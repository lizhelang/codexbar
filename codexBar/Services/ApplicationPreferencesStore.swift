import Combine
import Foundation

@MainActor
final class ApplicationPreferencesStore: ObservableObject {
    static let shared = ApplicationPreferencesStore()
    static let defaultsKey = "codexbar.application.preferences.v1"
    private static let legacyHeightKey = "codexbar.menuBarPopoverPreferredHeight"

    @Published private(set) var preferences: ApplicationPreferences
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(ApplicationPreferences.self, from: data) {
            var restored = decoded
            if defaults.object(forKey: Self.legacyHeightKey) != nil {
                restored.preferredMenuHeight = defaults.double(forKey: Self.legacyHeightKey)
                restored.normalize()
            }
            self.preferences = restored
        } else {
            var initial = ApplicationPreferences()
            if defaults.object(forKey: "languageOverride") != nil {
                initial.language = defaults.bool(forKey: "languageOverride") ? .simplifiedChinese : .english
            }
            initial.preferredMenuHeight = defaults.double(forKey: Self.legacyHeightKey)
            initial.normalize()
            self.preferences = initial
        }
        self.applyLegacyPreferences()
    }

    func update(_ transform: (inout ApplicationPreferences) -> Void) {
        var updated = self.preferences
        transform(&updated)
        updated.normalize()
        guard updated != self.preferences else { return }
        let heightChanged = updated.preferredMenuHeight != self.preferences.preferredMenuHeight
        self.preferences = updated
        if let data = try? JSONEncoder().encode(updated) { self.defaults.set(data, forKey: Self.defaultsKey) }
        self.applyLegacyPreferences(updateHeight: heightChanged)
    }

    private func applyLegacyPreferences(updateHeight: Bool = false) {
        switch self.preferences.language {
        case .system: self.defaults.removeObject(forKey: "languageOverride")
        case .simplifiedChinese: self.defaults.set(true, forKey: "languageOverride")
        case .english: self.defaults.set(false, forKey: "languageOverride")
        }
        if updateHeight { self.defaults.set(self.preferences.preferredMenuHeight, forKey: Self.legacyHeightKey) }
    }
}
