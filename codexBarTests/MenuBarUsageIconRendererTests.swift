import AppKit
import XCTest

final class MenuBarUsageIconRendererTests: XCTestCase {
    func testDualWindowLayoutMatchesPixelGrid() {
        XCTAssertEqual(
            MenuBarUsageIconRenderer.barRects(windowCount: 2),
            [
                .init(x: 3, y: 19, width: 30, height: 12),
                .init(x: 3, y: 5, width: 30, height: 8),
            ]
        )
    }

    func testSingleWindowLayoutIsCenteredWithoutPlaceholderTrack() {
        XCTAssertEqual(
            MenuBarUsageIconRenderer.barRects(windowCount: 1),
            [.init(x: 3, y: 12, width: 30, height: 12)]
        )
        XCTAssertEqual(MenuBarUsageIconRenderer.barRects(windowCount: 0), [])
    }

    func testFillWidthClampsAndQuantizesToPhysicalPixels() {
        XCTAssertEqual(MenuBarUsageIconRenderer.fillWidthPixels(displayPercent: -5), 0)
        XCTAssertEqual(MenuBarUsageIconRenderer.fillWidthPixels(displayPercent: 1), 0)
        XCTAssertEqual(MenuBarUsageIconRenderer.fillWidthPixels(displayPercent: 2), 1)
        XCTAssertEqual(MenuBarUsageIconRenderer.fillWidthPixels(displayPercent: 50), 15)
        XCTAssertEqual(MenuBarUsageIconRenderer.fillWidthPixels(displayPercent: 101), 30)
        XCTAssertEqual(MenuBarUsageIconRenderer.fillWidthPixels(displayPercent: .nan), 0)
        XCTAssertEqual(MenuBarUsageIconRenderer.fillWidthPixels(displayPercent: .infinity), 0)
    }

    func testRenderedImageIsEighteenPointTwoXTemplate() throws {
        let image = try XCTUnwrap(
            MenuBarUsageIconRenderer.makeImage(
                spec: MenuBarUsageIconSpec(displayPercents: [67, 48]),
                accessibilityDescription: "Codexbar"
            )
        )
        let representation = try XCTUnwrap(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        )

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(representation.pixelsWide, 36)
        XCTAssertEqual(representation.pixelsHigh, 36)
        XCTAssertEqual(representation.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "Codexbar")
    }

    func testSpecIgnoresUnexpectedExtraWindows() {
        XCTAssertEqual(
            MenuBarUsageIconSpec(displayPercents: [10, 20, 30]).displayPercents,
            [10, 20]
        )
    }
}
