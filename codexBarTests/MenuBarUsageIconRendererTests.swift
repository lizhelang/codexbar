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

    func testVerticalPercentLayoutKeepsBarsBelowThePrimaryValue() {
        XCTAssertEqual(
            MenuBarUsageIconRenderer.barRects(windowCount: 2, showsPrimaryPercent: true),
            [
                .init(x: 3, y: 10, width: 30, height: 5),
                .init(x: 3, y: 3, width: 30, height: 5),
            ]
        )
        XCTAssertEqual(
            MenuBarUsageIconRenderer.barRects(windowCount: 1, showsPrimaryPercent: true),
            [.init(x: 3, y: 5, width: 30, height: 7)]
        )
    }

    func testPrimaryPercentUsesLargeBoldFontForCommonValues() {
        let font = MenuBarUsageIconRenderer.primaryPercentFont(for: "91%")

        XCTAssertEqual(font.pointSize, 8)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testHundredPercentUsesSmallerBoldFontToStayInsideSquareIcon() {
        let font = MenuBarUsageIconRenderer.primaryPercentFont(for: "100%")
        let text = NSAttributedString(string: "100%", attributes: [.font: font])
        let availableWidth = CGFloat(MenuBarUsageIconRenderer.primaryPercentTextRect.width) /
            MenuBarUsageIconRenderer.backingScale
        let availableHeight = CGFloat(MenuBarUsageIconRenderer.primaryPercentTextRect.height) /
            MenuBarUsageIconRenderer.backingScale

        XCTAssertEqual(font.pointSize, 6)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertLessThanOrEqual(text.size().width, availableWidth)
        XCTAssertLessThanOrEqual(text.size().height, availableHeight)
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

    func testRenderedVerticalImageContainsPrimaryTextAndEveryActualBar() throws {
        let image = try XCTUnwrap(
            MenuBarUsageIconRenderer.makeImage(
                spec: MenuBarUsageIconSpec(
                    displayPercents: [100, 48],
                    showsPrimaryPercent: true
                ),
                accessibilityDescription: "Codexbar"
            )
        )
        let representation = try XCTUnwrap(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        )

        XCTAssertGreaterThan(
            self.nonTransparentPixelCount(
                in: MenuBarUsageIconRenderer.primaryPercentTextRect,
                representation: representation
            ),
            0
        )
        self.assertTransparentAtHorizontalCanvasEdges(
            in: MenuBarUsageIconRenderer.primaryPercentTextRect,
            representation: representation
        )
        XCTAssertEqual(
            self.nonTransparentPixelCount(
                in: .init(x: 0, y: 15, width: 36, height: 3),
                representation: representation
            ),
            0,
            "文字与上方进度之间应保留物理像素间隔"
        )
        for rect in MenuBarUsageIconRenderer.barRects(
            windowCount: 2,
            showsPrimaryPercent: true
        ) {
            XCTAssertGreaterThan(
                self.nonTransparentPixelCount(in: rect, representation: representation),
                0
            )
        }
    }

    func testLargeCommonPercentRemainsInsideHorizontalCanvasEdges() throws {
        let image = try XCTUnwrap(
            MenuBarUsageIconRenderer.makeImage(
                spec: MenuBarUsageIconSpec(
                    displayPercents: [99],
                    showsPrimaryPercent: true
                ),
                accessibilityDescription: "Codexbar"
            )
        )
        let representation = try XCTUnwrap(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        )

        XCTAssertGreaterThan(
            self.nonTransparentPixelCount(
                in: MenuBarUsageIconRenderer.primaryPercentTextRect,
                representation: representation
            ),
            0
        )
        self.assertTransparentAtHorizontalCanvasEdges(
            in: MenuBarUsageIconRenderer.primaryPercentTextRect,
            representation: representation
        )
    }

    func testPrimaryPercentUsesOnlyTheShortestActualWindow() {
        XCTAssertEqual(
            MenuBarUsageIconSpec(
                displayPercents: [67, 48],
                showsPrimaryPercent: true
            ).primaryPercentText,
            "67%"
        )
        XCTAssertEqual(
            MenuBarUsageIconSpec(
                displayPercents: [73],
                showsPrimaryPercent: true
            ).primaryPercentText,
            "73%"
        )
        XCTAssertNil(
            MenuBarUsageIconSpec(displayPercents: [67, 48]).primaryPercentText
        )
        XCTAssertEqual(
            MenuBarUsageIconSpec(
                displayPercents: [101],
                showsPrimaryPercent: true
            ).primaryPercentText,
            "100%"
        )
        XCTAssertNil(
            MenuBarUsageIconSpec(
                displayPercents: [.nan],
                showsPrimaryPercent: true
            ).primaryPercentText
        )
    }

    func testSpecIgnoresUnexpectedExtraWindows() {
        XCTAssertEqual(
            MenuBarUsageIconSpec(displayPercents: [10, 20, 30]).displayPercents,
            [10, 20]
        )
    }

    private func nonTransparentPixelCount(
        in rect: MenuBarUsageIconRenderer.PixelRect,
        representation: NSBitmapImageRep
    ) -> Int {
        var count = 0
        let bitmapMinY = representation.pixelsHigh - rect.y - rect.height
        for x in rect.x ..< rect.x + rect.width {
            for y in bitmapMinY ..< bitmapMinY + rect.height
                where (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                count += 1
            }
        }
        return count
    }

    private func assertTransparentAtHorizontalCanvasEdges(
        in rect: MenuBarUsageIconRenderer.PixelRect,
        representation: NSBitmapImageRep,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bitmapMinY = representation.pixelsHigh - rect.y - rect.height
        for x in [0, representation.pixelsWide - 1] {
            for y in bitmapMinY ..< bitmapMinY + rect.height {
                XCTAssertEqual(
                    representation.colorAt(x: x, y: y)?.alphaComponent ?? 0,
                    0,
                    accuracy: 0.001,
                    file: file,
                    line: line
                )
            }
        }
    }
}
