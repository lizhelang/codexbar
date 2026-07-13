import Foundation
import SwiftUI

@MainActor
enum CodexBarSettingsWindowPresenter {
    static let windowID = "openai-settings"

    static func open() {
        Self.open(
            store: .shared,
            codexAppPathPanelService: .shared
        )
    }

    static func open(
        store: TokenStore,
        codexAppPathPanelService: CodexAppPathPanelService
    ) {
        store.refreshHistoricalModels()
        DetachedWindowPresenter.shared.show(
            id: Self.windowID,
            title: L.settingsWindowTitle,
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            SettingsWindowView(
                store: store,
                codexAppPathPanelService: codexAppPathPanelService
            ) {
                DetachedWindowPresenter.shared.close(id: Self.windowID)
            }
        }
    }
}
