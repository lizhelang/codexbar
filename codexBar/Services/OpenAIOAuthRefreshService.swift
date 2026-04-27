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
        let accounts = self.store.accounts.filter { self.shouldRefresh($0, force: false, now: currentTime) }
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

        _ = try? self.store.reconcileAuthJSONIfNeeded(accountID: account.accountId)
        let latestAccount = self.store.oauthAccount(accountID: account.accountId) ?? account
        let now = currentTime.timeIntervalSince1970
        let existingRetryState = self.retryStates[latestAccount.accountId].map { retryState in
            PortableCoreRefreshRetryState(
                attempts: retryState.attempts,
                retryAfter: retryState.retryAfter.timeIntervalSince1970
            )
        }

        do {
            let refreshedAccount = try await self.refreshAction(latestAccount)
            let request = PortableCoreRefreshOutcomeRequest(
                account: .legacy(from: latestAccount),
                now: now,
                maxRetryCount: self.maxRetryCount,
                existingRetryState: existingRetryState,
                outcome: "refreshed",
                refreshedAccount: .legacy(from: refreshedAccount)
            )
            let outcome =
                (try? RustPortableCoreAdapter.shared.applyRefreshOutcome(
                    request,
                    buildIfNeeded: false
                )) ?? PortableCoreLegacyRefreshKernel.applyOutcome(request)
            self.retryStates.removeValue(forKey: latestAccount.accountId)
            self.store.addOrUpdate(outcome.account.tokenAccount())
            return .refreshed(refreshedAccount)
        } catch let oauthError as OpenAIOAuthError where oauthError.isTerminalAuthFailure {
            let request = PortableCoreRefreshOutcomeRequest(
                account: .legacy(from: latestAccount),
                now: now,
                maxRetryCount: self.maxRetryCount,
                existingRetryState: existingRetryState,
                outcome: "terminal_failure",
                refreshedAccount: nil
            )
            let outcome =
                (try? RustPortableCoreAdapter.shared.applyRefreshOutcome(
                    request,
                    buildIfNeeded: false
                )) ?? PortableCoreLegacyRefreshKernel.applyOutcome(request)
            self.retryStates.removeValue(forKey: latestAccount.accountId)
            self.store.addOrUpdate(outcome.account.tokenAccount())
            return .terminalFailure(oauthError.localizedDescription)
        } catch {
            let request = PortableCoreRefreshOutcomeRequest(
                account: .legacy(from: latestAccount),
                now: now,
                maxRetryCount: self.maxRetryCount,
                existingRetryState: existingRetryState,
                outcome: "transient_failure",
                refreshedAccount: nil
            )
            let outcome =
                (try? RustPortableCoreAdapter.shared.applyRefreshOutcome(
                    request,
                    buildIfNeeded: false
                )) ?? PortableCoreLegacyRefreshKernel.applyOutcome(request)
            self.retryStates[latestAccount.accountId] = outcome.nextRetryState.map { retryState in
                RetryState(
                    attempts: retryState.attempts,
                    retryAfter: Date(timeIntervalSince1970: retryState.retryAfter)
                )
            }
            return .transientFailure(error.localizedDescription)
        }
    }

    private func shouldRefresh(_ account: TokenAccount, force: Bool, now: Date) -> Bool {
        let request = PortableCoreRefreshPlanRequest(
            account: .legacy(from: account),
            force: force,
            now: now.timeIntervalSince1970,
            refreshWindowSeconds: self.refreshWindow,
            existingRetryState: nil,
            inFlight: false
        )
        let result =
            (try? RustPortableCoreAdapter.shared.planRefresh(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreLegacyRefreshKernel.plan(request)
        return result.shouldRefresh
    }

}
