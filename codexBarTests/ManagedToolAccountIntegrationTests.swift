import AppKit
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import codexbar

@MainActor
final class ManagedToolAccountIntegrationTests: CodexBarTestCase {
    func testSelectedCursorProjectionNeverInheritsAnotherAccountOrLegacyCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = FixtureCursorService()
        let accounts = CursorAccountStore(rootURL: fixture.root.appendingPathComponent("accounts"), service: service,
            sessionReader: CursorDesktopSessionReader(databaseURL: fixture.root.appendingPathComponent("missing.db")),
            preferencesStore: fixture.preferences)
        let a = try await accounts.addAccount(sessionCookie: Self.cookie("user_first"), alias: "First fixture")
        await accounts.refreshAccount(a, force: true)
        let legacy = ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .imported,
            dailyEntries: [.init(date: Date(), totalTokens: 999)], refreshedAt: Date())
        let cache = fixture.root.appendingPathComponent("tool-usage-summary.json")
        try JSONEncoder().encode([legacy]).write(to: cache)
        let tools = ToolUsageStore(collectors: [], cacheURL: cache, preferencesStore: fixture.preferences,
                                  cursorAccountStore: accounts)
        try await self.wait { tools.snapshot(for: .cursor).dailyEntries.first?.totalTokens == 101 }

        let b = try await accounts.addAccount(sessionCookie: Self.cookie("user_second"), alias: "Second fixture")
        try accounts.selectAccount(b)
        try await self.wait { tools.snapshot(for: .cursor).dailyEntries.isEmpty }
        XCTAssertEqual(tools.quota(for: .cursor).windows.first?.usedPercent, 72)
        await accounts.refreshAccount(b, force: true)
        try await self.wait { tools.snapshot(for: .cursor).dailyEntries.first?.totalTokens == 202 }
        try accounts.selectAccount(a)
        try await self.wait { tools.snapshot(for: .cursor).dailyEntries.first?.totalTokens == 101 }
        XCTAssertEqual(tools.quota(for: .cursor).windows.first?.usedPercent, 31)

        let imported = ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .imported,
            dailyEntries: [.init(date: Date(), totalTokens: 303)], refreshedAt: Date())
        tools.updateImportedCursor(imported)
        XCTAssertEqual(accounts.states[a]?.usage?.dailyEntries.first?.totalTokens, 303)
        XCTAssertEqual(accounts.states[b]?.usage?.dailyEntries.first?.totalTokens, 202)
        try accounts.removeAccount(a)
        try await self.wait { tools.snapshot(for: .cursor).dailyEntries.first?.totalTokens != 303 }
    }

    func testOpenCodeProjectionFollowsSelectedProfileAndRetainsSoftwareWideLocalHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let connections = ToolConnectionStore(directory: fixture.root.appendingPathComponent("connections"),
                                               service: FixtureConnectionService(), home: fixture.root, environment: [:])
        try await connections.saveOpenCodeProfile(label: "Go first", apiKey: "fixture-first-key", cookie: nil)
        let first = try XCTUnwrap(connections.profiles(for: .openCode).first)
        try await connections.saveOpenCodeProfile(label: "Go second", apiKey: "fixture-second-key", cookie: nil)
        let second = try XCTUnwrap(connections.profiles(for: .openCode).last)
        let tools = ToolUsageStore(collectors: [], cacheURL: fixture.root.appendingPathComponent("history.json"),
            preferencesStore: fixture.preferences, connectionStore: connections)
        try connections.select(first.id)
        try await self.wait { tools.quota(for: .openCode).windows.first?.usedPercent == 11 }
        try connections.select(second.id)
        try await self.wait { tools.quota(for: .openCode).windows.first?.usedPercent == 22 }
        XCTAssertTrue(tools.snapshot(for: .openCode).dailyEntries.isEmpty,
                      "凭据查询的额度不能捏造成该账号的本地token历史")
        try connections.setEnabled(second.id, enabled: false)
        try await self.wait { tools.quota(for: .openCode).windows.first?.usedPercent == 11 }
    }

    func testNativeAccountPanelsShowRealConnectionsAndProviderSpecificAddControls() async throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else { throw XCTSkip("只在隔离测试窗口中验证") }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let accounts = CursorAccountStore(rootURL: fixture.root.appendingPathComponent("accounts"), service: FixtureCursorService(),
            sessionReader: CursorDesktopSessionReader(databaseURL: fixture.root.appendingPathComponent("missing.db")),
            preferencesStore: fixture.preferences)
        let a = try await accounts.addAccount(sessionCookie: Self.cookie("user_first"), alias: "Cursor Fixture A")
        let b = try await accounts.addAccount(sessionCookie: Self.cookie("user_second"), alias: "Cursor Fixture B")
        await accounts.refreshAccount(a, force: true); await accounts.refreshAccount(b, force: true)
        let connections = ToolConnectionStore(directory: fixture.root.appendingPathComponent("connections"),
            service: FixtureConnectionService(), home: fixture.root, environment: [:])
        try await connections.saveOpenCodeProfile(label: "Go Fixture A", apiKey: "fixture-first-key", cookie: nil)
        try await connections.saveOpenCodeProfile(label: "Go Fixture B", apiKey: "fixture-second-key", cookie: nil)
        let tools = ToolUsageStore(collectors: [], cacheURL: fixture.root.appendingPathComponent("usage.json"),
            preferencesStore: fixture.preferences, cursorAccountStore: accounts, connectionStore: connections)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-managed-account-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for client in ToolUsageClient.allCases {
            for (inline, width) in [(false, CGFloat(560)), (true, CGFloat(332)), (true, CGFloat(315))] {
                let view = ManagedToolAccountsView(client: client, cursorAccounts: accounts, connections: connections,
                    preferencesStore: fixture.preferences, toolUsageStore: tools,
                    openURL: { _ in XCTFail("不应打开真实浏览器") }, isInline: inline)
                let host = NSHostingView(rootView: view)
                let size = CGSize(width: width, height: inline ? 900 : 820)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.frame = NSRect(origin: .zero, size: size)
                for _ in 0..<12 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = client.rawValue + (inline ? "-inline-\(Int(width))" : "")
                try png.write(to: output.appendingPathComponent(name + ".png"))
                let image = try XCTUnwrap(bitmap.cgImage)
                let accountNames: [String]
                switch client {
                case .cursor: accountNames = ["Cursor Fixture A", "Cursor Fixture B"]
                case .openCode: accountNames = ["Go Fixture A", "Go Fixture B"]
                case .claudeCode, .deepSeekHarness: accountNames = []
                }
                let text = try self.panelText(in: image, accountNames: accountNames)
                try text.write(to: output.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
                XCTAssertTrue(text.contains("自动识别") || text.contains("Discover"), text)
                XCTAssertTrue(text.contains("读取设置") || text.contains("Collection settings"), text)
                switch client {
                case .cursor:
                    XCTAssertTrue(text.contains("Cursor Fixture A"), text)
                    XCTAssertTrue(text.contains("Cursor Fixture B"), text)
                    XCTAssertTrue(text.contains("手动添加") || text.contains("Add account manually"), text)
                case .openCode:
                    XCTAssertTrue(text.contains("Go Fixture A"), text)
                    XCTAssertTrue(text.contains("Go Fixture B"), text)
                    XCTAssertTrue(text.contains("添加接入") || text.contains("Add connection"), text)
                case .claudeCode:
                    XCTAssertTrue(text.contains("连接 Claude") || text.contains("Connect Claude"), text)
                case .deepSeekHarness:
                    XCTAssertTrue(inline ? text.localizedCaseInsensitiveContains("DeepSeek Key")
                                  : text.localizedCaseInsensitiveContains("DeepSeek API Key"), text)
                }
                if inline {
                    XCTAssertTrue(self.scrollViews(in: host).isEmpty, "内联账号区不得增加自己的滚动容器")
                    XCTAssertFalse(text.contains("账号与额度") || text.contains("Accounts and limits"),
                                   "内联账号区复用外层软件标题")
                    let identifiers = Set(self.accessibilityElements(window).compactMap { $0.accessibilityIdentifier() })
                    XCTAssertFalse(identifiers.contains("codexbar.accounts.\(client.rawValue).done"), "内联账号区无需关闭独立窗口")
                    for button in self.buttons(in: host) {
                        let frame = host.convert(button.bounds, from: button)
                        XCTAssertGreaterThanOrEqual(frame.minX, -0.5, name)
                        XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "内联账号按钮不得溢出实际内容视口：\(name)")
                    }
                }
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    func testCursorHeaderExpandsBothAccountsInsideTheSameManagementViewport() async throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else { throw XCTSkip("只在隔离测试窗口中验证") }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.update {
            $0.preferredMenuHeight = 640
            $0.theme = .dark
            $0.fontScale = 1
            $0.toolOrder = ["cursor", "codex", "claudeCode", "openCode", "deepSeekHarness"]
            $0.collapsedManagementTools = ApplicationPreferences.allTools
        }
        let accounts = CursorAccountStore(rootURL: fixture.root.appendingPathComponent("accounts"), service: FixtureCursorService(),
            sessionReader: CursorDesktopSessionReader(databaseURL: fixture.root.appendingPathComponent("missing.db")),
            preferencesStore: fixture.preferences)
        let first = try await accounts.addAccount(sessionCookie: Self.cookie("user_first"), alias: "Cursor Inline A")
        let second = try await accounts.addAccount(sessionCookie: Self.cookie("user_second"), alias: "Cursor Inline B")
        await accounts.refreshAccount(first, force: true)
        await accounts.refreshAccount(second, force: true)
        let selectedAccount = accounts.selectedAccountID
        let connections = ToolConnectionStore(directory: fixture.root.appendingPathComponent("connections"),
            service: FixtureConnectionService(), home: fixture.root, environment: [:])
        let tools = ToolUsageStore(collectors: [], quotaFetcher: FixtureManagedQuotaFetcher(),
            cacheURL: fixture.root.appendingPathComponent("usage.json"), preferencesStore: fixture.preferences,
            cursorAccountStore: accounts, connectionStore: connections)
        let gateway = FixtureManagedGateway()
        let store = TokenStore(syncService: FixtureManagedCodexSync(), openAIAccountGatewayService: FixtureManagedAccountGateway(),
            openRouterGatewayService: gateway, chatCompletionsGatewayService: gateway,
            localCostRefreshWorker: { _, _, _ in
                LocalCostRefreshOutcome(summary: .empty, isComplete: true, mayReplaceLastKnownGood: true,
                    warningCount: 0, lastRawSessionScanAt: nil, latestUsageEventAt: nil, progress: .zero, errorMessage: nil)
            }, codexRunningProcessIDs: { [] }, loadServiceTierCatalog: { nil })
        let sync = DeviceUsageSyncService(storageURL: fixture.root.appendingPathComponent("sync"), startConfiguredMode: false)
        let view = MenuBarView(toolUsageStore: tools, preferencesStore: fixture.preferences, deviceSync: sync, initialPage: .limits)
            .environmentObject(store).environmentObject(OAuthManager()).environmentObject(UpdateCoordinator())
            .defaultAppStorage(fixture.defaults)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 640)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-managed-account-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await self.wait { self.scrollViews(in: host).count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        let originalWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        try self.writeImage(host, to: output.appendingPathComponent("cursor-management-initial-collapsed.png"))
        try self.texts(in: host).map(\.text).joined(separator: "\n")
            .write(to: output.appendingPathComponent("cursor-management-initial-collapsed.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(try self.texts(in: host).contains { $0.text.contains("Cursor Inline A") || $0.text.contains("Cursor Inline B") })
        let headerAnchor = try self.pressCursorHeader(in: host, window: window)
        try await self.wait { !fixture.preferences.preferences.isManagementToolCollapsed("cursor") }
        XCTAssertEqual(Set(NSApplication.shared.windows.map(ObjectIdentifier.init)), originalWindows,
                       "点击软件标题应展开当前管理页，不能新开账号窗口")
        XCTAssertEqual(self.scrollViews(in: host).count, 1, "账号列表应使用外层管理视口")
        let scroll = try XCTUnwrap(self.scrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        var renderedText = ""
        for (index, offset) in [CGFloat.zero, CGFloat(280), max(0, document.bounds.height - scroll.contentView.bounds.height)].enumerated() {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let clamped = min(offset, maximum)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? clamped : maximum - clamped))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            renderedText += try self.texts(in: host).map(\.text).joined(separator: "\n") + "\n"
            try self.writeImage(host, to: output.appendingPathComponent("cursor-management-inline-\(index).png"))
        }
        XCTAssertTrue(renderedText.contains("Cursor Inline A"), renderedText)
        XCTAssertTrue(renderedText.contains("Cursor Inline B"), renderedText)
        XCTAssertTrue(renderedText.contains("手动添加") || renderedText.contains("Add account manually"), renderedText)
        try renderedText.write(to: output.appendingPathComponent("cursor-management-inline.txt"), atomically: true, encoding: .utf8)
        _ = try self.pressCursorHeader(in: host, window: window, anchorFromDocumentTop: headerAnchor)
        try await self.wait { fixture.preferences.preferences.isManagementToolCollapsed("cursor") }
        try self.writeImage(host, to: output.appendingPathComponent("cursor-management-final-collapsed.png"))
        XCTAssertFalse(try self.texts(in: host).contains { $0.text.contains("Cursor Inline A") || $0.text.contains("Cursor Inline B") })
        XCTAssertTrue(ApplicationPreferencesStore(defaults: fixture.defaults).preferences.isManagementToolCollapsed("cursor"))
        XCTAssertEqual(accounts.selectedAccountID, selectedAccount, "展开和收起不能切换看板账号")
        XCTAssertEqual(Set(NSApplication.shared.windows.map(ObjectIdentifier.init)), originalWindows)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.listeningPort)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { self.scrollViews(in: $0) }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { self.buttons(in: $0) }
    }

    private func accessibilityElements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 20, let element = object as? NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { self.accessibilityElements($0, depth: depth + 1) }
    }

    private func writeImage(_ host: NSView, to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func panelText(in image: CGImage, accountNames: [String]) throws -> String {
        var text = try self.recognizedPanelText(in: image)
        guard !accountNames.allSatisfy({ text.contains($0) }) else { return text }

        // 窄窗口会生成很长的实际布局图，全文 OCR 会把相邻中文段落和英文账号名
        // 错分成竖向碎片。只裁切同一张已渲染图，不更改像素或放宽完整名称断言。
        // 正方形分段重叠一半，避免行恰好跨过边界；尺寸来自实际图像，而非固定账号位置。
        let tileHeight = min(image.width, image.height)
        let step = max(1, tileHeight / 2)
        for top in stride(from: 0, to: image.height, by: step) {
            let bounds = CGRect(x: 0, y: CGFloat(top), width: CGFloat(image.width),
                                height: CGFloat(min(tileHeight, image.height - top)))
            let tile = try XCTUnwrap(image.cropping(to: bounds))
            text += "\n" + (try self.recognizedPanelText(in: tile))
            if accountNames.allSatisfy({ text.contains($0) }) { break }
        }
        return text
    }

    private func recognizedPanelText(in image: CGImage) throws -> String {
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["zh-Hans", "en-US"]
        recognition.customWords = ["Cursor Fixture A", "Cursor Fixture B", "Go Fixture A", "Go Fixture B"]
        recognition.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([recognition])
        return (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func texts(in host: NSView) throws -> [(text: String, bounds: CGRect)] {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLanguages = ["zh-Hans", "en-US"]
        recognition.customWords = ["Cursor"]
        recognition.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([recognition])
        return (recognition.results ?? []).compactMap { result in
            guard let text = result.topCandidates(1).first?.string else { return nil }
            let box = result.boundingBox
            return (text, CGRect(x: box.minX * host.bounds.width, y: (1 - box.maxY) * host.bounds.height,
                                 width: box.width * host.bounds.width, height: box.height * host.bounds.height))
        }
    }

    @discardableResult
    private func pressCursorHeader(in host: NSView, window: NSWindow,
                                   anchorFromDocumentTop: NSRect? = nil) throws -> NSRect {
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(self.scrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        let anchor: NSRect
        if let anchorFromDocumentTop {
            anchor = anchorFromDocumentTop
        } else {
            let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
            let recognized = try self.texts(in: host)
            let title = try XCTUnwrap(recognized.first {
                let words = $0.text.components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.filter(\.isLetter).lowercased() }.filter { !$0.isEmpty }
                // 完整软件名仅容许已实测的一个 OCR 字符差异（CUYSOr）；账号名和“Cursor 模型”不匹配。
                let word = Array(words.last ?? "")
                let expected = Array("cursor")
                let matches = word.count == expected.count && zip(word, expected).filter { $0.0 != $0.1 }.count <= 1
                let frame = host.isFlipped ? $0.bounds
                    : CGRect(x: $0.bounds.minX, y: host.bounds.height - $0.bounds.maxY,
                             width: $0.bounds.width, height: $0.bounds.height)
                return matches && viewport.contains(NSPoint(x: frame.midX, y: frame.midY))
                    && frame.minX < viewport.midX
            }, "实际管理视口应可见 Cursor 软件标题：\(recognized.map(\.text).joined(separator: "\n"))")
            let frameInHost = host.isFlipped ? title.bounds
                : CGRect(x: title.bounds.minX, y: host.bounds.height - title.bounds.maxY,
                         width: title.bounds.width, height: title.bounds.height)
            let frameInDocument = document.convert(frameInHost, from: host)
            anchor = NSRect(x: frameInDocument.minX - document.bounds.minX,
                            y: document.isFlipped ? frameInDocument.minY - document.bounds.minY
                                : document.bounds.maxY - frameInDocument.maxY,
                            width: frameInDocument.width, height: frameInDocument.height)
        }
        // 文档高度在展开后变化；保存从文档顶部量出的标题锚点，再由原生坐标转换定位回它。
        let targetInDocument = NSRect(x: document.bounds.minX + anchor.minX,
            y: document.isFlipped ? document.bounds.minY + anchor.minY : document.bounds.maxY - anchor.maxY,
            width: anchor.width, height: anchor.height)
        document.scrollToVisible(targetInDocument.insetBy(dx: 0, dy: -8))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        let targetInHost = host.convert(targetInDocument, from: document)
        let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
        let pointInHost = try XCTUnwrap(viewport.contains(NSPoint(x: targetInHost.midX, y: targetInHost.midY))
            ? NSPoint(x: targetInHost.midX, y: targetInHost.midY) : nil,
            "软件标题锚点应滚回实际视口：viewport=\(viewport), header=\(targetInHost)")
        XCTContext.runActivity(named: "Cursor 软件标题命中实际滚动视口") { activity in
            let geometry = "document=\(document.bounds), flipped=\(document.isFlipped), clip=\(scroll.contentView.bounds), anchor=\(anchor), viewport=\(viewport), header=\(targetInHost)"
            let attachment = XCTAttachment(string: geometry)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        let identifier = "codexbar.management.cursor.header"
        if let element = self.accessibilityElements(window).first(where: { $0.accessibilityIdentifier() == identifier }),
           element.accessibilityPerformPress() { return anchor }
        if let button = self.buttons(in: host).first(where: { $0.accessibilityIdentifier() == identifier }) {
            button.performClick(nil)
            return anchor
        }
        XCTAssertFalse(window.isVisible, "事件只发送给自身未显示的 fixture 窗口")
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
        return anchor
    }

    private func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("投影未及时更新")
    }
    private static func cookie(_ userID: String) -> String {
        let payload = Data("{\"sub\":\"\(userID)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return userID + "%3A%3AeyJhbGciOiJub25lIn0." + payload + ".fixture"
    }
    @MainActor private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let preferences: ApplicationPreferencesStore
        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-account-fixture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            self.suite = "managed-account-fixture-" + UUID().uuidString
            self.defaults = UserDefaults(suiteName: self.suite)!
            self.preferences = ApplicationPreferencesStore(defaults: self.defaults)
        }
        func cleanUp() { self.defaults.removePersistentDomain(forName: self.suite); try? FileManager.default.removeItem(at: self.root) }
    }
}

private actor FixtureCursorService {}
extension FixtureCursorService: CursorAccountServicing {
    func probe(sessionCookie: String, now: Date) async throws -> CursorAccountProbe {
        let id = try CursorAccountService.userID(sessionCookie: sessionCookie)
        return CursorAccountProbe(identity: CursorAccountIdentity(userID: id, planType: "pro"), quota:
            ToolQuotaSnapshot(client: .cursor, status: .ready, providerName: "Cursor",
                windows: [.init(id: "fixture", label: "Cursor 模型", usedPercent: id == "user_first" ? 31 : 72)],
                refreshedAt: now, statusDetail: ""))
    }
    func usage(sessionCookie: String, now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        let id = try CursorAccountService.userID(sessionCookie: sessionCookie)
        return ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .server,
            dailyEntries: [.init(date: now, totalTokens: id == "user_first" ? 101 : 202)], refreshedAt: now)
    }
}

private actor FixtureConnectionService {}
extension FixtureConnectionService: ToolConnectionServicing {
    func discover(client: ToolUsageClient, preferences: ApplicationPreferences) async throws -> [DiscoveredToolConnection] { [] }
    func organizations(sessionKey: String) async throws -> [ClaudeOrganization] { [.init(id: "fixture-org", name: "Fixture Org")] }
    func query(profile: ManagedToolConnection, credential: ManagedToolCredential, now: Date) async throws -> ManagedToolQuotaResult {
        ManagedToolQuotaResult(snapshot: ToolQuotaSnapshot(client: profile.client, status: .ready, providerName: "OpenCode Go",
            windows: [.init(id: "rolling", label: "5 小时", usedPercent: credential.apiKey == "fixture-first-key" ? 11 : 22)],
            refreshedAt: now, statusDetail: ""))
    }
}

private struct FixtureManagedQuotaFetcher: ToolQuotaFetching {
    func fetch(client: ToolUsageClient, preferences: ApplicationPreferences, now: Date) async -> ToolQuotaSnapshot {
        ToolQuotaSnapshot(client: client, status: .notConfigured, providerName: client.displayName,
                          refreshedAt: now, statusDetail: "隔离 fixture，没有外部额度请求")
    }
}

private final class FixtureManagedCodexSync: CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws {}
}

private final class FixtureManagedGateway: OpenRouterGatewayControlling, ChatCompletionsGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {}
}

private final class FixtureManagedAccountGateway: OpenAIAccountGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(accounts: [TokenAccount], quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
                     accountUsageMode: CodexBarOpenAIAccountUsageMode, reserveActiveAccountQuota: Bool,
                     reserveActiveAccountQuotaPercent: Int, defaultProxy: OpenAIAccountGatewayConfiguredProxy?,
                     proxyByAccountID: [String: OpenAIAccountGatewayConfiguredProxy]) {}
    func currentRoutedAccountID() -> String? { nil }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID: String) -> Bool { false }
}
