import AppKit
import XCTest

final class MenuBarPopoverSizingTests: XCTestCase {
    func testInitialSizeUsesStableWidthAndDefaultHeight() {
        let size = MenuBarPopoverSizing.initialSize(availableHeight: 1200)

        XCTAssertEqual(size.width, MenuBarStatusItemIdentity.popoverContentWidth)
        XCTAssertEqual(size.height, MenuBarPopoverSizing.defaultHeight)
    }

    func testClampedHeightCapsToAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 2000, availableHeight: 1400),
            1400
        )
    }

    func testClampedHeightFallsBackToConfiguredMaximumWhenAvailableHeightIsUnknown() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 2000, availableHeight: nil),
            MenuBarPopoverSizing.maximumHeight
        )
    }

    func testClampedHeightRespectsAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 600, availableHeight: 500),
            500
        )
    }

    func testClampedHeightFollowsShortContentHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 100, availableHeight: 200),
            100
        )
    }

    func testFlexibleSectionHeightCapReturnsRemainingBudgetForScrollableSection() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 260,
                availableHeight: 520
            ),
            160
        )
    }

    func testFlexibleSectionHeightCapFloorsToMinimumHeightWhenFixedChromeExceedsAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 120,
                availableHeight: 400
            ),
            MenuBarPopoverSizing.minimumHeight
        )
    }

    func testFlexibleSectionHeightCapReturnsNilWithoutAvailableHeight() {
        XCTAssertNil(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 260,
                availableHeight: nil
            )
        )
    }

    func testFlexibleSectionHeightCapPrioritizesKeepingFixedChromeVisibleWhenBannerAppears() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 708,
                flexibleSectionHeight: 248,
                availableHeight: 520
            ),
            60
        )
    }

    func testFlexibleSectionHeightCapUsesMaximumAvailableHeightInsteadOfInitialPopoverHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 708,
                flexibleSectionHeight: 248,
                availableHeight: 700
            ),
            240
        )
    }
}
