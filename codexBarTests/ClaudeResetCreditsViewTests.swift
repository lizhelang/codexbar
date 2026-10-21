import AppKit
import SwiftUI
import Vision
import XCTest
@testable import codexbar

@MainActor
final class ClaudeResetCreditsViewTests: XCTestCase {
    func testReadyAccountAndFallbackQuotaShowResetCardsWithoutExpanding() async throws {
        try self.requireIsolatedHost()
        let language = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = language }
        let now = Date()
        let snapshot = self.fixture(now: now)
        XCTAssertEqual(snapshot.status, .ready)
        let quotaViews: [(String, AnyView)] = [
            ("claude-reset-account", AnyView(CursorAccountQuotaView(
                quota: snapshot, state: nil, usageDisplayMode: .remaining, now: now))),
            ("claude-reset-fallback", AnyView(ToolQuotaView(
                snapshot: snapshot, symbol: "sparkle", tint: .orange, mode: .remaining,
                expanded: false, toggle: {}, refresh: {}, showUsage: {}, managementMode: true,
                showsHeader: false, compactManagementActions: true))),
        ]

        for (name, view) in quotaViews {
            let (host, window) = self.makeWindow(view)
            defer { window.contentView = nil; window.close() }
            try await self.settle(host)
            let rows = try self.capture(host, name: name)
            let text = rows.map(\.text).joined(separator: "\n")
            let compact = text.filter { !$0.isWhitespace }
            XCTAssertTrue(compact.contains("重置卡"), text)
            XCTAssertTrue(compact.contains("1张"), "只有有效的一张卡计入库存：\n\(text)")
            XCTAssertFalse(compact.contains("3张"), text)
            XCTAssertTrue(compact.contains("到期"), text)
            XCTAssertTrue(compact.contains("使用"), text)
            XCTAssertTrue(compact.contains("80%") && compact.contains("60%"), text)
            XCTAssertEqual(host.fittingSize.width, 360, accuracy: 1)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testExpiredOrPausedResetCardsNeverAppearAsAvailable() async throws {
        try self.requireIsolatedHost()
        let language = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = language }
        let now = Date()
        for (name, grants) in [
            ("claude-reset-expired", [self.grant(id: "expired", endsAt: now.addingTimeInterval(-60))]),
            ("claude-reset-paused", [self.grant(id: "paused", endsAt: now.addingTimeInterval(3_600), paused: true)]),
        ] {
            let snapshot = self.fixture(now: now, grants: grants)
            let (host, window) = self.makeWindow(ClaudeResetCreditsView(snapshot: snapshot, now: now))
            defer { window.contentView = nil; window.close() }
            try await self.settle(host)
            let text = try self.capture(host, name: name).map(\.text).joined(separator: "\n")
            XCTAssertFalse(text.filter { !$0.isWhitespace }.contains("1张"), text)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testUseActionOpensOfficialUsagePageWithoutConsumingReset() async throws {
        try self.requireIsolatedHost()
        let language = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = language }
        let now = Date()
        let snapshot = self.fixture(now: now)
        let original = snapshot
        var openedURLs: [URL] = []
        let view = ClaudeResetCreditsView(snapshot: snapshot, now: now)
            .environment(\.openURL, OpenURLAction { url in
                openedURLs.append(url)
                return .handled
            })
        let (host, window) = self.makeWindow(view)
        defer { window.contentView = nil; window.close() }
        try await self.settle(host)
        let rows = try self.capture(host, name: "claude-reset-use-link")
        let link = try XCTUnwrap(rows.first {
            $0.text.filter { !$0.isWhitespace }.contains("使用")
        }, "应有官方使用入口：\(rows.map(\.text).joined(separator: "\n"))")
        try self.pressLink(in: host, window: window, recognizedBounds: link.bounds)
        for _ in 0..<20 where openedURLs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://claude.ai/settings/usage"])
        XCTAssertEqual(snapshot, original, "打开官方页面不能在本地消耗重置卡")
        XCTAssertFalse(window.isVisible)
    }

    private func fixture(now: Date, grants: [[String: Any]]? = nil) -> ToolQuotaSnapshot {
        ToolQuotaService.parseClaude([
            "five_hour": ["utilization": 20, "resets_at": self.iso(now.addingTimeInterval(7_200))],
            "seven_day": ["utilization": 40, "resets_at": self.iso(now.addingTimeInterval(172_800))],
            "cedar_ember": [
                "eligible": true,
                "grants": grants ?? [
                    self.grant(id: "valid", endsAt: now.addingTimeInterval(129_600)),
                    self.grant(id: "expired", endsAt: now.addingTimeInterval(-60)),
                    self.grant(id: "paused", endsAt: now.addingTimeInterval(172_800), paused: true),
                ],
            ],
        ], now: now)
    }

    private func grant(id: String, endsAt: Date, paused: Bool = false) -> [String: Any] {
        ["id": id, "resets_left": 1, "resets_total": 1, "paused": paused,
         "starts_at": NSNull(), "ends_at": self.iso(endsAt), "usable_now": true,
         "clears": ["five_hour"]]
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func requireIsolatedHost() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("只在隔离的原生测试窗口中验证，不操作运行中的应用")
        }
    }

    private func makeWindow(_ view: some View) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.padding(14)
            .frame(width: 360, height: 340, alignment: .topLeading)
            .background(MenuSurface.backgroundTop).environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        let frame = NSRect(x: 0, y: 0, width: 360, height: 340)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = frame
        return (host, window)
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        host.displayIfNeeded()
    }

    private func capture(_ host: NSView, name: String) throws -> [(text: String, bounds: CGRect)] {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-reset-cards-20261021/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent(name + ".png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["Claude", "重置卡", "前往Claude使用", "到期"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        let rows = (request.results ?? []).compactMap { result -> (text: String, bounds: CGRect)? in
            result.topCandidates(1).first.map { ($0.string, result.boundingBox) }
        }
        try rows.map(\.text).joined(separator: "\n")
            .write(to: output.appendingPathComponent(name + "-ocr.txt"), atomically: true, encoding: .utf8)
        return rows
    }

    private func pressLink(in host: NSView, window: NSWindow, recognizedBounds: CGRect) throws {
        if let element = self.accessibilityElements(window).first(where: {
            $0.accessibilityIdentifier() == "codexbar.claude.reset-credits.open-usage"
        }), element.accessibilityPerformPress() { return }
        if let button = self.buttons(in: host).first(where: {
            $0.accessibilityIdentifier() == "codexbar.claude.reset-credits.open-usage"
        }) {
            button.performClick(nil)
            return
        }
        // The compact link stays at the right edge of the padded row; OCR may
        // combine its short label with the adjacent expiry text.
        let pointInHost = NSPoint(x: host.bounds.maxX - 30,
            y: (host.isFlipped ? 1 - recognizedBounds.midY : recognizedBounds.midY) * host.bounds.height)
        XCTAssertTrue(host.bounds.contains(pointInHost))
        XCTAssertFalse(window.isVisible)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let point = host.convert(pointInHost, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApplication.shared.postEvent(up, atStart: true)
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func accessibilityElements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 20, let element = object as? NSAccessibilityProtocol else { return [] }
        var children: [Any] = element.accessibilityChildren() ?? []
        if let window = object as? NSWindow, let contentView = window.contentView { children.append(contentView) }
        if let view = object as? NSView { children.append(contentsOf: view.subviews) }
        return [element] + children.flatMap { self.accessibilityElements($0, depth: depth + 1) }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { self.buttons(in: $0) }
    }
}
