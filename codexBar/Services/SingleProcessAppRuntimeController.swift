import Foundation

@MainActor
protocol LifecycleControlling: AnyObject {
    func start()
    func stop()
}

@MainActor
protocol OAuthRefreshLifecycleControlling: LifecycleControlling {
    func refreshDueAccountsNow() async
}

@MainActor
protocol TokenStoreReloading: AnyObject {
    func load()
}

protocol MenuHostLegacyCleaning: AnyObject {
    @discardableResult
    func cleanupLegacyArtifacts() -> MenuHostLegacyCleanupResult
}

extension MenuBarStatusItemController: LifecycleControlling {}
extension OpenAIUsagePollingService: LifecycleControlling {}
extension UpdateCoordinator: LifecycleControlling {}
extension OpenAIOAuthRefreshService: OAuthRefreshLifecycleControlling {}
extension TokenStore: TokenStoreReloading {}
extension MenuHostBootstrapService: MenuHostLegacyCleaning {}

@MainActor
final class SingleProcessAppRuntimeController {
    typealias EventRecorder = (_ type: String, _ fields: [String: Any]) -> Void

    private let statusItemHost: any LifecycleControlling
    private let usagePolling: any LifecycleControlling
    private let oauthRefresh: any OAuthRefreshLifecycleControlling
    private let updateCoordinator: any LifecycleControlling
    private let tokenStore: any TokenStoreReloading
    private let legacyMenuHostCleaner: any MenuHostLegacyCleaning
    private let recordEvent: EventRecorder

    init(
        statusItemHost: any LifecycleControlling,
        usagePolling: any LifecycleControlling,
        oauthRefresh: any OAuthRefreshLifecycleControlling,
        updateCoordinator: any LifecycleControlling,
        tokenStore: any TokenStoreReloading,
        legacyMenuHostCleaner: any MenuHostLegacyCleaning,
        recordEvent: @escaping EventRecorder
    ) {
        self.statusItemHost = statusItemHost
        self.usagePolling = usagePolling
        self.oauthRefresh = oauthRefresh
        self.updateCoordinator = updateCoordinator
        self.tokenStore = tokenStore
        self.legacyMenuHostCleaner = legacyMenuHostCleaner
        self.recordEvent = recordEvent
    }

    static func live() -> SingleProcessAppRuntimeController {
        SingleProcessAppRuntimeController(
            statusItemHost: MenuBarStatusItemController.shared,
            usagePolling: OpenAIUsagePollingService.shared,
            oauthRefresh: OpenAIOAuthRefreshService.shared,
            updateCoordinator: UpdateCoordinator.shared,
            tokenStore: TokenStore.shared,
            legacyMenuHostCleaner: MenuHostBootstrapService.shared
        ) { type, fields in
            AppLifecycleDiagnostics.shared.recordEvent(type: type, fields: fields)
        }
    }

    func start() {
        let cleanupResult = self.legacyMenuHostCleaner.cleanupLegacyArtifacts()
        if cleanupResult.hadLegacyArtifacts {
            self.recordEvent(
                "legacy_menu_host_cleaned",
                [
                    "pid": getpid(),
                    "removedAppBundle": cleanupResult.removedAppBundle,
                    "removedLease": cleanupResult.removedLease,
                    "removedRootDirectory": cleanupResult.removedRootDirectory,
                    "terminatedRunningHelper": cleanupResult.terminatedRunningHelper,
                ]
            )
        }

        self.tokenStore.load()
        self.statusItemHost.start()
        self.usagePolling.start()
        self.oauthRefresh.start()
        self.updateCoordinator.start()
        self.recordEvent(
            "single_process_runtime_services_started",
            ["pid": getpid()]
        )
    }

    func stop() {
        self.updateCoordinator.stop()
        self.oauthRefresh.stop()
        self.usagePolling.stop()
        self.statusItemHost.stop()
        self.recordEvent(
            "single_process_runtime_services_stopped",
            ["pid": getpid()]
        )
    }

    func handleApplicationDidBecomeActive() async {
        self.tokenStore.load()
        await self.oauthRefresh.refreshDueAccountsNow()
    }
}
