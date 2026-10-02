import Foundation

enum OpenAIOAuthRefreshOutcome {
    case refreshed(TokenAccount)
    case terminalFailure(String)
    case transientFailure(String)
    case skipped
}

@MainActor
final class OpenAIOAuthRefreshService {
    nonisolated static let defaultRefreshInterval: TimeInterval = 5 * 60
    nonisolated static let defaultRefreshWindow: TimeInterval = 30 * 60

    static let shared = OpenAIOAuthRefreshService(store: TokenStore.shared)

    private struct RetryState {
        let attempts: Int
        let retryAfter: Date
    }

    private struct LiveAuthCredentials: Equatable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let accountID: String?
        let clientID: String?

        static func read() -> Self? {
            guard let data = try? Data(contentsOf: CodexPaths.authURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = object["tokens"] as? [String: Any],
                  let accessToken = tokens["access_token"] as? String,
                  !accessToken.isEmpty else { return nil }
            return Self(
                accessToken: accessToken,
                refreshToken: tokens["refresh_token"] as? String,
                idToken: tokens["id_token"] as? String,
                accountID: tokens["account_id"] as? String,
                clientID: object["client_id"] as? String
            )
        }
    }

    private let store: TokenStore
    private let refreshInterval: TimeInterval
    private let refreshWindow: TimeInterval
    private let maxRetryCount: Int
    private let now: () -> Date
    private let refreshAction: (TokenAccount) async throws -> TokenAccount

    private var loopTask: Task<Void, Never>?
    private var inFlightAccountIDs: Set<String> = []
    private var retryStates: [String: RetryState] = [:]

    init(
        store: TokenStore,
        refreshInterval: TimeInterval = OpenAIOAuthRefreshService.defaultRefreshInterval,
        refreshWindow: TimeInterval = OpenAIOAuthRefreshService.defaultRefreshWindow,
        maxRetryCount: Int = 3,
        now: @escaping () -> Date = Date.init,
        refreshAction: @escaping (TokenAccount) async throws -> TokenAccount = { account in
            try await OpenAIOAuthFlowService().refreshAccount(account)
        }
    ) {
        self.store = store
        self.refreshInterval = refreshInterval
        self.refreshWindow = refreshWindow
        self.maxRetryCount = maxRetryCount
        self.now = now
        self.refreshAction = refreshAction
    }

    func start() {
        guard self.loopTask == nil else { return }

        let sleepDuration = UInt64(max(self.refreshInterval, 1) * 1_000_000_000)
        self.loopTask = Task {
            await self.refreshDueAccountsNow()

            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: sleepDuration)
                } catch {
                    break
                }
                await self.refreshDueAccountsNow()
            }
        }
    }

    func stop() {
        self.loopTask?.cancel()
        self.loopTask = nil
        self.inFlightAccountIDs.removeAll()
        self.retryStates.removeAll()
    }

    func refreshDueAccountsNow() async {
        let currentTime = self.now()
        var candidates = self.store.accounts
        if let remoteConnectionAccount = self.store.remoteConnectionAccount,
           candidates.contains(where: { $0.accountId == remoteConnectionAccount.accountId }) == false {
            candidates.append(remoteConnectionAccount)
        }
        let accounts = candidates.filter { self.shouldRefresh($0, force: false, now: currentTime) }
        for account in accounts {
            _ = await self.refreshNow(account: account, force: false)
        }
    }

    func refreshNow(account: TokenAccount, force: Bool = true) async -> OpenAIOAuthRefreshOutcome {
        let currentTime = self.now()
        guard self.shouldRefresh(account, force: force, now: currentTime) else {
            return .skipped
        }

        if let retryState = self.retryStates[account.accountId],
           retryState.retryAfter > currentTime {
            return .skipped
        }
        guard self.inFlightAccountIDs.insert(account.accountId).inserted else {
            return .skipped
        }
        defer {
            self.inFlightAccountIDs.remove(account.accountId)
        }

        let authSnapshot = LiveAuthCredentials.read()
        _ = try? self.store.reconcileAuthJSONIfNeeded(accountID: account.accountId)
        guard let latestAccount = self.latestStoredAccount(matching: account),
              latestAccount.remoteAccountId == account.remoteAccountId,
              self.shouldRefresh(latestAccount, force: force, now: currentTime) else {
            return .skipped
        }

        do {
            let refreshedAccount = try await self.refreshAction(latestAccount)
            self.retryStates.removeValue(forKey: latestAccount.accountId)
            do {
                return try self.persistOAuthRefreshResult(
                    refreshedAccount,
                    replacing: latestAccount,
                    authSnapshot: authSnapshot
                )
            } catch {
                return .transientFailure(error.localizedDescription)
            }
        } catch let oauthError as OpenAIOAuthError where oauthError.isTerminalAuthFailure {
            self.retryStates.removeValue(forKey: latestAccount.accountId)
            do {
                return try self.persistOAuthRefreshResult(
                    latestAccount,
                    replacing: latestAccount,
                    authSnapshot: authSnapshot,
                    terminalFailure: oauthError.localizedDescription
                )
            } catch {
                return .transientFailure(error.localizedDescription)
            }
        } catch {
            guard let current = self.latestStoredAccount(matching: latestAccount),
                  current.remoteAccountId == latestAccount.remoteAccountId else { return .skipped }
            guard self.hasSameCredentials(current, as: latestAccount) else {
                self.retryStates.removeValue(forKey: latestAccount.accountId)
                return .refreshed(current)
            }
            self.retryStates[latestAccount.accountId] = self.nextRetryState(
                existing: self.retryStates[latestAccount.accountId],
                now: currentTime
            )
            return .transientFailure(error.localizedDescription)
        }
    }

    private func latestStoredAccount(matching account: TokenAccount) -> TokenAccount? {
        if let oauthAccount = self.store.oauthAccount(accountID: account.accountId) {
            return oauthAccount
        }
        if let remoteConnectionAccount = self.store.remoteConnectionAccount,
           remoteConnectionAccount.accountId == account.accountId {
            return remoteConnectionAccount
        }
        return self.store.remoteConnectionAccounts.first { $0.accountId == account.accountId }
    }

    private func persistOAuthRefreshResult(
        _ result: TokenAccount,
        replacing source: TokenAccount,
        authSnapshot: LiveAuthCredentials?,
        terminalFailure: String? = nil
    ) throws -> OpenAIOAuthRefreshOutcome {
        guard let beforeReconcile = self.latestStoredAccount(matching: source),
              beforeReconcile.remoteAccountId == source.remoteAccountId else { return .skipped }
        guard self.hasSameCredentials(beforeReconcile, as: source) else {
            return .refreshed(beforeReconcile)
        }
        // 只吸收请求期间真正轮换的凭据；旧文件的格式或其他元数据变化不算轮换。
        if let liveAuth = LiveAuthCredentials.read(), liveAuth != authSnapshot {
            _ = try self.store.reconcileAuthJSONIfNeeded(
                accountID: source.accountId,
                preferLiveCredentials: true
            )
        }
        guard var current = self.latestStoredAccount(matching: source),
              current.remoteAccountId == source.remoteAccountId else { return .skipped }
        guard self.hasSameCredentials(current, as: source) else {
            return .refreshed(current)
        }
        guard result.accountId == source.accountId,
              result.remoteAccountId == source.remoteAccountId else {
            return .transientFailure(L.authRecoveryDeferredMsg)
        }

        if terminalFailure != nil {
            current.tokenExpired = true
        } else {
            // 只合并本次轮换的凭据，保留请求期间更新的资料、额度和暂停状态。
            current.accessToken = result.accessToken
            current.refreshToken = result.refreshToken
            current.idToken = result.idToken
            current.expiresAt = result.expiresAt
            current.oauthClientID = result.oauthClientID ?? current.oauthClientID
            current.tokenLastRefreshAt = result.tokenLastRefreshAt
            if current.tokenExpired == source.tokenExpired {
                current.tokenExpired = result.tokenExpired
            }
        }

        if self.store.oauthAccount(accountID: source.accountId) != nil {
            self.store.addOrUpdate(current, reconcileActiveAuth: false)
        } else {
            _ = try self.store.importRemoteConnectionAccount(
                current,
                activate: false,
                reconcileActiveAuth: false
            )
        }
        guard let saved = self.latestStoredAccount(matching: source) else { return .skipped }
        if let terminalFailure { return .terminalFailure(terminalFailure) }
        return .refreshed(saved)
    }

    private func hasSameCredentials(_ lhs: TokenAccount, as rhs: TokenAccount) -> Bool {
        lhs.accessToken == rhs.accessToken &&
            lhs.refreshToken == rhs.refreshToken &&
            lhs.idToken == rhs.idToken &&
            lhs.expiresAt == rhs.expiresAt &&
            lhs.oauthClientID == rhs.oauthClientID &&
            lhs.tokenLastRefreshAt == rhs.tokenLastRefreshAt
    }

    private func shouldRefresh(_ account: TokenAccount, force: Bool, now: Date) -> Bool {
        guard account.isSuspended == false else { return false }
        if force { return true }
        guard account.tokenExpired == false else { return false }
        guard let expiresAt = account.expiresAt else {
            return account.tokenLastRefreshAt == nil
        }
        return expiresAt.timeIntervalSince(now) <= self.refreshWindow
    }

    private func nextRetryState(existing: RetryState?, now: Date) -> RetryState {
        let attempts = min((existing?.attempts ?? 0) + 1, self.maxRetryCount)
        let backoffMinutes = pow(2.0, Double(max(0, attempts - 1)))
        return RetryState(
            attempts: attempts,
            retryAfter: now.addingTimeInterval(backoffMinutes * 60)
        )
    }
}
