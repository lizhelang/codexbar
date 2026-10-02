import AppKit
import SwiftUI
import XCTest

@MainActor
final class SlidingGlassSelectionTests: XCTestCase {
    func testPeriodSelectionKeepsEveryCellInPlace() throws {
        let fixture = GlassSelectionFixtureState(values: ["今天", "本周", "本月", "总计"])
        let host = NSHostingView(rootView: GlassSelectionFixture(state: fixture, showsTrack: true))
        let window = makeWindow(host: host, height: 64)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let original = try cellFrames(in: fixture, count: 4)
        for index in [0, 1, 2, 3, 0] {
            fixture.select(index)
            settle(host)
            XCTAssertEqual(fixture.selection, index)
            assertFrames(try cellFrames(in: fixture, count: 4), equalTo: original)
        }
        try render(host, name: "periods")
    }

    func testPageSelectionKeepsEightEqualCells() throws {
        let fixture = GlassSelectionFixtureState(values: ["主页", "额度", "工具", "模型", "项目", "会话", "设备", "趋势"])
        let host = NSHostingView(rootView: GlassSelectionFixture(state: fixture, showsTrack: false))
        let window = makeWindow(host: host, height: 84)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let original = try cellFrames(in: fixture, count: 8)
        for index in [7, 4, 1, 0] {
            fixture.select(index)
            settle(host)
            XCTAssertEqual(fixture.selection, index)
            assertFrames(try cellFrames(in: fixture, count: 8), equalTo: original)
        }
        try render(host, name: "pages")
    }

    private func makeWindow(host: NSView, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 360, height: height)
        XCTAssertFalse(window.isVisible)
        return window
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
    }

    private func cellFrames(in fixture: GlassSelectionFixtureState, count: Int) throws -> [CGRect] {
        let frames = fixture.frames.sorted { $0.key < $1.key }.map(\.value)
        XCTAssertEqual(frames.count, count)
        let first = try XCTUnwrap(frames.first)
        XCTAssertGreaterThan(first.width, 10)
        for frame in frames {
            XCTAssertEqual(frame.width, first.width, accuracy: 1)
            XCTAssertEqual(frame.height, first.height, accuracy: 1)
        }
        return frames
    }

    private func assertFrames(_ frames: [CGRect], equalTo original: [CGRect]) {
        XCTAssertEqual(frames.count, original.count)
        for (frame, prior) in zip(frames, original) {
            XCTAssertEqual(frame.minX, prior.minX, accuracy: 0.5)
            XCTAssertEqual(frame.minY, prior.minY, accuracy: 0.5)
            XCTAssertEqual(frame.width, prior.width, accuracy: 0.5)
            XCTAssertEqual(frame.height, prior.height, accuracy: 0.5)
        }
    }

    private func render(_ host: NSView, name: String) throws {
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-glass-selection", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

@MainActor
private final class GlassSelectionFixtureState: ObservableObject {
    let values: [String]
    @Published var selection = 0
    var frames: [Int: CGRect] = [:]

    init(values: [String]) { self.values = values }

    func select(_ value: Int) {
        selection = value
    }
}

private struct GlassSelectionFixture: View {
    @ObservedObject var state: GlassSelectionFixtureState
    let showsTrack: Bool

    var body: some View {
        SlidingGlassSelection(
            values: Array(state.values.indices), selection: state.selection,
            onSelect: state.select, accessibilityIdentifier: { "fixture.\($0)" },
            inset: showsTrack ? 3 : 0, showsTrack: showsTrack
        ) { value, selected in
            VStack(spacing: 4) {
                if !showsTrack { Image(systemName: "square.grid.2x2").font(.system(size: 15)) }
                Text(state.values[value]).font(.system(size: showsTrack ? 11 : 9, weight: .semibold))
            }
            .foregroundStyle(selected ? MenuSurface.accent : MenuSurface.muted)
            .padding(.vertical, showsTrack ? 7 : 8)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: GlassSelectionFramesKey.self,
                        value: [value: geometry.frame(in: .named("selection-fixture"))]
                    )
                }
            }
        }
        .coordinateSpace(name: "selection-fixture")
        .onPreferenceChange(GlassSelectionFramesKey.self) { state.frames = $0 }
        .padding(12)
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(MenuSurface.backgroundTop)
        .environment(\.colorScheme, .dark)
    }
}

private struct GlassSelectionFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
