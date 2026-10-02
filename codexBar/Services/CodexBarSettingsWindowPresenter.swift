import Foundation
import SwiftUI

@MainActor
enum CodexBarSettingsWindowPresenter {
    static let windowID = "openai-settings"

    static func open() {
        Self.open(store: .shared)
    }

    static func open(store: TokenStore) {
        store.refreshHistoricalModels()
        DetachedWindowPresenter.shared.show(
            id: Self.windowID,
            title: L.settingsWindowTitle,
            size: CGSize(width: 540, height: 720),
            configuration: .openAISettings
        ) {
            SettingsWindowView(
                store: store
            ) {
                DetachedWindowPresenter.shared.close(id: Self.windowID)
            }
        }
    }
}
