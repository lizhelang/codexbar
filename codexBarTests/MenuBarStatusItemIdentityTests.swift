import AppKit
import XCTest

final class MenuBarStatusItemIdentityTests: XCTestCase {
    func testPopoverWidthStaysCompact() {
        XCTAssertEqual(MenuBarStatusItemIdentity.popoverContentWidth, 300)
    }

    func testIdentityConstantsStayStable() {
        XCTAssertEqual(MenuBarStatusItemIdentity.accessibilityLabel, "codexbar")
        XCTAssertEqual(MenuBarStatusItemIdentity.accessibilityIdentifier, "codexbar.status-item")
        XCTAssertEqual(
            MenuBarStatusItemIdentity.statusItemAutosaveName,
            "lzhl.codexAppBar.menu-bar-status-item"
        )
    }

    func testStatusItemBehaviorAllowsRemovalAndTermination() {
        let behavior = MenuBarStatusItemIdentity.statusItemBehavior

        XCTAssertTrue(behavior.contains(.removalAllowed))
        XCTAssertTrue(behavior.contains(.terminationOnRemoval))
    }

    func testRepairVisibilityWhenLegacyKeysSayVisibleButNamedKeysDoNot() {
        XCTAssertTrue(
            MenuBarStatusItemIdentity.shouldRepairVisibility(
                domain: [
                    "menuBarExtra.isInserted": true,
                    "NSStatusItem VisibleCC Item-0": 1,
                    "NSStatusItem VisibleCC lzhl.codexAppBar.menu-bar-status-item": 0,
                ]
            )
        )
    }

    func testSkipRepairWhenNamedVisibilityIsAlreadyPresent() {
        XCTAssertFalse(
            MenuBarStatusItemIdentity.shouldRepairVisibility(
                domain: [
                    "menuBarExtra.isInserted": true,
                    "NSStatusItem VisibleCC lzhl.codexAppBar.menu-bar-status-item": 1,
                ]
            )
        )
    }
}
