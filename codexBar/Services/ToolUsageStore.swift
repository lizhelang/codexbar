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
    private var discoveryQuotaSnapshots: [ToolUsageClient: ToolQuotaSnapshot] = [:]
    private let preferencesStore: ApplicationPreferencesStore?
    private var preferencesCancellable: AnyCancellable?
    private var collectionRevision = 0
    private let cacheURL: URL
    private let cacheQueue = DispatchQueue(label: "codexbar.tool-usage-cache", qos: .utility)
    private var lastScanAt: Date?
    /// FSEvents-backed: periodic scans of unchanged local transcripts are skipped, with a safety rescan.
    private var localScanGate = LocalScanGate()
    private let localScanMaximumAge: TimeInterval = 15 * 60
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
                self.discoveryQuotaSnapshots.removeAll()
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

        // Every collector must name its directories for a skip to be safe; injected test doubles do not.
        var unchangedResults: [ToolUsageSnapshot]?
        if collectors.allSatisfy({ !$0.watchedPaths.isEmpty }) {
            self.localScanGate.watch(collectors.flatMap(\.watchedPaths))
            if !force, !self.localScanGate.shouldScan(maximumAge: self.localScanMaximumAge) {
                let previous = collectors.compactMap { self.snapshots[$0.client]?.refreshed(at: now) }
                if previous.count == collectors.count { unchangedResults = previous }
            }
        }
        if unchangedResults == nil { self.localScanGate.markScanStarted() }
        let reusedResults = unchangedResults
        if let reusedResults, !shouldSyncLegacyCursor {
            self.apply(reusedResults, scannedAt: now, importRevision: importRevision)
            return
        }

        Task.detached(priority: .utility) {
            var results = reusedResults ?? collectors.map { $0.collect(now: now, calendar: calendar) }
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
                        refreshedAt: now, statusDetail: "Grok 用量同步失败"
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
        if client == .antigravity {
            return ToolQuotaSnapshot(client: client, status: .unsupported, providerName: client.displayName,
                statusDetail: "Antigravity 账号额度在额度页独立管理；Token 用量来自本机会话记录")
        }
        if let snapshot = self.quotaSnapshots[client] { return snapshot }
        if client == .cursor, self.cursorAccountStore != nil {
            return ToolQuotaSnapshot(client: client, status: .notConfigured, providerName: client.displayName,
                statusDetail: "请在账号管理中连接并启用 Grok 账号")
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
        let enabledClients = ToolUsageClient.connectionClients.filter { !preferences.disabledTools.contains($0.rawValue) }
        Task {
            await withTaskGroup(of: ToolQuotaSnapshot?.self) { group in
                // A slow history sync must not hold up the other tools' quota refreshes.
                for client in enabledClients {
                    group.addTask { @MainActor in
                        guard self.collectionRevision == revision else { return nil }
                        if client == .cursor, let accounts = self.cursorAccountStore {
                            await accounts.discoverDesktopAccount(force: force, now: now)
                            await accounts.refreshAll(force: force, now: now)
                            return nil
                        }
                        if client != .cursor, let connections = self.connectionStore {
                            await connections.discover(client: client, preferences: preferences)
                            guard self.collectionRevision == revision else { return nil }
                            let profiles = connections.profiles(for: client)
                            for profile in profiles where profile.isEnabled {
                                guard self.collectionRevision == revision else { return nil }
                                await connections.refresh(profileID: profile.id, force: force, now: now)
                            }
                            // Preserve paused/hidden connections. Only explain discovery when
                            // there is no managed source, rather than replacing it with a generic message.
                            if !profiles.isEmpty || !connections.hiddenProfiles(for: client).isEmpty { return nil }
                        }
                        return await fetcher.fetch(client: client, preferences: preferences, now: now)
                    }
                }
                for await snapshot in group {
                    guard self.collectionRevision == revision else { continue }
                    if let snapshot {
                        self.discoveryQuotaSnapshots[snapshot.client] = snapshot
                        self.quotaSnapshots[snapshot.client] = snapshot
                    }
                    self.projectManagedAccounts()
                }
            }
            await MainActor.run {
                self.isRefreshingQuotas = false
                guard self.collectionRevision == revision else {
                    self.pendingQuotaRefresh = false
                    self.refreshQuotasIfNeeded(force: true)
                    return
                }
                self.quotaSnapshots = self.quotaSnapshots.filter { !preferences.disabledTools.contains($0.key.rawValue) }
                self.saveQuotaCache(Array(self.quotaSnapshots.values))
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
            AntigravityUsageCollector(dataDirectory: preferences.dataDirectory(for: "antigravity")),
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
                        ? "Grok 自动同步暂无记录；保留上次用量"
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
        // Collectors stamp every result with a fresh `refreshedAt`, so plain `!=` was always true and
        // each periodic scan re-encoded every usage record to disk. Only real content changes are persisted;
        // a timestamp-only change is still published so "updated at" labels stay current.
        let contentChanged = Self.snapshotContentChanged(from: self.snapshots, to: updated)
        if contentChanged || updated.contains(where: { self.snapshots[$0.key]?.refreshedAt != $0.value.refreshedAt }) {
            self.snapshots = updated
        }
        if contentChanged {
            self.saveCache()
        }
        self.lastScanAt = scannedAt
        self.isRefreshing = false
        if self.pendingRefresh {
            self.pendingRefresh = false
            self.refreshIfNeeded(force: true)
        }
    }

    static func snapshotContentChanged(
        from previous: [ToolUsageClient: ToolUsageSnapshot],
        to next: [ToolUsageClient: ToolUsageSnapshot]
    ) -> Bool {
        guard previous.count == next.count else { return true }
        return next.contains { client, snapshot in
            guard let old = previous[client] else { return true }
            return !old.hasSameContent(as: snapshot)
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

    /// Software usage includes all enabled account histories; quota remains scoped
    /// to the selected identity. Changing the quota selection must not hide usage.
    private func projectManagedAccounts() {
        let preferences = self.preferencesStore?.preferences ?? ApplicationPreferences()
        if let cursorAccountStore {
            let account = cursorAccountStore.accounts.first { $0.id == cursorAccountStore.selectedAccountID }
            let state = account.flatMap { cursorAccountStore.states[$0.id] }
            self.snapshots[.cursor] = CursorUsageAggregation.snapshot(
                accounts: cursorAccountStore.accounts, states: cursorAccountStore.states, calendar: .current)
            if !preferences.disabledTools.contains("cursor"), account?.isPaused == false, let quota = state?.quota {
                self.quotaSnapshots[.cursor] = quota
            } else { self.quotaSnapshots.removeValue(forKey: .cursor) }
        }
        if let connectionStore {
            for client in ToolUsageClient.connectionClients where client != .cursor {
                if !preferences.disabledTools.contains(client.rawValue), let quota = connectionStore.selectedQuota(for: client) {
                    self.quotaSnapshots[client] = quota
                    self.discoveryQuotaSnapshots.removeValue(forKey: client)
                } else if !preferences.disabledTools.contains(client.rawValue),
                          connectionStore.profiles(for: client).isEmpty,
                          connectionStore.hiddenProfiles(for: client).isEmpty,
                          let diagnostic = self.discoveryQuotaSnapshots[client] {
                    self.quotaSnapshots[client] = diagnostic
                } else { self.quotaSnapshots.removeValue(forKey: client) }
            }
        }
    }
}
