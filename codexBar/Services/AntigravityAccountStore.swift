import AppKit
import Combine
import Darwin
import Foundation

extension Notification.Name {
    static let antigravityLoginDidSucceed = Notification.Name("codexbar.antigravityLoginDidSucceed")
    static let antigravityLoginDidFail = Notification.Name("codexbar.antigravityLoginDidFail")
}

private struct AntigravityAccountsIndex: Codable {
    var version: Int = 1
    var activeAccountID: String?
    var accounts: [AntigravityAccount]
}

@MainActor
final class AntigravityAccountStore: ObservableObject {
    static let shared = AntigravityAccountStore()

    @Published private(set) var accounts: [AntigravityAccount] = []
    @Published private(set) var activeAccountID: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshingAccountIDs: Set<String> = []
    @Published private(set) var statusMessage: String?

    let rootURL: URL
    let showsEmptySection: Bool
    private let service: any AntigravityAccountServicing
    private let localSync: AntigravityLocalCredentialSync
    private let autoDiscoverLocalCredentials: Bool
    private var lastFullRefreshAt: Date?

    var activeAccount: AntigravityAccount? {
        if let activeAccountID,
           let matched = self.accounts.first(where: { $0.id == activeAccountID }) {
            return matched
        }
        return self.accounts.first(where: \.isActive) ?? self.accounts.first
    }

    var availableCount: Int {
        self.accounts.filter { $0.status == .ok && $0.hasAvailableQuota }.count
    }

    init(
        rootURL: URL? = nil,
        service: any AntigravityAccountServicing = AntigravityAccountService(),
        localSync: AntigravityLocalCredentialSync? = nil,
        showsEmptySection: Bool? = nil,
        autoDiscoverLocalCredentials: Bool? = nil
    ) {
        let isIsolatedTestEnv = ProcessInfo.processInfo.environment["CODEXBAR_HOME"] != nil && rootURL == nil
        self.rootURL = rootURL ?? CodexPaths.codexBarRoot.appendingPathComponent("antigravity-accounts", isDirectory: true)
        self.service = service
        self.localSync = localSync ?? AntigravityLocalCredentialSync()
        self.showsEmptySection = showsEmptySection ?? !isIsolatedTestEnv
        self.autoDiscoverLocalCredentials = autoDiscoverLocalCredentials ?? !isIsolatedTestEnv
        self.load()
        if rootURL == nil, !isIsolatedTestEnv, !self.accounts.isEmpty {
            Task { @MainActor [weak self] in
                await self?.refreshAllIfNeeded(force: false)
            }
        }
    }

    private var indexFileURL: URL {
        self.rootURL.appendingPathComponent("accounts.json")
    }

    private var credentialsDirectoryURL: URL {
        self.rootURL.appendingPathComponent("credentials", isDirectory: true)
    }

    private func credentialFileURL(for accountID: String) -> URL {
        let safeName = accountID.replacingOccurrences(of: "/", with: "_")
        return self.credentialsDirectoryURL.appendingPathComponent("\(safeName).json")
    }

    func load() {
        var loadedAccounts: [AntigravityAccount] = []
        var loadedActiveID: String?

        if let data = try? Data(contentsOf: self.indexFileURL),
           let decoded = try? JSONDecoder().decode(AntigravityAccountsIndex.self, from: data) {
            loadedAccounts = decoded.accounts
            loadedActiveID = decoded.activeAccountID
        }

        if self.autoDiscoverLocalCredentials,
           let localTokenFile = self.localSync.readLocalTokenFile() {
            let claims = AntigravityJWTClaims.decode(jwt: localTokenFile.idToken)
            let localID = self.resolveLocalAccountID(
                tokenFile: localTokenFile,
                claims: claims,
                existingAccounts: loadedAccounts
            )
            if let existingIndex = loadedAccounts.firstIndex(where: { $0.id == localID }) {
                if let email = claims?.email, !email.isEmpty {
                    loadedAccounts[existingIndex].email = email
                }
                if let name = claims?.name, !name.isEmpty {
                    loadedAccounts[existingIndex].displayName = name
                }
                if let sub = claims?.subject, !sub.isEmpty {
                    loadedAccounts[existingIndex].userID = sub
                }
                // Reading the application's older token must not undo a refresh in our own cache.
                let savedTokenFile = self.loadCredentialFile(for: localID)
                let keepsRefreshedToken = savedTokenFile.map {
                    !$0.token.refreshToken.isEmpty &&
                        $0.token.refreshToken == localTokenFile.token.refreshToken &&
                        $0.token.expiry > localTokenFile.token.expiry
                } ?? false
                if !keepsRefreshedToken {
                    try? self.saveCredentialFile(localTokenFile, for: localID)
                }
            } else {
                let discovered = AntigravityAccount(
                    id: localID,
                    email: claims?.email ?? "",
                    displayName: claims?.name,
                    userID: claims?.subject,
                    tierID: "free-tier",
                    tierName: "Antigravity",
                    cloudAICompanionProject: "aicode-consumers",
                    quotaWindows: [],
                    status: .ok,
                    statusMessage: nil,
                    addedAt: Date(),
                    lastUpdatedAt: nil,
                    isActive: true
                )
                loadedAccounts.insert(discovered, at: 0)
                try? self.saveCredentialFile(localTokenFile, for: localID)
            }
            loadedActiveID = localID
        }

        if loadedActiveID == nil || !loadedAccounts.contains(where: { $0.id == loadedActiveID }) {
            loadedActiveID = loadedAccounts.first?.id
        }

        for index in loadedAccounts.indices {
            loadedAccounts[index].isActive = (loadedAccounts[index].id == loadedActiveID)
        }

        self.accounts = loadedAccounts
        self.activeAccountID = loadedActiveID
        self.saveIndex()
    }

    private func resolveLocalAccountID(
        tokenFile: AntigravityTokenFile,
        claims: AntigravityJWTClaims?,
        existingAccounts: [AntigravityAccount]
    ) -> String {
        if let sub = claims?.subject, !sub.isEmpty {
            let candidate = AntigravityAccount.makeStableID(
                userID: sub,
                email: claims?.email,
                refreshToken: tokenFile.token.refreshToken
            )
            if existingAccounts.contains(where: { $0.id == candidate || $0.userID == sub }) {
                return existingAccounts.first(where: { $0.id == candidate || $0.userID == sub })!.id
            }
            return candidate
        }
        if let email = claims?.email?.lowercased(), !email.isEmpty,
           let matched = existingAccounts.first(where: { $0.email.lowercased() == email }) {
            return matched.id
        }
        for account in existingAccounts {
            if let saved = self.loadCredentialFile(for: account.id),
               !saved.token.refreshToken.isEmpty,
               saved.token.refreshToken == tokenFile.token.refreshToken {
                return account.id
            }
        }
        return AntigravityAccount.makeStableID(
            userID: claims?.subject,
            email: claims?.email,
            refreshToken: tokenFile.token.refreshToken
        )
    }

    func loadCredentialFile(for accountID: String) -> AntigravityTokenFile? {
        let url = self.credentialFileURL(for: accountID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? AntigravityTokenFile.parse(data: data)
    }

    private func saveCredentialFile(_ tokenFile: AntigravityTokenFile, for accountID: String) throws {
        try FileManager.default.createDirectory(at: self.credentialsDirectoryURL, withIntermediateDirectories: true)
        _ = chmod(self.credentialsDirectoryURL.path, S_IRWXU)
        let url = self.credentialFileURL(for: accountID)
        let data = try tokenFile.serializedData()
        try data.write(to: url, options: .atomic)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
            _ = chmod(self.rootURL.path, S_IRWXU)
            let index = AntigravityAccountsIndex(
                version: 1,
                activeAccountID: self.activeAccountID,
                accounts: self.accounts
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(index)
            try data.write(to: self.indexFileURL, options: .atomic)
            _ = chmod(self.indexFileURL.path, S_IRUSR | S_IWUSR)
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func importTokenJSON(_ rawJSON: String, activate: Bool = true) async throws -> AntigravityAccount {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw AntigravityAccountError.invalidTokenPayload
        }
        let tokenFile = try AntigravityTokenFile.parse(data: data)
        return try await self.importTokenFile(tokenFile, activate: activate)
    }

    @discardableResult
    func importTokenFile(_ tokenFile: AntigravityTokenFile, activate: Bool = true) async throws -> AntigravityAccount {
        let probe = try await self.service.probeAccount(tokenFile: tokenFile, forceRefresh: false)
        let accountID = self.resolveImportedAccountID(probe: probe)
        let now = Date()

        try self.saveCredentialFile(probe.tokenFile, for: accountID)

        var updatedAccounts = self.accounts
        let existingAddedAt = updatedAccounts.first(where: { $0.id == accountID })?.addedAt ?? now
        let shouldActivate = activate || updatedAccounts.isEmpty || self.activeAccountID == accountID

        let account = AntigravityAccount(
            id: accountID,
            email: probe.email,
            displayName: probe.displayName,
            userID: probe.userID,
            tierID: probe.tierID,
            tierName: probe.tierName,
            cloudAICompanionProject: probe.cloudAICompanionProject,
            quotaWindows: probe.quotaWindows,
            status: .ok,
            statusMessage: nil,
            addedAt: existingAddedAt,
            lastUpdatedAt: now,
            isActive: shouldActivate
        )

        if let index = updatedAccounts.firstIndex(where: { $0.id == accountID }) {
            updatedAccounts[index] = account
        } else {
            updatedAccounts.append(account)
        }

        if shouldActivate {
            try self.localSync.writeLocalTokenFile(probe.tokenFile)
            self.activeAccountID = accountID
        }

        for idx in updatedAccounts.indices {
            updatedAccounts[idx].isActive = (updatedAccounts[idx].id == self.activeAccountID)
        }

        self.accounts = updatedAccounts
        self.statusMessage = nil
        self.saveIndex()
        return self.accounts.first(where: { $0.id == accountID }) ?? account
    }

    private func resolveImportedAccountID(probe: AntigravityAccountProbeResult) -> String {
        if let userID = probe.userID, !userID.isEmpty,
           let existing = self.accounts.first(where: { $0.userID == userID }) {
            return existing.id
        }
        if !probe.email.isEmpty,
           let existing = self.accounts.first(where: { $0.email.lowercased() == probe.email.lowercased() }) {
            return existing.id
        }
        return AntigravityAccount.makeStableID(
            userID: probe.userID,
            email: probe.email,
            refreshToken: probe.tokenFile.token.refreshToken
        )
    }

    func activateAccount(_ account: AntigravityAccount) throws {
        guard let tokenFile = self.loadCredentialFile(for: account.id) else {
            throw AntigravityAccountError.accountNotFound
        }
        try self.localSync.writeLocalTokenFile(tokenFile)
        self.activeAccountID = account.id
        for index in self.accounts.indices {
            self.accounts[index].isActive = (self.accounts[index].id == account.id)
        }
        self.statusMessage = nil
        self.saveIndex()
    }

    func removeAccount(_ account: AntigravityAccount) {
        let removedID = account.id
        try? FileManager.default.removeItem(at: self.credentialFileURL(for: removedID))
        self.accounts.removeAll { $0.id == removedID }
        if self.activeAccountID == removedID {
            self.activeAccountID = self.accounts.first?.id
            if let nextActive = self.accounts.first,
               let nextToken = self.loadCredentialFile(for: nextActive.id) {
                try? self.localSync.writeLocalTokenFile(nextToken)
            }
        }
        for index in self.accounts.indices {
            self.accounts[index].isActive = (self.accounts[index].id == self.activeAccountID)
        }
        self.saveIndex()
    }

    func refreshAllIfNeeded(force: Bool = false, minimumInterval: TimeInterval = 60) async {
        if !force,
           let lastFullRefreshAt = self.lastFullRefreshAt,
           Date().timeIntervalSince(lastFullRefreshAt) < minimumInterval,
           self.accounts.allSatisfy({ !$0.quotaWindows.isEmpty }) {
            return
        }
        await self.refreshAll(force: force)
    }

    func refreshAll(force: Bool = false) async {
        guard !self.isRefreshing else { return }
        if self.autoDiscoverLocalCredentials {
            self.load()
        }
        guard !self.accounts.isEmpty else { return }

        self.isRefreshing = true
        self.lastFullRefreshAt = Date()
        defer { self.isRefreshing = false }

        let snapshot = self.accounts
        for account in snapshot {
            await self.refreshAccount(account, forceRefreshToken: false)
        }
    }

    func refreshAccount(_ account: AntigravityAccount, forceRefreshToken: Bool = false) async {
        guard !self.refreshingAccountIDs.contains(account.id) else { return }
        guard let tokenFile = self.loadCredentialFile(for: account.id) else {
            self.markAccountFailure(
                accountID: account.id,
                status: .reauthRequired,
                message: AntigravityAccountError.missingRefreshToken.localizedDescription
            )
            return
        }

        self.refreshingAccountIDs.insert(account.id)
        defer { self.refreshingAccountIDs.remove(account.id) }

        do {
            let probe = try await self.service.probeAccount(
                tokenFile: tokenFile,
                forceRefresh: forceRefreshToken
            )
            try self.saveCredentialFile(probe.tokenFile, for: account.id)
            guard let index = self.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            if !probe.email.isEmpty {
                self.accounts[index].email = probe.email
            }
            if let displayName = probe.displayName, !displayName.isEmpty {
                self.accounts[index].displayName = displayName
            }
            if let userID = probe.userID, !userID.isEmpty {
                self.accounts[index].userID = userID
            }
            self.accounts[index].tierID = probe.tierID
            self.accounts[index].tierName = probe.tierName
            self.accounts[index].cloudAICompanionProject = probe.cloudAICompanionProject
            self.accounts[index].quotaWindows = probe.quotaWindows
            self.accounts[index].status = .ok
            self.accounts[index].statusMessage = nil
            self.accounts[index].lastUpdatedAt = Date()
            self.saveIndex()
        } catch let error as AntigravityAccountError {
            let isAuthFailure: Bool
            switch error {
            case .missingRefreshToken, .authorizationExpired:
                isAuthFailure = true
            default:
                isAuthFailure = false
            }
            self.markAccountFailure(
                accountID: account.id,
                status: isAuthFailure ? .reauthRequired : .error,
                message: error.localizedDescription
            )
        } catch {
            self.markAccountFailure(
                accountID: account.id,
                status: .error,
                message: error.localizedDescription
            )
        }
    }

    private func markAccountFailure(
        accountID: String,
        status: AntigravityAccountStatus,
        message: String
    ) {
        guard let index = self.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        self.accounts[index].status = status
        self.accounts[index].statusMessage = message
        self.saveIndex()
    }
}

@MainActor
final class AntigravityLoginCoordinator: ObservableObject {
    static let shared = AntigravityLoginCoordinator()

    @Published private(set) var activeSession: AntigravityOAuthSession?
    @Published private(set) var isExchanging = false
    @Published var errorMessage: String?

    private var callbackServer: LocalhostOAuthCallbackServer?
    private let service: any AntigravityAccountServicing

    init(service: any AntigravityAccountServicing = AntigravityAccountService()) {
        self.service = service
    }

    func startBrowserOAuth(store: AntigravityAccountStore = .shared, openBrowser: Bool = true) {
        self.stopServer()
        self.errorMessage = nil

        var startedServer: LocalhostOAuthCallbackServer?
        var chosenPort: UInt16 = 51121
        for candidate in UInt16(51121)...UInt16(51145) {
            let server = LocalhostOAuthCallbackServer(
                port: candidate,
                callbackPath: "/auth/callback"
            ) { [weak self] callbackURL in
                guard let self else { return }
                Task { @MainActor in
                    await self.completeCallback(callbackInput: callbackURL, store: store)
                }
            }
            if (try? server.start()) != nil {
                startedServer = server
                chosenPort = candidate
                break
            }
        }

        self.callbackServer = startedServer
        do {
            let session = try self.service.makeAuthorizationSession(port: chosenPort)
            self.activeSession = session
            if openBrowser {
                NSWorkspace.shared.open(session.authorizationURL)
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func completeCallback(
        callbackInput: String,
        store: AntigravityAccountStore = .shared
    ) async -> Bool {
        guard let session = self.activeSession else {
            self.errorMessage = AntigravityAccountError.invalidOAuthCallback.localizedDescription
            return false
        }
        guard !self.isExchanging else { return false }
        self.isExchanging = true
        self.errorMessage = nil
        defer { self.isExchanging = false }

        do {
            let tokenFile = try await self.service.exchangeCallback(
                callbackInput: callbackInput,
                session: session
            )
            _ = try await store.importTokenFile(tokenFile, activate: true)
            self.stop()
            DetachedWindowPresenter.shared.close(id: "add-antigravity-account")
            NotificationCenter.default.post(name: .antigravityLoginDidSucceed, object: nil)
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            NotificationCenter.default.post(
                name: .antigravityLoginDidFail,
                object: nil,
                userInfo: ["message": error.localizedDescription]
            )
            return false
        }
    }

    func importManualTokenJSON(
        _ rawJSON: String,
        store: AntigravityAccountStore = .shared
    ) async -> Bool {
        guard !self.isExchanging else { return false }
        self.isExchanging = true
        self.errorMessage = nil
        defer { self.isExchanging = false }

        do {
            _ = try await store.importTokenJSON(rawJSON, activate: true)
            self.stop()
            DetachedWindowPresenter.shared.close(id: "add-antigravity-account")
            NotificationCenter.default.post(name: .antigravityLoginDidSucceed, object: nil)
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func stop() {
        self.stopServer()
        self.activeSession = nil
        self.isExchanging = false
    }

    private func stopServer() {
        self.callbackServer?.stop()
        self.callbackServer = nil
    }
}
