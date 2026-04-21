import AppKit
import Foundation

enum MenuBarStatusItemIdentity {
    static let popoverContentWidth: CGFloat = 300
    static let accessibilityLabel = "codexbar"
    static let accessibilityIdentifier = "codexbar.status-item"
    static let statusItemAutosaveName: NSStatusItem.AutosaveName = "lzhl.codexbar.menu-bar-status-item"
    static let statusItemBehavior: NSStatusItem.Behavior = [
        .removalAllowed,
    ]
    static let legacyStatusItemAutosaveNames: [NSStatusItem.AutosaveName] = [
        "lzhl.codexAppBar.menu-bar-status-item",
    ]
    static let legacyVisibilityPreferenceKeys = [
        "menuBarExtra.isInserted",
        "codexbar.menu-bar-extra.is-inserted",
    ]

    static var namedVisibleKeys: [String] {
        self.namedVisibleKeys(for: [self.statusItemAutosaveName])
    }

    static var legacyNamedVisibleKeys: [String] {
        self.namedVisibleKeys(for: self.legacyStatusItemAutosaveNames)
    }

    static func resolvedVisibility(domain: [String: Any]) -> Bool {
        if let namedVisibility = self.namedVisibility(
            domain: domain,
            autosaveNames: [self.statusItemAutosaveName]
        ) {
            return namedVisibility
        }
        if let legacyNamedVisibility = self.namedVisibility(
            domain: domain,
            autosaveNames: self.legacyStatusItemAutosaveNames
        ) {
            return legacyNamedVisibility
        }
        for key in self.legacyVisibilityPreferenceKeys {
            if let value = self.boolValue(domain[key]) {
                return value
            }
        }
        return true
    }

    static func shouldRepairVisibility(domain: [String: Any]) -> Bool {
        let hasCurrentNamedVisibility = self.namedVisibility(
            domain: domain,
            autosaveNames: [self.statusItemAutosaveName]
        ) != nil
        let hasLegacyVisibilitySource =
            self.namedVisibility(domain: domain, autosaveNames: self.legacyStatusItemAutosaveNames) != nil ||
            self.legacyVisibilityPreferenceKeys.contains {
                self.boolValue(domain[$0]) != nil
            }
        return hasCurrentNamedVisibility == false && hasLegacyVisibilitySource
    }

    static func repairVisibilityIfNeeded(userDefaults: UserDefaults = .standard) {
        let domain = userDefaults.dictionaryRepresentation()
        guard self.shouldRepairVisibility(domain: domain) else {
            return
        }

        let visible = self.resolvedVisibility(domain: domain)
        self.namedVisibleKeys.forEach { key in
            userDefaults.set(visible, forKey: key)
        }
        userDefaults.synchronize()
    }

    private static func namedVisibleKeys(for autosaveNames: [NSStatusItem.AutosaveName]) -> [String] {
        autosaveNames.flatMap { autosaveName in
            [
                "NSStatusItem VisibleCC \(autosaveName)",
                "NSStatusItem Visible \(autosaveName)",
            ]
        }
    }

    private static func namedVisibility(
        domain: [String: Any],
        autosaveNames: [NSStatusItem.AutosaveName]
    ) -> Bool? {
        let values = self.namedVisibleKeys(for: autosaveNames).compactMap {
            self.boolValue(domain[$0])
        }
        if values.contains(true) {
            return true
        }
        if values.contains(false) {
            return false
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return NSString(string: string).boolValue
        default:
            return nil
        }
    }
}
