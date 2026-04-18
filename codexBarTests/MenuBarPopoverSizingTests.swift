import AppKit
import XCTest

final class MenuBarPopoverSizingTests: XCTestCase {
    func testInitialSizeUsesStableWidthAndDefaultHeight() {
        let size = MenuBarPopoverSizing.initialSize(availableHeight: 1200)

        XCTAssertEqual(size.width, MenuBarStatusItemIdentity.popoverContentWidth)
        XCTAssertEqual(size.height, MenuBarPopoverSizing.defaultHeight)
    }

    func testClampedHeightCapsToConfiguredMaximum() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 2000, availableHeight: 1400),
            MenuBarPopoverSizing.maximumHeight
        )
    }

    func testClampedHeightRespectsAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 600, availableHeight: 500),
            500
        )
    }

    func testClampedHeightNeverDropsBelowMinimumHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 100, availableHeight: 200),
            MenuBarPopoverSizing.minimumHeight
        )
    }
}
