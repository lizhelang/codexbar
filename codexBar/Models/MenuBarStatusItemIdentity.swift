import AppKit
import Foundation

enum MenuBarStatusItemIdentity {
    static let popoverContentWidth: CGFloat = 300
    static let accessibilityLabel = "codexbar"
    static let accessibilityIdentifier = "codexbar.menubar-extra"
    static let statusItemAutosaveName: NSStatusItem.AutosaveName = "lzhl.codexAppBar.menu-bar-status-item"
    static let statusItemBehavior: NSStatusItem.Behavior = [
        .removalAllowed,
        .terminationOnRemoval,
    ]

    static let legacyVisibleKeys = [
        "menuBarExtra.isInserted",
        "codexbar.menu-bar-extra.is-inserted",
        "NSStatusItem VisibleCC Item-0",
        "NSStatusItem Visible Item-0",
    ]

    static var namedVisibleKeys: [String] {
        [
            "NSStatusItem VisibleCC \(self.statusItemAutosaveName)",
            "NSStatusItem Visible \(self.statusItemAutosaveName)",
        ]
    }

    static func shouldRepairVisibility(domain: [String: Any]) -> Bool {
        let hasLegacyVisible = self.legacyVisibleKeys.contains {
            self.boolValue(domain[$0]) == true
        }
        let hasNamedVisible = self.namedVisibleKeys.contains {
            self.boolValue(domain[$0]) == true
        }
        return hasLegacyVisible && hasNamedVisible == false
    }

    static func repairVisibilityIfNeeded(userDefaults: UserDefaults = .standard) {
        guard self.shouldRepairVisibility(domain: userDefaults.dictionaryRepresentation()) else {
            return
        }

        self.namedVisibleKeys.forEach { key in
            userDefaults.set(true, forKey: key)
        }
        userDefaults.synchronize()
    }

    static func clearVisibilityKeys(userDefaults: UserDefaults = .standard) {
        (self.legacyVisibleKeys + self.namedVisibleKeys).forEach { key in
            userDefaults.removeObject(forKey: key)
        }
        userDefaults.synchronize()
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
