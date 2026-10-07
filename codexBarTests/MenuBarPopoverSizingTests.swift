import AppKit
import SwiftUI
import XCTest

final class MenuBarPopoverSizingTests: XCTestCase {
    func testInitialSizeUsesStableWidthAndDefaultHeight() {
        let size = MenuBarPopoverSizing.initialSize(availableHeight: 1200)

        XCTAssertEqual(size.width, MenuBarStatusItemIdentity.popoverContentWidth)
        XCTAssertEqual(size.height, MenuBarPopoverSizing.defaultHeight)
    }

    @MainActor
    func testNativeScrollViewportKeepsHeightAcrossShortAndLongPages() {
        for contentHeight: CGFloat in [20, 299, 300, 301, 1800] {
            let hostingView = NSHostingView(rootView:
                AdaptiveMenuScrollContainer(maxHeight: 300) {
                    Color.clear.frame(height: contentHeight)
                }
                .frame(width: 360)
            )
            hostingView.setFrameSize(NSSize(width: 360, height: 300))
            hostingView.layoutSubtreeIfNeeded()
            XCTAssertEqual(hostingView.fittingSize.height, 300, accuracy: 1)
            XCTAssertEqual(hostingView.fittingSize.width, 360, accuracy: 1)
        }
    }

    @MainActor
    func testNativeScrollViewportFollowsHeightChangesWithoutContentMeasurement() {
        func content(height: CGFloat) -> AnyView {
            AnyView(AdaptiveMenuScrollContainer(maxHeight: height) {
                Color.clear.frame(height: 1800)
            }.frame(width: 360))
        }
        let hostingView = NSHostingView(rootView: content(height: 300))
        for height: CGFloat in [300, 480, 160, 300] {
            hostingView.rootView = content(height: height)
            hostingView.setFrameSize(NSSize(width: 360, height: height))
            hostingView.layoutSubtreeIfNeeded()
            XCTAssertEqual(hostingView.fittingSize.height, height, accuracy: 1)
        }
    }

    func testClampedHeightCapsToMenuHeightEvenOnTallScreens() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 2000, availableHeight: 1400),
            MenuBarPopoverSizing.maximumHeight
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

    func testDefaultHeightStaysStableAcrossShortPages() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 100, availableHeight: 200),
            200
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 100, availableHeight: 1000),
            MenuBarPopoverSizing.defaultHeight
        )
    }

    func testPreferredHeightStaysStableAcrossPageContent() {
        for pageHeight in [100.0, 320.0, 1200.0] {
            XCTAssertEqual(
                MenuBarPopoverSizing.clampedHeight(
                    desiredHeight: pageHeight,
                    availableHeight: 1000,
                    preferredHeight: 780
                ),
                780
            )
        }
        XCTAssertEqual(
            MenuBarPopoverSizing.initialSize(availableHeight: 1000, preferredHeight: 780).height,
            780
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.scrollBodyHeightLimit(availableHeight: 1000, preferredHeight: 780),
            780 - MenuBarPopoverSizing.fixedChromeHeight
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.scrollBodyHeightLimit(availableHeight: 1000, preferredHeight: 260),
            260 - MenuBarPopoverSizing.fixedChromeHeight
        )
    }

    func testPreferredHeightIsBoundedByUserMinimumAndScreenAvailability() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(
                desiredHeight: 100,
                availableHeight: 1000,
                preferredHeight: 120
            ),
            MenuBarPopoverSizing.minimumUserHeight
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(
                desiredHeight: 100,
                availableHeight: 500,
                preferredHeight: 900
            ),
            500
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(
                desiredHeight: 100,
                availableHeight: 200,
                preferredHeight: 260
            ),
            200
        )
    }

    func testSinglePageSelectorLeavesFullBodyBudgetWithoutBottomNavigation() {
        XCTAssertEqual(MenuBarPopoverSizing.fixedChromeHeight, 118)
        for height: CGFloat in [260, 640, 780] {
            let bodyHeight = MenuBarPopoverSizing.scrollBodyHeightLimit(
                availableHeight: 1000,
                preferredHeight: height
            )
            XCTAssertEqual(bodyHeight, height - 118)
            XCTAssertEqual(
                MenuBarPopoverSizing.clampedHeight(desiredHeight: bodyHeight, availableHeight: 1000, preferredHeight: height),
                height
            )
        }
    }

    func testDraggingBottomEdgeChangesHeightInExpectedDirection() {
        XCTAssertEqual(
            MenuBarPopoverSizing.resizedHeight(
                startingHeight: 640,
                startingPointerScreenY: 400,
                pointerScreenY: 300,
                availableHeight: 900
            ),
            740
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.resizedHeight(
                startingHeight: 640,
                startingPointerScreenY: 400,
                pointerScreenY: 500,
                availableHeight: 900
            ),
            540
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.resizedHeight(
                startingHeight: 640,
                startingPointerScreenY: 400,
                pointerScreenY: 950,
                availableHeight: 900
            ),
            MenuBarPopoverSizing.minimumUserHeight
        )
    }

    func testPreferredHeightPersistsAndZeroRestoresAutomaticHeight() {
        let suiteName = "MenuBarPopoverSizingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MenuBarPopoverSizing.savedPreferredHeight(userDefaults: defaults), 0)
        defaults.set(790.0, forKey: MenuBarPopoverSizing.preferredHeightDefaultsKey)
        XCTAssertEqual(MenuBarPopoverSizing.savedPreferredHeight(userDefaults: defaults), 790)
        defaults.set(0.0, forKey: MenuBarPopoverSizing.preferredHeightDefaultsKey)
        XCTAssertEqual(MenuBarPopoverSizing.savedPreferredHeight(userDefaults: defaults), 0)
    }

    func testScrollBodyLimitUsesIndependentFixedChromeBudget() {
        XCTAssertEqual(
            MenuBarPopoverSizing.scrollBodyHeightLimit(availableHeight: 1400),
            MenuBarPopoverSizing.maximumHeight - MenuBarPopoverSizing.fixedChromeHeight
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.scrollBodyHeightLimit(availableHeight: 500),
            500 - MenuBarPopoverSizing.fixedChromeHeight
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.scrollBodyHeightLimit(availableHeight: 80),
            MenuBarPopoverSizing.minimumHeight
        )
        XCTAssertEqual(
            MenuBarPopoverSizing.scrollBodyHeightLimit(availableHeight: nil),
            MenuBarPopoverSizing.maximumHeight - MenuBarPopoverSizing.fixedChromeHeight
        )
    }
}
