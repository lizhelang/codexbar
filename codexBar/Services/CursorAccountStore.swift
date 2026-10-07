import Combine
import Darwin
import Foundation

// Account discovery/deduplication and per-account throttling adapt token-monitor's
// providers/cursor/{auth,selfSync}.js (MIT, Copyright (c) 2026 Javis).
// This store monitors accounts; it never activates, rewrites or logs into Cursor itself.
@MainActor
final class CursorAccountStore: ObservableObject {
    static let shared = CursorAccountStore()

    @Published private(set) var accounts: [CursorManagedAccount] = []
    @Published private(set) var states: [String: CursorAccountState] = [:]
    @Published private(set) var selectedAccountID: String?
    @Published private(set) var desktopAccountID: String?
    @Published private(set) var status: String?
    @Published private(set) var isDiscovering = false
    @Published private(set) var isAdding = false
    @Published private(set) var isCollectionEnabled = true

    let rootURL: URL
    private let service: any CursorAccountServicing
    private let sessionReader: CursorDesktopSessionReader
    private let preferencesStore: ApplicationPreferencesStore
    private let refreshInterval: TimeInterval
    private var preferenceSubscription: AnyCancellable?
    private var revisions: [String: UUID] = [:]
    private var inFlight: [String: UUID] = [:]
    private var lastAttempts: [String: Date] = [:]
    private var lastDiscovery: Date?
    private var collectionRevision = UUID()

    var selectedAccount: CursorManagedAccount? { self.accounts.first { $0.id == self.selectedAccountID } }
    var selectedState: CursorAccountState? { self.selectedAccountID.flatMap { self.states[$0] } }
    var isRefreshing: Bool { !self.inFlight.isEmpty }

    init(rootURL: URL? = nil, service: any CursorAccountServicing = CursorAccountService(),
         sessionReader: CursorDesktopSessionReader? = nil,
         preferencesStore: ApplicationPreferencesStore? = nil, refreshInterval: TimeInterval = 60) {
        self.rootURL = rootURL ?? CodexPaths.codexBarRoot.appendingPathComponent("cursor-accounts", isDirectory: true)
        self.service = service
        self.preferencesStore = preferencesStore ?? .shared
        self.sessionReader = sessionReader ?? CursorDesktopSessionReader(databaseURL: CodexPaths.realHome
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"))
        self.refreshInterval = refreshInterval.isFinite ? max(1, refreshInterval) : 60
        self.isCollectionEnabled = !self.preferencesStore.preferences.disabledTools.contains("cursor")
        self.load()
        self.preferenceSubscription = self.preferencesStore.$preferences.dropFirst().sink { [weak self] preferences in
            guard let self else { return }
            let enabled = !preferences.disabledTools.contains("cursor")
            if enabled != self.isCollectionEnabled {
                self.collectionRevision = UUID()
                self.isCollectionEnabled = enabled
                self.inFlight.removeAll()
                for account in self.accounts {
                    var state = self.states[account.id] ?? CursorAccountState()
                    state.status = enabled && !account.isPaused ? .idle : .paused
                    state.statusDetail = enabled && !account.isPaused ? nil : CursorAccountError.paused.statusDetail
                    self.states[account.id] = state
                }
            }
        }
    }

    /// Read-only desktop discovery. It preserves the selected monitoring account and pause choices.
    func discoverDesktopAccount(force: Bool = false, now: Date = Date()) async {
        guard self.isCollectionEnabled, !self.isDiscovering else { return }
        if !force, let lastDiscovery, now.timeIntervalSince(lastDiscovery) < self.refreshInterval { return }
        self.lastDiscovery = now
        self.isDiscovering = true
        let collectionRevision = self.collectionRevision
        defer { self.isDiscovering = false }
        do {
            let root = self.preferencesStore.preferences.dataDirectory(for: "cursor")
            let reader = root.map { CursorDesktopSessionReader(databaseURL: $0.appendingPathComponent("state.vscdb")) } ?? self.sessionReader
            let cookie = try reader.sessionCookie()
            let id = try CursorAccountService.userID(sessionCookie: cookie)
            let revision = self.revisions[id]
            if self.accounts.first(where: { $0.id == id })?.isPaused == true {
                self.desktopAccountID = id
                self.status = CursorAccountError.paused.statusDetail
                return
            }
            let probe = try await self.service.probe(sessionCookie: cookie, now: now)
            guard self.isCollectionEnabled, self.collectionRevision == collectionRevision,
                  self.revisions[id] == revision else { return }
            guard probe.identity.userID == id else { throw CursorAccountError.identityMismatch }
            try self.saveValidatedAccount(cookie: cookie, probe: probe, alias: nil, source: .desktop, now: now)
            self.desktopAccountID = id
            self.status = nil
        } catch let error as CursorUsageSyncError where error == .noDesktopSession {
            guard self.collectionRevision == collectionRevision else { return }
            self.desktopAccountID = nil
            self.status = "未发现已登录的 Cursor，可手动添加账号"
        } catch {
            guard self.collectionRevision == collectionRevision else { return }
            self.status = CursorAccountError.sanitized(error).statusDetail
        }
    }

    /// Authentication and usage-summary validation must both succeed before any credential is saved.
    @discardableResult
    func addAccount(sessionCookie: String, alias: String = "", now: Date = Date()) async throws -> String {
        guard !self.isAdding else { throw CursorAccountError.operationSuperseded }
        guard self.isCollectionEnabled else { throw CursorAccountError.paused }
        let cookie = try CursorAccountService.normalize(sessionCookie)
        let id = try CursorAccountService.userID(sessionCookie: cookie)
        let cleanAlias = try self.validAlias(alias, cookie: cookie)
        let revision = self.revisions[id]
        let collectionRevision = self.collectionRevision
        self.isAdding = true
        defer { self.isAdding = false }
        do {
            let probe = try await self.service.probe(sessionCookie: cookie, now: now)
            guard self.isCollectionEnabled, self.collectionRevision == collectionRevision,
                  self.revisions[id] == revision else { throw CursorAccountError.operationSuperseded }
            guard probe.identity.userID == id else { throw CursorAccountError.identityMismatch }
            try self.saveValidatedAccount(cookie: cookie, probe: probe, alias: cleanAlias.isEmpty ? nil : cleanAlias, source: .manual, now: now)
            self.status = nil
            return id
        } catch {
            let safe = CursorAccountError.sanitized(error)
            self.status = safe.statusDetail
            throw safe
        }
    }

    func replaceCredential(accountID: String, sessionCookie: String, now: Date = Date()) async throws {
        guard self.accounts.contains(where: { $0.id == accountID }) else { throw CursorAccountError.accountNotFound }
        guard try CursorAccountService.userID(sessionCookie: sessionCookie) == accountID else { throw CursorAccountError.identityMismatch }
        _ = try await self.addAccount(sessionCookie: sessionCookie, now: now)
    }

    func renameAccount(_ accountID: String, alias: String) throws {
        guard let index = self.accounts.firstIndex(where: { $0.id == accountID }) else { throw CursorAccountError.accountNotFound }
        var updated = self.accounts
        updated[index].alias = try self.validAlias(alias, cookie: try self.readCredential(accountID))
        updated[index].updatedAt = Date()
        try self.saveDocument(accounts: updated, selectedAccountID: self.selectedAccountID)
        self.accounts = updated
    }

    func selectAccount(_ accountID: String) throws {
        guard self.accounts.contains(where: { $0.id == accountID }) else { throw CursorAccountError.accountNotFound }
        try self.saveDocument(accounts: self.accounts, selectedAccountID: accountID)
        self.selectedAccountID = accountID
    }

    func setPaused(_ accountID: String, paused: Bool) throws {
        guard let index = self.accounts.firstIndex(where: { $0.id == accountID }) else { throw CursorAccountError.accountNotFound }
        var updated = self.accounts
        updated[index].isPaused = paused
        try self.saveDocument(accounts: updated, selectedAccountID: self.selectedAccountID)
        self.revisions[accountID] = UUID()
        self.inFlight.removeValue(forKey: accountID)
        self.accounts = updated
        var state = self.states[accountID] ?? CursorAccountState()
        state.status = paused || !self.isCollectionEnabled ? .paused : .idle
        state.statusDetail = state.status == .paused ? CursorAccountError.paused.statusDetail : nil
        self.states[accountID] = state
        try self.saveState(state, accountID: accountID)
    }

    func removeAccount(_ accountID: String) throws {
        guard let account = self.accounts.first(where: { $0.id == accountID }) else { throw CursorAccountError.accountNotFound }
        guard !account.isDesktop else { throw CursorAccountError.desktopAccountCannotBeRemoved }
        let updated = self.accounts.filter { $0.id != accountID }
        let selection = self.selectedAccountID == accountID ? updated.first?.id : self.selectedAccountID
        // Metadata removal is committed first: no late refresh or restart can recreate this account.
        try self.saveDocument(accounts: updated, selectedAccountID: selection)
        self.revisions[accountID] = UUID()
        self.inFlight.removeValue(forKey: accountID)
        self.accounts = updated
        self.selectedAccountID = selection
        self.states.removeValue(forKey: accountID)
        self.lastAttempts.removeValue(forKey: accountID)
        do {
            for url in [self.credentialURL(accountID), self.snapshotURL(accountID)] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch { throw CursorAccountError.storageFailure }
    }

    func refreshAll(force: Bool = false, now: Date = Date()) async {
        guard self.isCollectionEnabled else { return }
        let ids = self.accounts.filter { !$0.isPaused }.map(\.id)
        for id in ids { await self.refreshAccount(id, force: force, now: now) }
    }

    func refreshAccount(_ accountID: String, force: Bool = false, now: Date = Date()) async {
        guard self.isCollectionEnabled,
              let account = self.accounts.first(where: { $0.id == accountID }), !account.isPaused,
              self.inFlight[accountID] == nil else { return }
        if !force, let attempt = self.lastAttempts[accountID], now.timeIntervalSince(attempt) < self.refreshInterval { return }
        self.lastAttempts[accountID] = now
        let attempt = UUID()
        let revision = self.revisions[accountID]
        let collectionRevision = self.collectionRevision
        self.inFlight[accountID] = attempt
        var state = self.states[accountID] ?? CursorAccountState()
        state.status = .refreshing
        state.statusDetail = nil
        self.states[accountID] = state
        defer {
            if self.inFlight[accountID] == attempt { self.inFlight.removeValue(forKey: accountID) }
        }
        do {
            let cookie = try self.readCredential(accountID)
            let probe = try await self.service.probe(sessionCookie: cookie, now: now)
            guard self.accepts(accountID, attempt: attempt, revision: revision, collectionRevision: collectionRevision) else { return }
            guard probe.identity.userID == accountID else { throw CursorAccountError.identityMismatch }
            try self.applyIdentity(probe.identity, now: now)
            state.quota = probe.quota
            state.refreshedAt = now
            self.states[accountID] = state
            do {
                let usage = try await self.service.usage(sessionCookie: cookie, now: now, calendar: .current)
                guard self.accepts(accountID, attempt: attempt, revision: revision, collectionRevision: collectionRevision) else { return }
                state.usage = Self.preservingHistory(previous: state.usage, updated: usage)
                state.status = .ready
                state.statusDetail = state.usage?.statusDetail
            } catch {
                guard self.accepts(accountID, attempt: attempt, revision: revision, collectionRevision: collectionRevision) else { return }
                let safe = CursorAccountError.sanitized(error)
                state.status = safe == .authenticationRequired ? .authenticationRequired : .failed
                state.statusDetail = safe.statusDetail
                state.usage = Self.failedUsage(previous: state.usage, now: now, detail: safe.statusDetail)
            }
            self.states[accountID] = state
            try self.saveState(state, accountID: accountID)
        } catch {
            guard self.accepts(accountID, attempt: attempt, revision: revision, collectionRevision: collectionRevision) else { return }
            let safe = CursorAccountError.sanitized(error)
            state.status = safe == .authenticationRequired ? .authenticationRequired : .failed
            state.statusDetail = safe.statusDetail
            if let previousQuota = state.quota {
                state.quota = ToolQuotaSnapshot(client: .cursor,
                    status: safe == .authenticationRequired ? .authenticationRequired : .failed,
                    providerName: previousQuota.providerName, windows: previousQuota.windows,
                    balance: previousQuota.balance, refreshedAt: previousQuota.refreshedAt, statusDetail: safe.statusDetail)
            }
            state.usage = Self.failedUsage(previous: state.usage, now: now, detail: safe.statusDetail)
            self.states[accountID] = state
            try? self.saveState(state, accountID: accountID)
        }
    }

    /// CSV belongs to one explicitly selected account, never the aggregate client cache.
    func importUsage(_ snapshot: ToolUsageSnapshot, accountID: String) throws {
        guard snapshot.client == .cursor, self.accounts.contains(where: { $0.id == accountID }) else { throw CursorAccountError.accountNotFound }
        let safeSnapshot = CursorAccountService.sanitizedUsage(snapshot, cookie: try self.readCredential(accountID))
        self.revisions[accountID] = UUID()
        self.inFlight.removeValue(forKey: accountID)
        var state = self.states[accountID] ?? CursorAccountState()
        state.usage = safeSnapshot
        state.status = self.accounts.first(where: { $0.id == accountID })?.isPaused == true || !self.isCollectionEnabled ? .paused : .ready
        state.statusDetail = state.status == .paused ? CursorAccountError.paused.statusDetail : safeSnapshot.statusDetail
        try self.saveState(state, accountID: accountID)
        self.states[accountID] = state
    }

    private func accepts(_ id: String, attempt: UUID, revision: UUID?, collectionRevision: UUID) -> Bool {
        self.isCollectionEnabled && self.collectionRevision == collectionRevision && self.revisions[id] == revision
            && self.inFlight[id] == attempt && self.accounts.contains { $0.id == id && !$0.isPaused }
    }

    private func saveValidatedAccount(cookie: String, probe: CursorAccountProbe, alias: String?, source: CursorManagedAccount.Source, now: Date) throws {
        let id = probe.identity.userID
        guard id == (try CursorAccountService.userID(sessionCookie: cookie)) else { throw CursorAccountError.identityMismatch }
        var updated = self.accounts
        if let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index].email = probe.identity.email
            updated[index].name = probe.identity.name
            updated[index].planType = probe.identity.planType
            if let alias { updated[index].alias = alias }
            if source == .desktop { updated[index].source = .desktop }
            updated[index].updatedAt = now
        } else {
            guard updated.count < 500 else { throw CursorAccountError.storageFailure }
            updated.append(CursorManagedAccount(id: id, userID: id, email: probe.identity.email, name: probe.identity.name,
                planType: probe.identity.planType, alias: alias ?? "", source: source, isPaused: false, createdAt: now, updatedAt: now))
        }
        let selection = self.selectedAccountID ?? id
        let oldCredential = try? self.readCredential(id)
        do {
            try self.ensureStorageRoot()
            try CursorAccountFileIO.write(try JSONEncoder().encode(Credential(sessionCookie: cookie)), to: self.credentialURL(id))
            try self.saveDocument(accounts: updated, selectedAccountID: selection)
        } catch {
            if let oldCredential {
                try? CursorAccountFileIO.write(try JSONEncoder().encode(Credential(sessionCookie: oldCredential)), to: self.credentialURL(id))
            } else { try? FileManager.default.removeItem(at: self.credentialURL(id)) }
            throw CursorAccountError.storageFailure
        }
        self.revisions[id] = UUID()
        self.inFlight.removeValue(forKey: id)
        self.lastAttempts.removeValue(forKey: id)
        self.accounts = updated
        self.selectedAccountID = selection
        var state = self.states[id] ?? CursorAccountState()
        state.quota = probe.quota
        state.refreshedAt = now
        state.status = updated.first(where: { $0.id == id })?.isPaused == true ? .paused : .ready
        state.statusDetail = state.status == .paused ? CursorAccountError.paused.statusDetail : nil
        self.states[id] = state
        try self.saveState(state, accountID: id)
    }

    private func applyIdentity(_ identity: CursorAccountIdentity, now: Date) throws {
        guard let index = self.accounts.firstIndex(where: { $0.id == identity.userID }) else { throw CursorAccountError.accountNotFound }
        var updated = self.accounts
        updated[index].email = identity.email
        updated[index].name = identity.name
        updated[index].planType = identity.planType
        updated[index].updatedAt = now
        try self.saveDocument(accounts: updated, selectedAccountID: self.selectedAccountID)
        self.accounts = updated
    }

    private func validAlias(_ raw: String, cookie: String) throws -> String {
        let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard alias.utf8.count <= 128, alias.rangeOfCharacter(from: .controlCharacters) == nil,
              alias.isEmpty || CursorAccountService.safeDisplayText(alias, cookie: cookie) != nil else {
            throw CursorAccountError.invalidAlias
        }
        return alias
    }

    private struct Document: Codable { var version = 1; let accounts: [CursorManagedAccount]; let selectedAccountID: String? }
    private nonisolated struct Credential: Codable { let sessionCookie: String }

    private var metadataURL: URL { self.rootURL.appendingPathComponent("accounts.json") }
    private func credentialURL(_ id: String) -> URL { self.rootURL.appendingPathComponent("credentials").appendingPathComponent(id + ".json") }
    private func snapshotURL(_ id: String) -> URL { self.rootURL.appendingPathComponent("snapshots").appendingPathComponent(id + ".json") }

    private func saveDocument(accounts: [CursorManagedAccount], selectedAccountID: String?) throws {
        do {
            try self.ensureStorageRoot()
            try CursorAccountFileIO.write(try JSONEncoder().encode(Document(accounts: accounts, selectedAccountID: selectedAccountID)), to: self.metadataURL)
        }
        catch { throw CursorAccountError.storageFailure }
    }

    private func saveState(_ state: CursorAccountState, accountID: String) throws {
        do {
            try self.ensureStorageRoot()
            try CursorAccountFileIO.write(try JSONEncoder().encode(state), to: self.snapshotURL(accountID))
        }
        catch { throw CursorAccountError.storageFailure }
    }

    private func readCredential(_ id: String) throws -> String {
        do {
            try self.ensureExistingStorageRoot()
            let credential = try JSONDecoder().decode(Credential.self, from: CursorAccountFileIO.read(self.credentialURL(id), limit: 32 * 1024))
            let cookie = try CursorAccountService.normalize(credential.sessionCookie)
            guard try CursorAccountService.userID(sessionCookie: cookie) == id else { throw CursorAccountError.identityMismatch }
            return cookie
        } catch { throw (error as? CursorAccountError) ?? .storageFailure }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: self.metadataURL.path) else { return }
        do {
            try self.ensureExistingStorageRoot()
            let document = try JSONDecoder().decode(Document.self, from: CursorAccountFileIO.read(self.metadataURL, limit: 2 * 1024 * 1024))
            guard document.version == 1, document.accounts.count <= 500,
                  Set(document.accounts.map(\.id)).count == document.accounts.count,
                  document.accounts.allSatisfy({ $0.id == $0.userID && $0.id.range(of: #"^user_[A-Za-z0-9_]+$"#, options: .regularExpression) != nil }) else {
                throw CursorAccountError.storageFailure
            }
            self.accounts = document.accounts
            self.selectedAccountID = self.accounts.contains { $0.id == document.selectedAccountID } ? document.selectedAccountID : self.accounts.first?.id
            for account in self.accounts {
                self.revisions[account.id] = UUID()
                var state = (try? JSONDecoder().decode(CursorAccountState.self, from: CursorAccountFileIO.read(self.snapshotURL(account.id), limit: 64 * 1024 * 1024))) ?? CursorAccountState()
                if state.status == .refreshing { state.status = .idle }
                if account.isPaused || !self.isCollectionEnabled {
                    state.status = .paused
                    state.statusDetail = CursorAccountError.paused.statusDetail
                }
                self.states[account.id] = state
            }
        } catch { self.status = CursorAccountError.storageFailure.statusDetail }
    }

    private func ensureExistingStorageRoot() throws {
        let values = try self.rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CursorAccountError.storageFailure }
    }

    private func ensureStorageRoot() throws {
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try self.ensureExistingStorageRoot()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.path)
    }

    private static func preservingHistory(previous: ToolUsageSnapshot?, updated: ToolUsageSnapshot) -> ToolUsageSnapshot {
        guard updated.dailyEntries.isEmpty, let previous, !previous.dailyEntries.isEmpty else { return updated }
        return ToolUsageSnapshot(client: .cursor, availability: .partial, evidence: previous.evidence,
            dailyEntries: previous.dailyEntries, usageRecords: previous.usageRecords, latestUsageAt: previous.latestUsageAt,
            refreshedAt: updated.refreshedAt, statusDetail: "Cursor 本次未返回用量记录，保留该账号上次用量")
    }

    private static func failedUsage(previous: ToolUsageSnapshot?, now: Date, detail: String) -> ToolUsageSnapshot? {
        guard let previous else { return nil }
        return ToolUsageSnapshot(client: .cursor, availability: .failed, evidence: previous.evidence,
            dailyEntries: previous.dailyEntries, usageRecords: previous.usageRecords, latestUsageAt: previous.latestUsageAt,
            refreshedAt: now, statusDetail: detail)
    }
}

/// O_EXCL creates the temporary file with 0600 immediately, before any secret bytes
/// are written. rename atomically replaces the destination without following it.
private nonisolated enum CursorAccountFileIO {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CursorAccountError.storageFailure }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CursorAccountError.storageFailure }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CursorAccountError.storageFailure }
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        let directory = try url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw CursorAccountError.storageFailure }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CursorAccountError.storageFailure }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size >= 0, attributes.st_size <= Int64(limit) else { throw CursorAccountError.storageFailure }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CursorAccountError.storageFailure }
        return data
    }
}
