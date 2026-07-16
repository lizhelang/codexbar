import AppKit

struct MenuBarUsageIconSpec: Equatable {
    let displayPercents: [Double]

    init(displayPercents: [Double]) {
        self.displayPercents = Array(displayPercents.prefix(2))
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

    static func barRects(windowCount: Int) -> [PixelRect] {
        let barX = (self.canvasPixels - self.barWidthPixels) / 2
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
        accessibilityDescription: String
    ) -> NSImage? {
        let rects = self.barRects(windowCount: spec.displayPercents.count)
        guard rects.isEmpty == false else { return nil }

        let image = NSImage(size: self.pointSize)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: self.canvasPixels,
            pixelsHigh: self.canvasPixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        representation.size = self.pointSize
        image.addRepresentation(representation)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: representation) {
            NSGraphicsContext.current = context
            context.cgContext.setShouldAntialias(true)
            context.cgContext.interpolationQuality = .none

            for (rect, percent) in zip(rects, spec.displayPercents) {
                self.drawBar(rect: rect, displayPercent: percent)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func drawBar(rect: PixelRect, displayPercent: Double) {
        let barRect = self.pointRect(rect)
        let radius = self.points(rect.height / 2)
        let trackPath = NSBezierPath(
            roundedRect: barRect,
            xRadius: radius,
            yRadius: radius
        )

        NSColor.labelColor.withAlphaComponent(0.28).setFill()
        trackPath.fill()

        let strokeWidthPixels = 2
        let strokeInsetPixels = strokeWidthPixels / 2
        let strokeRect = self.pointRect(
            PixelRect(
                x: rect.x + strokeInsetPixels,
                y: rect.y + strokeInsetPixels,
                width: max(0, rect.width - strokeInsetPixels * 2),
                height: max(0, rect.height - strokeInsetPixels * 2)
            )
        )
        let strokePath = NSBezierPath(
            roundedRect: strokeRect,
            xRadius: self.points(max(0, rect.height / 2 - strokeInsetPixels)),
            yRadius: self.points(max(0, rect.height / 2 - strokeInsetPixels))
        )
        strokePath.lineWidth = self.points(strokeWidthPixels)
        NSColor.labelColor.withAlphaComponent(0.44).setStroke()
        strokePath.stroke()

        let fillWidth = self.fillWidthPixels(
            displayPercent: displayPercent,
            barWidthPixels: rect.width
        )
        guard fillWidth > 0 else { return }

        NSGraphicsContext.current?.cgContext.saveGState()
        trackPath.addClip()
        NSColor.labelColor.setFill()
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
}
