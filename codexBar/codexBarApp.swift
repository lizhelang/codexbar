import SwiftUI

@main
struct codexBarApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleObserver.self) private var lifecycleObserver

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L.settings) {
                    CodexBarSettingsWindowPresenter.open()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
