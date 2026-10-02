import Combine
import Foundation

@MainActor
final class DeviceUsageSyncService: ObservableObject {
    static let shared = DeviceUsageSyncService()

    @Published private(set) var configuration: DeviceUsageSyncConfiguration
    @Published private(set) var remoteSnapshots: [DeviceUsageSnapshot] = []
    @Published private(set) var localSnapshot: DeviceUsageSnapshot?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var statusMessage = "仅统计本机，未启用同步。"
    @Published private(set) var listeningPort: UInt16?
    let deviceID: String

    private let storageURL: URL
    private var hub: DeviceUsageHubServer?
    private var timer: Timer?
    private var operation: Task<Void, Never>?
    private var revision = 0
    private let persistenceQueue = DispatchQueue(label: "codexbar.device-usage-cache", qos: .utility)

    init(storageURL: URL? = nil, startConfiguredMode: Bool = true) {
        self.storageURL = (storageURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexbar/device-sync")).resolvingSymlinksInPath()
        let configURL = self.storageURL.appendingPathComponent("configuration.json")
        if let data = try? DeviceUsageSnapshotDirectory.readRegularFile(configURL, maximumBytes: 16_384),
           let configuration = try? JSONDecoder().decode(DeviceUsageSyncConfiguration.self, from: data) {
            self.configuration = configuration
        } else { self.configuration = DeviceUsageSyncConfiguration() }
        let idURL = self.storageURL.appendingPathComponent("device-id")
        if let data = try? DeviceUsageSnapshotDirectory.readRegularFile(idURL, maximumBytes: 128),
           let text = String(data: data, encoding: .utf8), UUID(uuidString: text) != nil {
            self.deviceID = text.lowercased()
        } else {
            self.deviceID = UUID().uuidString.lowercased()
            try? Self.writeProtected(Data(self.deviceID.utf8), to: idURL)
        }
        if let data = try? DeviceUsageSnapshotDirectory.readRegularFile(self.storageURL.appendingPathComponent("remote-cache.json"), maximumBytes: 64 * 1024 * 1024),
           let snapshots = try? JSONDecoder().decode([DeviceUsageSnapshot].self, from: data),
           snapshots.count <= DeviceUsageSnapshotDirectory.maximumDevices {
            self.remoteSnapshots = DeviceUsageSnapshot.latestDevices(snapshots.filter { (try? $0.validate()) != nil }, excluding: self.deviceID)
        }
        if let data = try? DeviceUsageSnapshotDirectory.readRegularFile(self.storageURL.appendingPathComponent("local-cache.json"), maximumBytes: DeviceUsageSnapshotDirectory.maximumSnapshotBytes),
           let snapshot = try? JSONDecoder().decode(DeviceUsageSnapshot.self, from: data),
           snapshot.deviceID == self.deviceID, (try? snapshot.validate()) != nil {
            self.localSnapshot = snapshot
        }
        if self.configuration.mode == .local { self.remoteSnapshots = [] }
        if startConfiguredMode { self.restart() }
    }

    /// The caller supplies only already-collected aggregates. Cursor account API/CSV totals are not device-local.
    func publishLocalUsage(codex: LocalCostSummary, tools: [ToolUsageClient: ToolUsageSnapshot], enabledToolIDs: Set<String> = ["codex", "claudeCode", "openCode", "cursor", "deepSeekHarness"], now: Date = Date()) {
        let cachedEntries = self.localSnapshot?.dailyEntries ?? []
        let hasDisabledCachedData = cachedEntries.contains { !enabledToolIDs.contains($0.toolID) }
        guard codex.updatedAt != nil || tools.values.contains(where: { $0.refreshedAt != nil || !$0.dailyEntries.isEmpty }) || hasDisabledCachedData || enabledToolIDs.isEmpty else { return }
        // A not-yet-loaded collector must not erase its last complete local history on startup.
        var entries = cachedEntries.filter { enabledToolIDs.contains($0.toolID) }
        if enabledToolIDs.contains("codex"), codex.updatedAt != nil {
            entries.removeAll { $0.toolID == "codex" }
            entries += codex.dailyEntries.map {
                DeviceUsageDailyStat(date: $0.date, toolID: "codex", totalTokens: max(0, $0.totalTokens), knownCostUSD: max(0, $0.costUSD), costIsComplete: $0.costIsComplete)
            }
        }
        for client in ToolUsageClient.allCases {
            guard enabledToolIDs.contains(client.rawValue), let tool = tools[client], tool.evidence != .server, tool.evidence != .imported,
                  tool.refreshedAt != nil || !tool.dailyEntries.isEmpty else { continue }
            entries.removeAll { $0.toolID == client.rawValue }
            entries += tool.dailyEntries.map {
                DeviceUsageDailyStat(date: $0.date, toolID: client.rawValue, totalTokens: max(0, $0.totalTokens), knownCostUSD: max(0, $0.costUSD ?? $0.knownCostUSD ?? 0), costIsComplete: $0.costUSD != nil || $0.totalTokens == 0)
            }
        }
        let previous = self.localSnapshot
        guard previous?.dailyEntries != entries || previous?.deviceName != self.configuration.deviceName ||
                previous?.timeZoneIdentifier != TimeZone.current.identifier else { return }
        let snapshot = DeviceUsageSnapshot(deviceID: self.deviceID, deviceName: self.configuration.deviceName, generatedAt: now, dailyEntries: entries)
        guard (try? snapshot.validate()) != nil else { return }
        self.localSnapshot = snapshot
        self.persistCache(snapshot, filename: "local-cache.json")
        if self.configuration.mode != .local, self.lastSyncAt == nil { self.syncNow() }
    }

    func applyConfiguration(_ newConfiguration: DeviceUsageSyncConfiguration, pairingSecret: String?) throws {
        let name = newConfiguration.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, (30...3600).contains(newConfiguration.syncIntervalSeconds), newConfiguration.listenPort > 0 else { throw DeviceUsageSyncError.invalidConfiguration }
        var configuration = newConfiguration
        configuration.deviceName = name
        if configuration.mode == .sharedFolder || configuration.mode == .iCloudDrive {
            guard !configuration.folderPath.isEmpty else { throw DeviceUsageSyncError.invalidConfiguration }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: configuration.folderPath, isDirectory: &isDirectory), isDirectory.boolValue else { throw DeviceUsageSyncError.unsafePath }
            configuration.folderPath = URL(fileURLWithPath: configuration.folderPath).resolvingSymlinksInPath().path
        }
        if configuration.mode == .client { _ = try DeviceUsageHubClient.validatedURL(configuration.hubURL) }
        if configuration.mode == .client || configuration.mode == .host {
            let supplied = pairingSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (supplied?.isEmpty == false ? supplied : nil) ?? self.savedPairingSecret() ?? (configuration.mode == .host ? Self.newPairingSecret() : nil)
            guard let key, key.count >= 32, key.count <= 128, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { throw DeviceUsageSyncError.invalidConfiguration }
            try Self.writeProtected(Data(key.utf8), to: self.storageURL.appendingPathComponent("pairing-secret"))
        }
        let emptyCache = try JSONEncoder().encode([DeviceUsageSnapshot]())
        let remoteCacheURL = self.storageURL.appendingPathComponent("remote-cache.json")
        // A deliberate source change must complete after any earlier cache write.
        try self.persistenceQueue.sync { try Self.writeProtected(emptyCache, to: remoteCacheURL) }
        try Self.writeProtected(JSONEncoder().encode(configuration), to: self.storageURL.appendingPathComponent("configuration.json"))
        self.configuration = configuration
        if let local = self.localSnapshot {
            self.localSnapshot = DeviceUsageSnapshot(deviceID: self.deviceID, deviceName: name, generatedAt: Date(), timeZoneIdentifier: local.timeZoneIdentifier, dailyEntries: local.dailyEntries)
        }
        self.remoteSnapshots = []
        self.lastSyncAt = nil
        self.restart()
    }

    /// Read only when the user explicitly asks to copy the Hub pairing key.
    func pairingSecretForUserCopy() -> String? { self.savedPairingSecret() }

    func syncNow() {
        guard self.configuration.mode != .local, !self.isSyncing else { return }
        guard self.configuration.mode != .host || self.listeningPort != nil else { return }
        let configuration = self.configuration
        let snapshot = self.localSnapshot.map {
            DeviceUsageSnapshot(deviceID: $0.deviceID, deviceName: configuration.deviceName, generatedAt: Date(), timeZoneIdentifier: $0.timeZoneIdentifier, dailyEntries: $0.dailyEntries)
        }
        let secret = self.savedPairingSecret()
        let revision = self.revision
        let storageURL = self.storageURL
        self.isSyncing = true
        self.operation = Task {
            do {
                let records: [DeviceUsageSnapshot]
                switch configuration.mode {
                case .local: records = []
                case .sharedFolder, .iCloudDrive:
                    let directory = DeviceUsageSnapshotDirectory(url: URL(fileURLWithPath: configuration.folderPath).appendingPathComponent("Codexbar Usage Sync", isDirectory: true))
                    records = try await Task.detached(priority: .utility) {
                        if let snapshot { try directory.write(snapshot) }
                        return try directory.read()
                    }.value
                case .host:
                    let directory = DeviceUsageSnapshotDirectory(url: storageURL.appendingPathComponent("hub-snapshots", isDirectory: true))
                    records = try await Task.detached(priority: .utility) {
                        if let snapshot { try directory.write(snapshot) }
                        return try directory.read()
                    }.value
                case .client:
                    guard let secret else { throw DeviceUsageSyncError.invalidConfiguration }
                    records = try await DeviceUsageHubClient(baseURL: DeviceUsageHubClient.validatedURL(configuration.hubURL), secret: secret).exchange(snapshot)
                }
                guard !Task.isCancelled, self.revision == revision else { return }
                // Preserve cached devices across incomplete iCloud downloads and temporary disappearance.
                self.remoteSnapshots = Array(DeviceUsageSnapshot.latestDevices(self.remoteSnapshots + records, excluding: self.deviceID)
                    .sorted { $0.generatedAt > $1.generatedAt }
                    .prefix(DeviceUsageSnapshotDirectory.maximumDevices))
                self.lastSyncAt = Date()
                self.statusMessage = "已同步 · \(self.remoteSnapshots.count) 台其他设备"
                self.persistCache(self.remoteSnapshots, filename: "remote-cache.json")
                self.isSyncing = false
            } catch {
                guard !Task.isCancelled, self.revision == revision else { return }
                self.statusMessage = (error as? DeviceUsageSyncError)?.errorDescription ?? "同步失败，保留上次设备数据。"
                self.isSyncing = false
            }
        }
    }

    private func restart() {
        self.revision += 1
        self.operation?.cancel()
        self.timer?.invalidate(); self.timer = nil
        self.hub?.stop(); self.hub = nil
        self.listeningPort = nil
        self.isSyncing = false
        guard self.configuration.mode != .local else {
            self.statusMessage = "仅统计本机，未启用同步。"
            return
        }
        self.statusMessage = "等待同步…"
        let interval = TimeInterval(min(3600, max(30, self.configuration.syncIntervalSeconds)))
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        if self.configuration.mode == .host {
            guard let key = self.savedPairingSecret() else { self.statusMessage = "未找到 Hub 配对密钥，请重新应用设置。"; return }
            let server = DeviceUsageHubServer(directory: DeviceUsageSnapshotDirectory(url: self.storageURL.appendingPathComponent("hub-snapshots")), secret: key)
            self.hub = server
            let revision = self.revision
            let port = self.configuration.listenPort
            let allowLAN = self.configuration.allowLANConnections
            Task {
                guard self.revision == revision else { return }
                do {
                    let actualPort = try await server.start(port: port, allowLAN: allowLAN)
                    guard self.revision == revision else { server.stop(); return }
                    self.listeningPort = actualPort
                    self.syncNow()
                } catch {
                    guard self.revision == revision else { return }
                    self.statusMessage = "Hub 无法启动，请检查端口是否被占用。"
                }
            }
        } else { self.syncNow() }
    }

    private func savedPairingSecret() -> String? {
        let url = self.storageURL.appendingPathComponent("pairing-secret")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let data = try? DeviceUsageSnapshotDirectory.readRegularFile(url, maximumBytes: 128) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func newPairingSecret() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    private func persistCache<Value: Encodable & Sendable>(_ value: Value, filename: String) {
        let url = self.storageURL.appendingPathComponent(filename)
        self.persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? Self.writeProtected(data, to: url)
        }
    }

    func waitForPendingCacheWrites() async {
        await withCheckedContinuation { continuation in
            self.persistenceQueue.async { continuation.resume() }
        }
    }

    nonisolated private static func writeProtected(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else { throw DeviceUsageSyncError.unsafePath }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw DeviceUsageSyncError.unsafePath }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
