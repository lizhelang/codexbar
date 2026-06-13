import AppKit
import XCTest

final class MenuBarStatusItemIdentityTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        self.suiteName = "MenuBarStatusItemIdentityTests.\(UUID().uuidString)"
        self.userDefaults = UserDefaults(suiteName: self.suiteName)
        self.userDefaults.removePersistentDomain(forName: self.suiteName)
    }

    override func tearDown() {
        self.userDefaults.removePersistentDomain(forName: self.suiteName)
        self.userDefaults = nil
        self.suiteName = nil
        super.tearDown()
    }

    func testPopoverWidthStaysCompact() {
        XCTAssertEqual(MenuBarStatusItemIdentity.popoverContentWidth, 300)
    }

    func testIdentityConstantsStayStable() {
        XCTAssertEqual(MenuBarStatusItemIdentity.accessibilityLabel, "codexbar")
        XCTAssertEqual(MenuBarStatusItemIdentity.accessibilityIdentifier, "codexbar.status-item")
        XCTAssertEqual(
            MenuBarStatusItemIdentity.statusItemAutosaveName,
            "lzhl.codexbar.menu-bar-status-item"
        )
        XCTAssertFalse(String(MenuBarStatusItemIdentity.statusItemAutosaveName).contains("codexAppBar"))
    }

    func testStatusItemBehaviorAllowsRemovalWithoutTermination() {
        let behavior = MenuBarStatusItemIdentity.statusItemBehavior

        XCTAssertTrue(behavior.contains(.removalAllowed))
        XCTAssertFalse(behavior.contains(.terminationOnRemoval))
    }

    func testAnonymousSwiftUIMenuBarPreferenceDoesNotHideCodexbar() {
        self.userDefaults.set(false, forKey: "menuBarExtra.isInserted")
        self.userDefaults.set(false, forKey: "codexbar.menu-bar-extra.is-inserted")

        MenuBarStatusItemIdentity.repairVisibilityIfNeeded(userDefaults: self.userDefaults)

        XCTAssertTrue(
            MenuBarStatusItemIdentity.resolvedVisibility(
                domain: self.userDefaults.dictionaryRepresentation()
            )
        )
        XCTAssertNil(
            self.userDefaults.object(forKey: "NSStatusItem VisibleCC lzhl.codexbar.menu-bar-status-item")
        )
        XCTAssertFalse(
            MenuBarStatusItemIdentity.shouldRepairVisibility(
                domain: self.userDefaults.dictionaryRepresentation()
            )
        )
    }

    func testRepairVisibilityIgnoresAnonymousSystemItemKeys() {
        self.userDefaults.set(false, forKey: "NSStatusItem Visible Item-0")

        XCTAssertFalse(
            MenuBarStatusItemIdentity.shouldRepairVisibility(
                domain: self.userDefaults.dictionaryRepresentation()
            )
        )
    }

    func testResolvedVisibilityPrefersCurrentNamedHiddenState() {
        XCTAssertFalse(
            MenuBarStatusItemIdentity.resolvedVisibility(
                domain: [
                    "menuBarExtra.isInserted": true,
                    "NSStatusItem VisibleCC lzhl.codexbar.menu-bar-status-item": false,
                ]
            )
        )
    }

    func testLegacyNamedVisibilityMigratesIntoCurrentIdentity() {
        self.userDefaults.set(false, forKey: "NSStatusItem VisibleCC lzhl.codexAppBar.menu-bar-status-item")

        MenuBarStatusItemIdentity.repairVisibilityIfNeeded(userDefaults: self.userDefaults)

        XCTAssertEqual(
            self.userDefaults.object(forKey: "NSStatusItem VisibleCC lzhl.codexbar.menu-bar-status-item") as? Bool,
            false
        )
    }

    func testMenuBarStatusItemControllerResolvedVisibilityUsesCurrentNamedPreference() {
        self.userDefaults.set(false, forKey: "NSStatusItem VisibleCC lzhl.codexbar.menu-bar-status-item")

        XCTAssertFalse(MenuBarStatusItemController.resolvedVisibilityPreference(userDefaults: self.userDefaults))

        self.userDefaults.set(true, forKey: "NSStatusItem VisibleCC lzhl.codexbar.menu-bar-status-item")

        XCTAssertTrue(MenuBarStatusItemController.resolvedVisibilityPreference(userDefaults: self.userDefaults))
    }
}
