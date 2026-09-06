import Foundation

enum OpenAIUsagePollingPolicy {
    static let allAccountsRefreshInterval: TimeInterval = 300

    static func accountToRefresh(
        activeProvider: CodexBarProvider?,
        activeAccount: TokenAccount?,
        now: Date,
        maxAge: TimeInterval,
        force: Bool
    ) -> TokenAccount? {
        guard activeProvider?.kind == .openAIOAuth,
              let activeAccount,
              activeAccount.isSuspended == false,
              activeAccount.tokenExpired == false else {
            return nil
        }

        guard force || activeAccount.isUsageSnapshotStale(maxAge: maxAge, now: now) else {
            return nil
        }
        return activeAccount
    }

    static func shouldRefreshAllAccounts(
        lastAllAccountsRefreshAt: Date?,
        now: Date,
        interval: TimeInterval,
        force: Bool
    ) -> Bool {
        if force { return true }
        guard let lastAllAccountsRefreshAt else { return true }
        return now.timeIntervalSince(lastAllAccountsRefreshAt) >= interval
    }
}

@MainActor
final class OpenAIUsagePollingService {
    static let shared = OpenAIUsagePollingService()
    nonisolated static let defaultRefreshInterval: TimeInterval = 60

    private let store: TokenStore
    private let refreshInterval: TimeInterval
    private let now: () -> Date
    private let refreshAction: (TokenAccount, TokenStore) async -> Void
    private let refreshAllAction: (TokenStore) async -> Void

    private var loopTask: Task<Void, Never>?
    private var lastAllAccountsRefreshAt: Date?

    init(
        store: TokenStore? = nil,
        refreshInterval: TimeInterval = OpenAIUsagePollingService.defaultRefreshInterval,
        now: @escaping () -> Date = Date.init,
        refreshAction: @escaping (TokenAccount, TokenStore) async -> Void = { account, store in
            await WhamService.shared.refreshOne(account: account, store: store)
        },
        refreshAllAction: @escaping (TokenStore) async -> Void = { store in
            _ = await WhamService.shared.refreshAll(store: store)
        }
    ) {
        self.store = store ?? .shared
        self.refreshInterval = refreshInterval
        self.now = now
        self.refreshAction = refreshAction
        self.refreshAllAction = refreshAllAction
    }

    func start() {
        guard self.loopTask == nil else { return }

        let sleepDuration = UInt64(max(self.refreshInterval, 1) * 1_000_000_000)
        self.loopTask = Task {
            await self.refreshIfNeeded(force: false)

            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: sleepDuration)
                } catch {
                    break
                }
                await self.refreshIfNeeded(force: false)
            }
        }
    }

    func stop() {
        self.loopTask?.cancel()
        self.loopTask = nil
    }

    func refreshNow() {
        Task {
            // 用户主动触发（例如切换账号后）只刷新当前活跃账号，不要顺带把全部账号都刷一遍。
            // 全量刷新交给后台周期任务（5 分钟一次）负责。
            await self.refreshActiveAccount(force: true)
        }
    }

    private func refreshIfNeeded(force: Bool) async {
        _ = try? self.store.reconcileAuthJSONIfNeeded()
        let now = self.now()
        if OpenAIUsagePollingPolicy.shouldRefreshAllAccounts(
            lastAllAccountsRefreshAt: self.lastAllAccountsRefreshAt,
            now: now,
            interval: OpenAIUsagePollingPolicy.allAccountsRefreshInterval,
            force: force
        ) {
            self.lastAllAccountsRefreshAt = now
            await self.refreshAllAction(self.store)
            return
        }

        await self.refreshActiveAccount(force: false)
    }

    private func refreshActiveAccount(force: Bool) async {
        guard let account = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: self.store.activeProvider,
            activeAccount: self.store.activeAccount(),
            now: self.now(),
            maxAge: self.refreshInterval,
            force: force
        ) else {
            return
        }

        await self.refreshAction(account, self.store)
    }
}
