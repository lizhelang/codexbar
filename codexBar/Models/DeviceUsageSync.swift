import Foundation

/// Deliberately limited to aggregate counters. Account identities, credentials and conversation metadata are never exported.
nonisolated struct DeviceUsageDailyStat: Codable, Equatable, Sendable {
    let date: Date
    let toolID: String
    let totalTokens: Int
    let knownCostUSD: Double
    let costIsComplete: Bool

    nonisolated init(date: Date, toolID: String, totalTokens: Int, knownCostUSD: Double = 0, costIsComplete: Bool = false) {
        self.date = date
        self.toolID = toolID
        self.totalTokens = totalTokens
        self.knownCostUSD = knownCostUSD
        self.costIsComplete = costIsComplete
    }
}

nonisolated struct DeviceUsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let deviceID: String
    let deviceName: String
    let generatedAt: Date
    let timeZoneIdentifier: String
    let dailyEntries: [DeviceUsageDailyStat]

    nonisolated var id: String { self.deviceID }
    nonisolated var totalTokens: Int {
        self.dailyEntries.reduce(0) { value, entry in
            let result = value.addingReportingOverflow(entry.totalTokens)
            return result.overflow ? Int.max : result.partialValue
        }
    }
    nonisolated func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(self.generatedAt) > 24 * 60 * 60 }

    nonisolated init(deviceID: String, deviceName: String, generatedAt: Date = Date(), timeZoneIdentifier: String = TimeZone.current.identifier, dailyEntries: [DeviceUsageDailyStat]) {
        self.schemaVersion = 1
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.generatedAt = generatedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.dailyEntries = dailyEntries
    }

    nonisolated func validate(now: Date = Date()) throws {
        let allowedTools: Set<String> = ["codex", "claudeCode", "openCode", "cursor", "deepSeekHarness"]
        guard self.schemaVersion == 1, UUID(uuidString: self.deviceID) != nil,
              self.deviceName.count <= 80, !self.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              self.generatedAt.timeIntervalSince1970.isFinite, self.generatedAt <= now.addingTimeInterval(300),
              TimeZone(identifier: self.timeZoneIdentifier) != nil, self.dailyEntries.count <= 20_000 else {
            throw DeviceUsageSyncError.invalidSnapshot
        }
        var keys = Set<String>()
        for entry in self.dailyEntries {
            guard entry.date.timeIntervalSince1970.isFinite, entry.date <= now.addingTimeInterval(24 * 60 * 60),
                  entry.date.timeIntervalSince1970 >= 0, allowedTools.contains(entry.toolID),
                  entry.totalTokens >= 0, entry.knownCostUSD.isFinite, entry.knownCostUSD >= 0,
                  keys.insert("\(entry.toolID):\(entry.date.timeIntervalSince1970)").inserted else {
                throw DeviceUsageSyncError.invalidSnapshot
            }
        }
    }

    nonisolated static func latestDevices(_ snapshots: [Self], excluding deviceID: String? = nil) -> [Self] {
        var devices: [String: Self] = [:]
        for snapshot in snapshots where snapshot.deviceID.caseInsensitiveCompare(deviceID ?? "") != .orderedSame {
            let key = snapshot.deviceID.lowercased()
            if devices[key].map({ $0.generatedAt >= snapshot.generatedAt }) == true { continue }
            devices[key] = snapshot
        }
        return devices.values.sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }
}

nonisolated enum DeviceUsageSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, sharedFolder, iCloudDrive, client, host
    nonisolated var id: String { self.rawValue }
    nonisolated var title: String {
        switch self {
        case .local: "仅本机"
        case .sharedFolder: "共享文件夹"
        case .iCloudDrive: "iCloud Drive"
        case .client: "连接 Hub"
        case .host: "本机作为 Hub"
        }
    }
}

nonisolated struct DeviceUsageSyncConfiguration: Codable, Equatable, Sendable {
    var mode: DeviceUsageSyncMode = .local
    var deviceName: String = Host.current().localizedName ?? "Mac"
    var folderPath: String = ""
    var hubURL: String = ""
    var listenPort: UInt16 = 23948
    var allowLANConnections = false
    var syncIntervalSeconds: Int = 60

    nonisolated init() {}
}

nonisolated enum DeviceUsageSyncError: Error, LocalizedError, Sendable {
    case invalidSnapshot, oversized, unsafePath, invalidConfiguration, unauthorized, connectionFailed, tooManyDevices
    nonisolated var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "同步数据格式无效。"
        case .oversized: "同步数据超过大小限制。"
        case .unsafePath: "同步目录或文件无效，请重新选择普通文件夹。"
        case .invalidConfiguration: "请检查设备名、同步目录、Hub 地址和配对密钥。"
        case .unauthorized: "Hub 配对密钥不匹配。"
        case .connectionFailed: "无法连接 Hub，请检查地址、端口及网络。"
        case .tooManyDevices: "同步设备超过 32 台上限。"
        }
    }
}
