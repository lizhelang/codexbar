import SwiftUI

@main
struct codexBarApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleObserver.self) private var lifecycleObserver

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(MenuHostBootstrapService.isMenuHostProcess)) {
            MenuBarView()
                .environmentObject(TokenStore.shared)
                .environmentObject(OAuthManager.shared)
                .environmentObject(UpdateCoordinator.shared)
        } label: {
            MenuBarIconView(
                store: TokenStore.shared,
                updateCoordinator: UpdateCoordinator.shared
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
