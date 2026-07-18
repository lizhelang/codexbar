import AppKit

struct MenuBarUsageIconSpec: Equatable {
    let displayPercents: [Double]
    let showsPrimaryPercent: Bool

    init(displayPercents: [Double], showsPrimaryPercent: Bool = false) {
        self.displayPercents = Array(displayPercents.prefix(2))
        self.showsPrimaryPercent = showsPrimaryPercent
    }

    var primaryPercentText: String? {
        guard self.showsPrimaryPercent,
              let primaryPercent = self.displayPercents.first,
              primaryPercent.isFinite else {
            return nil
        }

        let clampedPercent = min(max(primaryPercent, 0), 100)
        return "\(Int(clampedPercent))%"
    }
}

enum MenuBarUsageIconRenderer {
    struct PixelRect: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    static let pointSize = NSSize(width: 18, height: 18)
    static let backingScale: CGFloat = 2

    private static let canvasPixels = Int(pointSize.width * backingScale)
    private static let barWidthPixels = 30
    static let primaryPercentTextRect = PixelRect(x: 0, y: 18, width: 36, height: 18)

    static func primaryPercentFont(for text: String) -> NSFont {
        let fontSize: CGFloat = text.count >= 4 ? 6 : 8
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        return NSFontManager.shared.convert(font, toHaveTrait: .condensedFontMask)
    }

    static func barRects(
        windowCount: Int,
        showsPrimaryPercent: Bool = false
    ) -> [PixelRect] {
        let barX = (self.canvasPixels - self.barWidthPixels) / 2
        if showsPrimaryPercent {
            switch windowCount {
            case 2...:
                return [
                    PixelRect(x: barX, y: 10, width: self.barWidthPixels, height: 5),
                    PixelRect(x: barX, y: 3, width: self.barWidthPixels, height: 5),
                ]
            case 1:
                return [
                    PixelRect(x: barX, y: 5, width: self.barWidthPixels, height: 7),
                ]
            default:
                return []
            }
        }

        switch windowCount {
        case 2...:
            return [
                PixelRect(x: barX, y: 19, width: self.barWidthPixels, height: 12),
                PixelRect(x: barX, y: 5, width: self.barWidthPixels, height: 8),
            ]
        case 1:
            return [
                PixelRect(x: barX, y: 12, width: self.barWidthPixels, height: 12),
            ]
        default:
            return []
        }
    }

    static func fillWidthPixels(displayPercent: Double, barWidthPixels: Int = barWidthPixels) -> Int {
        guard displayPercent.isFinite else { return 0 }
        let clamped = min(max(displayPercent, 0), 100) / 100
        return min(
            max(Int((Double(barWidthPixels) * clamped).rounded()), 0),
            barWidthPixels
        )
    }

    static func makeImage(
        spec: MenuBarUsageIconSpec,
        foregroundColor: NSColor = .labelColor,
        accessibilityDescription: String
    ) -> NSImage? {
        let rects = self.barRects(
            windowCount: spec.displayPercents.count,
            showsPrimaryPercent: spec.primaryPercentText != nil
        )
        guard rects.isEmpty == false else { return nil }

        let image = NSImage(size: self.pointSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSGraphicsContext.saveGraphicsState()
            defer {
                NSGraphicsContext.restoreGraphicsState()
            }
            context.cgContext.setShouldAntialias(true)
            context.cgContext.interpolationQuality = .none

            if let primaryPercentText = spec.primaryPercentText {
                self.drawPrimaryPercent(
                    primaryPercentText,
                    foregroundColor: foregroundColor
                )
            }

            for (rect, percent) in zip(rects, spec.displayPercents) {
                self.drawBar(
                    rect: rect,
                    displayPercent: percent,
                    foregroundColor: foregroundColor
                )
            }
            return true
        }

        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func drawPrimaryPercent(
        _ text: String,
        foregroundColor: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: self.primaryPercentFont(for: text),
            .foregroundColor: foregroundColor,
            .expansion: text.count >= 4 ? 0 : -0.04,
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedText.size()
        let availableRect = self.pointRect(self.primaryPercentTextRect)
        let origin = NSPoint(
            x: self.pixelAligned(availableRect.midX - textSize.width / 2),
            y: self.pixelAligned(availableRect.midY - textSize.height / 2)
        )
        attributedText.draw(at: origin)
    }

    private static func drawBar(
        rect: PixelRect,
        displayPercent: Double,
        foregroundColor: NSColor
    ) {
        let barRect = self.pointRect(rect)
        let radius = self.points(rect.height / 2)
        let trackPath = NSBezierPath(
            roundedRect: barRect,
            xRadius: radius,
            yRadius: radius
        )

        foregroundColor.withAlphaComponent(0.28).setFill()
        trackPath.fill()

        let strokeWidthPixels = rect.height <= 7 ? 1 : 2
        let strokeWidth = self.points(strokeWidthPixels)
        let strokeRect = barRect.insetBy(
            dx: strokeWidth / 2,
            dy: strokeWidth / 2
        )
        let strokePath = NSBezierPath(
            roundedRect: strokeRect,
            xRadius: max(0, radius - strokeWidth / 2),
            yRadius: max(0, radius - strokeWidth / 2)
        )
        strokePath.lineWidth = strokeWidth
        foregroundColor.withAlphaComponent(0.44).setStroke()
        strokePath.stroke()

        let fillWidth = self.fillWidthPixels(
            displayPercent: displayPercent,
            barWidthPixels: rect.width
        )
        guard fillWidth > 0 else { return }

        NSGraphicsContext.current?.cgContext.saveGState()
        trackPath.addClip()
        foregroundColor.setFill()
        NSBezierPath(
            rect: self.pointRect(
                PixelRect(
                    x: rect.x,
                    y: rect.y,
                    width: fillWidth,
                    height: rect.height
                )
            )
        ).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private static func pointRect(_ rect: PixelRect) -> NSRect {
        NSRect(
            x: self.points(rect.x),
            y: self.points(rect.y),
            width: self.points(rect.width),
            height: self.points(rect.height)
        )
    }

    private static func points(_ pixels: Int) -> CGFloat {
        CGFloat(pixels) / self.backingScale
    }

    private static func pixelAligned(_ value: CGFloat) -> CGFloat {
        (value * self.backingScale).rounded() / self.backingScale
    }
}
