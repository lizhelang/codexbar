import Combine
import Foundation

/// Keeps cross-client usage separate from the Codex account and cost ledger.
/// Caches dated usage metadata; message bodies and authentication never enter this store.
@MainActor
final class ToolUsageStore: ObservableObject {
    static let shared = ToolUsageStore(preferencesStore: .shared,
        cursorAccountStore: .shared, connectionStore: .shared)

    @Published private(set) var snapshots: [ToolUsageClient: ToolUsageSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var quotaSnapshots: [ToolUsageClient: ToolQuotaSnapshot] = [:]
    @Published private(set) var isRefreshingQuotas = false

    private let injectedCollectors: [any ToolUsageCollecting]?
    private let injectedCursorSyncer: (any CursorUsageSyncing)?
    private let injectedQuotaFetcher: (any ToolQuotaFetching)?
    private var lastQuotaAttemptAt: Date?
    private var pendingQuotaRefresh = false
    private let preferencesStore: ApplicationPreferencesStore?
    private var preferencesCancellable: AnyCancellable?
    private var collectionRevision = 0
    private let cacheURL: URL
    private let cacheQueue = DispatchQueue(label: "codexbar.tool-usage-cache", qos: .utility)
    private var lastScanAt: Date?
    private var lastCursorAttemptAt: Date?
    private var pendingRefresh = false
    private var cursorImportRevision = 0
    private let cursorAccountStore: CursorAccountStore?
    private let connectionStore: ToolConnectionStore?
    private var managedSubscriptions: [AnyCancellable] = []

    /// The management surface shares the same injected identity stores as the dashboard.
    var managedCursorAccounts: CursorAccountStore? { self.cursorAccountStore }
    var managedConnections: ToolConnectionStore? { self.connectionStore }

    init(
        collectors: [any ToolUsageCollecting]? = nil,
        cursorSyncer: (any CursorUsageSyncing)? = nil,
        quotaFetcher: (any ToolQuotaFetching)? = nil,
        cacheURL: URL? = nil,
        preferencesStore: ApplicationPreferencesStore? = nil,
        cursorAccountStore: CursorAccountStore? = nil,
        connectionStore: ToolConnectionStore? = nil
    ) {
        self.injectedCollectors = collectors
        self.injectedCursorSyncer = cursorSyncer
        self.injectedQuotaFetcher = quotaFetcher
        self.preferencesStore = preferencesStore
        self.cursorAccountStore = cursorAccountStore
        self.connectionStore = connectionStore
        self.cacheURL = cacheURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/tool-usage-summary.json")
        self.loadCache()
        self.loadQuotaCache()
        self.preferencesCancellable = preferencesStore?.$preferences
            .map { CollectionConfiguration(disabledTools: $0.disabledTools, directories: $0.customDataDirectories) }
            .removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.collectionRevision += 1
                // @Published emits before storing the new value; collect on the next main-actor turn.
                Task { self.refreshIfNeeded(force: true) }
            }
        if let cursorAccountStore {
            cursorAccountStore.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.projectManagedAccounts() }
            }.store(in: &self.managedSubscriptions)
        }
        if let connectionStore {
            connectionStore.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.projectManagedAccounts() }
            }.store(in: &self.managedSubscriptions)
        }
        self.projectManagedAccounts()
    }

    func snapshot(for client: ToolUsageClient) -> ToolUsageSnapshot {
        self.snapshots[client] ?? ToolUsageSnapshot(
            client: client,
            availability: client == .cursor ? .needsImport : .noRecords,
            evidence: client == .cursor ? .imported : .reported
        )
    }

    var displaySnapshots: [ToolUsageClient: ToolUsageSnapshot] {
        Dictionary(uniqueKeysWithValues: ToolUsageClient.allCases.map { ($0, self.snapshot(for: $0)) })
    }

    func refreshIfNeeded(force: Bool = false, now: Date = Date()) {
        if self.preferencesStore != nil || self.injectedQuotaFetcher != nil {
            self.refreshQuotasIfNeeded(force: force, now: now)
        }
        if self.isRefreshing {
            self.pendingRefresh = self.pendingRefresh || force
            return
        }
        if force == false,
           let lastScanAt,
           now.timeIntervalSince(lastScanAt) < (self.preferencesStore?.preferences.refreshIntervalSeconds ?? 90) {
            return
        }

        self.isRefreshing = true
        let preferences = self.preferencesStore?.preferences ?? ApplicationPreferences()
        let collectors = (self.injectedCollectors ?? Self.collectors(preferences: preferences))
            .filter { !preferences.disabledTools.contains($0.client.rawValue) }
        let cursorRoot = preferences.dataDirectory(for: "cursor")
        let cursorSyncer = self.injectedCursorSyncer ?? CursorUsageSyncer(
            sessionReader: CursorDesktopSessionReader(databaseURL: cursorRoot?.appendingPathComponent("state.vscdb"))
        )
        let shouldSyncCursor = !preferences.disabledTools.contains("cursor") &&
            (force || self.lastCursorAttemptAt.map { now.timeIntervalSince($0) >= max(5 * 60, preferences.refreshIntervalSeconds) } ?? true)
        let shouldSyncLegacyCursor = shouldSyncCursor && self.cursorAccountStore == nil
        let collectionRevision = self.collectionRevision
        if shouldSyncCursor { self.lastCursorAttemptAt = now }
        let importRevision = self.cursorImportRevision
        let calendar = Calendar.current
        Task.detached(priority: .utility) {
            var results = collectors.map { $0.collect(now: now, calendar: calendar) }
            if shouldSyncLegacyCursor {
                do {
                    results.append(try await cursorSyncer.sync(now: now, calendar: calendar))
                } catch let error as CursorUsageSyncError {
                    results.append(ToolUsageSnapshot(
                        client: .cursor,
                        availability: error == .noDesktopSession ? .needsImport : .failed,
                        evidence: .server,
                        refreshedAt: now,
                        statusDetail: error.statusDetail
                    ))
                } catch {
                    results.append(ToolUsageSnapshot(
                        client: .cursor, availability: .failed, evidence: .server,
                        refreshedAt: now, statusDetail: "Cursor 用量同步失败"
                    ))
                }
            }
            let completedResults = results
            await MainActor.run {
                if self.collectionRevision == collectionRevision {
                    self.apply(completedResults, scannedAt: now, importRevision: importRevision)
                } else {
                    self.isRefreshing = false
                    self.pendingRefresh = false
                    self.refreshIfNeeded(force: true)
                }
            }
        }
    }

    private struct CollectionConfiguration: Equatable {
        var disabledTools: [String]
        var directories: [String: String]
    }

    func quota(for client: ToolUsageClient) -> ToolQuotaSnapshot {
        if let snapshot = self.quotaSnapshots[client] { return snapshot }
        if client == .cursor, self.cursorAccountStore != nil {
            return ToolQuotaSnapshot(client: client, status: .notConfigured, providerName: client.displayName,
                statusDetail: "请在账号管理中连接并启用 Cursor 账号")
        }
        if client != .cursor, self.connectionStore != nil {
            return ToolQuotaSnapshot(client: client, status: .notConfigured, providerName: client.displayName,
                statusDetail: "请在账号管理中自动识别或添加支持的连接")
        }
        return ToolQuotaSnapshot(client: client, status: .loading,
            providerName: client.displayName, statusDetail: "正在读取账户额度")
    }

    func refreshQuotasIfNeeded(force: Bool = false, now: Date = Date()) {
        guard !self.isRefreshingQuotas else {
            self.pendingQuotaRefresh = self.pendingQuotaRefresh || force
            return
        }
        if !force, let lastQuotaAttemptAt, now.timeIntervalSince(lastQuotaAttemptAt) < 300 { return }
        self.lastQuotaAttemptAt = now
        self.isRefreshingQuotas = true
        let preferences = self.preferencesStore?.preferences ?? ApplicationPreferences()
        let fetcher = self.injectedQuotaFetcher ?? ToolQuotaService()
        let revision = self.collectionRevision
        let enabledClients = ToolUsageClient.allCases.filter { !preferences.disabledTools.contains($0.rawValue) }
        let clients = enabledClients.filter {
            $0 == .cursor ? self.cursorAccountStore == nil : self.connectionStore == nil
        }
        Task {
            if enabledClients.contains(.cursor), let cursorAccountStore = self.cursorAccountStore {
                await cursorAccountStore.discoverDesktopAccount(force: force, now: now)
                await cursorAccountStore.refreshAll(force: force, now: now)
            }
            if let connectionStore = self.connectionStore {
                for client in enabledClients where client != .cursor {
                    guard self.collectionRevision == revision else { break }
                    let current = self.preferencesStore?.preferences ?? preferences
                    guard !current.disabledTools.contains(client.rawValue) else { continue }
                    await connectionStore.discover(client: client, preferences: current)
                    for profile in connectionStore.profiles(for: client) where profile.isEnabled {
                        guard self.collectionRevision == revision else { break }
                        await connectionStore.refresh(profileID: profile.id, force: force)
                    }
                }
            }
            let snapshots = await withTaskGroup(of: ToolQuotaSnapshot.self) { group in
                for client in clients {
                    group.addTask { await fetcher.fetch(client: client, preferences: preferences, now: now) }
                }
                var result: [ToolQuotaSnapshot] = []
                for await snapshot in group { result.append(snapshot) }
                return result
            }
            await MainActor.run {
                self.isRefreshingQuotas = false
                guard self.collectionRevision == revision else {
                    self.pendingQuotaRefresh = false
                    self.refreshQuotasIfNeeded(force: true)
                    return
                }
                var updated = self.quotaSnapshots.filter { !preferences.disabledTools.contains($0.key.rawValue) }
                for snapshot in snapshots { updated[snapshot.client] = snapshot }
                if updated != self.quotaSnapshots {
                    self.quotaSnapshots = updated
                    self.saveQuotaCache(Array(updated.values))
                }
                self.projectManagedAccounts()
                if self.pendingQuotaRefresh {
                    self.pendingQuotaRefresh = false
                    self.refreshQuotasIfNeeded(force: true)
                }
            }
        }
    }

    private var quotaCacheURL: URL { self.cacheURL.deletingLastPathComponent().appendingPathComponent("tool-quota-summary.json") }

    private func loadQuotaCache() {
        let url = self.quotaCacheURL
        self.cacheQueue.async { [weak self] in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024,
                  let cached = try? JSONDecoder().decode([ToolQuotaSnapshot].self, from: data) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var updated = self.quotaSnapshots
                for snapshot in cached where updated[snapshot.client] == nil &&
                    (snapshot.client == .cursor ? self.cursorAccountStore == nil : self.connectionStore == nil) {
                    updated[snapshot.client] = snapshot
                }
                if updated != self.quotaSnapshots { self.quotaSnapshots = updated }
            }
        }
    }

    private func saveQuotaCache(_ snapshots: [ToolQuotaSnapshot]) {
        let destination = self.quotaCacheURL
        self.cacheQueue.async {
            guard let data = try? JSONEncoder().encode(snapshots) else { return }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: destination, options: .atomic)) != nil else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    private static func collectors(preferences: ApplicationPreferences) -> [any ToolUsageCollecting] {
        let claudeRoot = preferences.dataDirectory(for: "claudeCode")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return [
            ClaudeCodeUsageCollector(projectsURL: claudeRoot.appendingPathComponent("projects"),
                                     transcriptsURL: claudeRoot.appendingPathComponent("transcripts")),
            OpenCodeUsageCollector(dataDirectory: preferences.dataDirectory(for: "openCode")),
            DeepSeekHarnessUsageCollector(sessionsDirectory: preferences.dataDirectory(for: "deepSeekHarness")?.appendingPathComponent("sessions")),
        ]
    }

    func updateImportedCursor(_ snapshot: ToolUsageSnapshot) {
        guard snapshot.client == .cursor else { return }
        if let cursorAccountStore {
            // A CSV is bound to the explicitly selected monitored account. Never
            // reuse an anonymous client-level import for a different identity.
            guard let accountID = cursorAccountStore.selectedAccountID,
                  (try? cursorAccountStore.importUsage(snapshot, accountID: accountID)) != nil else { return }
            self.projectManagedAccounts()
            return
        }
        self.cursorImportRevision += 1
        self.snapshots[.cursor] = snapshot
        self.saveCache()
        let revision = self.cursorImportRevision
        let calendar = Calendar.current
        Task.detached(priority: .utility) { [weak self] in
            let repriced = ToolCostEstimator.reprice(snapshot, calendar: calendar)
            await MainActor.run { [weak self] in
                guard let self, self.cursorImportRevision == revision,
                      self.snapshots[.cursor] == snapshot, repriced != snapshot else { return }
                self.snapshots[.cursor] = repriced
                self.saveCache()
            }
        }
    }

    private func apply(_ results: [ToolUsageSnapshot], scannedAt: Date, importRevision: Int) {
        var updated = self.snapshots
        for result in results {
            if result.client == .cursor, importRevision != self.cursorImportRevision {
                continue
            }
            if result.client == .cursor,
               result.dailyEntries.isEmpty,
               let previous = updated[.cursor],
               previous.dailyEntries.isEmpty == false {
                // An empty remote result may belong to a different account or
                // indicate a changed private API. Keep the user's CSV/history.
                updated[.cursor] = ToolUsageSnapshot(
                    client: .cursor,
                    availability: result.availability == .noRecords ? .partial : .failed,
                    evidence: previous.evidence,
                    dailyEntries: previous.dailyEntries,
                    usageRecords: previous.usageRecords,
                    latestUsageAt: previous.latestUsageAt,
                    refreshedAt: previous.refreshedAt,
                    statusDetail: result.availability == .noRecords
                        ? "Cursor 自动同步暂无记录；保留上次用量"
                        : result.statusDetail
                )
                continue
            }
            if result.availability == .failed,
               let previous = updated[result.client],
               previous.dailyEntries.isEmpty == false {
                updated[result.client] = ToolUsageSnapshot(
                    client: result.client,
                    availability: .failed,
                    evidence: previous.evidence,
                    dailyEntries: previous.dailyEntries,
                    usageRecords: previous.usageRecords,
                    latestUsageAt: previous.latestUsageAt,
                    refreshedAt: previous.refreshedAt,
                    statusDetail: result.statusDetail
                )
            } else {
                updated[result.client] = result
            }
        }
        if updated != self.snapshots {
            self.snapshots = updated
            self.saveCache()
        }
        self.lastScanAt = scannedAt
        self.isRefreshing = false
        if self.pendingRefresh {
            self.pendingRefresh = false
            self.refreshIfNeeded(force: true)
        }
    }

    private func loadCache() {
        let cacheURL = self.cacheURL
        let calendar = Calendar.current
        self.cacheQueue.async { [weak self] in
            guard let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: cacheURL), data.count <= 32 * 1024 * 1024,
                  let cached = try? JSONDecoder().decode([ToolUsageSnapshot].self, from: data) else { return }
            let repriced = cached.map { ToolCostEstimator.reprice($0, calendar: calendar) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var updated = self.snapshots
                // A fresh scan/import wins over an older disk snapshot.
                for snapshot in repriced where updated[snapshot.client] == nil &&
                    (snapshot.client != .cursor || self.cursorAccountStore == nil) {
                    updated[snapshot.client] = snapshot
                }
                if updated != self.snapshots {
                    self.snapshots = updated
                    self.saveCache()
                }
            }
        }
    }

    private func saveCache() {
        let snapshots = ToolUsageClient.allCases.compactMap { self.snapshots[$0] }
        let cacheURL = self.cacheURL
        self.cacheQueue.async {
            guard let data = try? JSONEncoder().encode(snapshots) else { return }
            let folder = cacheURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? data.write(to: cacheURL, options: .atomic)) != nil else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }
    }

    /// The client-level view projects a selected identity. Account caches remain
    /// in their own stores, so changing selection cannot inherit another account's data.
    private func projectManagedAccounts() {
        let preferences = self.preferencesStore?.preferences ?? ApplicationPreferences()
        if let cursorAccountStore {
            let account = cursorAccountStore.accounts.first { $0.id == cursorAccountStore.selectedAccountID }
            let state = account.flatMap { cursorAccountStore.states[$0.id] }
            if let usage = state?.usage { self.snapshots[.cursor] = usage }
            else { self.snapshots.removeValue(forKey: .cursor) }
            if !preferences.disabledTools.contains("cursor"), account?.isPaused == false, let quota = state?.quota {
                self.quotaSnapshots[.cursor] = quota
            } else { self.quotaSnapshots.removeValue(forKey: .cursor) }
        }
        if let connectionStore {
            for client in ToolUsageClient.allCases where client != .cursor {
                if !preferences.disabledTools.contains(client.rawValue), let quota = connectionStore.selectedQuota(for: client) {
                    self.quotaSnapshots[client] = quota
                } else { self.quotaSnapshots.removeValue(forKey: client) }
            }
        }
    }
}
