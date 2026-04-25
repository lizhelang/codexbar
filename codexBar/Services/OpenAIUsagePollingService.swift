import Foundation

enum OpenAIUsagePollingPolicy {
    static func accountToRefresh(
        activeProvider: CodexBarProvider?,
        activeAccount: TokenAccount?,
        now: Date,
        maxAge: TimeInterval,
        force: Bool
    ) -> TokenAccount? {
        let decision =
            (try? RustPortableCoreAdapter.shared.planUsagePolling(
            PortableCoreUsagePollingPlanRequest(
                activeProviderKind: activeProvider?.kind.rawValue,
                activeAccount: activeAccount.map(PortableCoreUsagePollingAccount.legacy(from:)),
                now: now.timeIntervalSince1970,
                maxAgeSeconds: maxAge,
                force: force
            ),
            buildIfNeeded: false
        )) ?? PortableCoreUsagePollingPlanResult.failClosed()
        guard decision.shouldRefresh else {
            return nil
        }
        return activeAccount
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

    private var loopTask: Task<Void, Never>?

    init(
        store: TokenStore? = nil,
        refreshInterval: TimeInterval = OpenAIUsagePollingService.defaultRefreshInterval,
        now: @escaping () -> Date = Date.init,
        refreshAction: @escaping (TokenAccount, TokenStore) async -> Void = { account, store in
            await WhamService.shared.refreshOne(account: account, store: store)
        }
    ) {
        self.store = store ?? .shared
        self.refreshInterval = refreshInterval
        self.now = now
        self.refreshAction = refreshAction
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
            await self.refreshIfNeeded(force: true)
        }
    }

    private func refreshIfNeeded(force: Bool) async {
        _ = try? self.store.reconcileAuthJSONIfNeeded()
        let now = self.now()
        let activeAccount = self.store.activeAccount()
        guard let account = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: self.store.activeProvider,
            activeAccount: activeAccount,
            now: now,
            maxAge: self.refreshInterval,
            force: force
        ) else {
            return
        }

        await self.refreshAction(account, self.store)
    }
}
