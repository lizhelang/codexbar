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

    func setManagementToolCollapsed(_ tool: String, collapsed: Bool) {
        guard ApplicationPreferences.allTools.contains(tool),
              self.preferences.isManagementToolCollapsed(tool) != collapsed else { return }
        self.update { preferences in
            preferences.collapsedManagementTools.removeAll { $0 == tool }
            if collapsed { preferences.collapsedManagementTools.append(tool) }
        }
    }

    func toggleManagementToolCollapsed(_ tool: String) {
        self.setManagementToolCollapsed(tool, collapsed: !self.preferences.isManagementToolCollapsed(tool))
    }

    /// Moves a section in the shared software order, including Codex and paused clients.
    /// An out-of-range destination stops at the nearest edge; unknown IDs are ignored.
    func moveManagementTool(_ tool: String, by offset: Int) {
        guard ApplicationPreferences.allTools.contains(tool),
              let index = self.preferences.toolOrder.firstIndex(of: tool) else { return }
        let boundedOffset = min(max(offset, -index), self.preferences.toolOrder.count - 1 - index)
        guard boundedOffset != 0 else { return }
        self.update { preferences in
            preferences.toolOrder.remove(at: index)
            preferences.toolOrder.insert(tool, at: index + boundedOffset)
        }
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
