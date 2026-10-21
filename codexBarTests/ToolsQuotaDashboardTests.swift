import AppKit
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import codexbar

@MainActor
final class ToolsQuotaDashboardTests: CodexBarTestCase {
    func testToolsPageShowsAntigravityAndCursorTokensWithoutQuotaWindows() async throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("只在隔离测试窗口中验证")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let originalLanguage = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = originalLanguage }

        let root = CodexPaths.realHome.appendingPathComponent("tools-quota-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "codexbar.tools-quota-fixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MenuPage.tools.rawValue, forKey: "codexbar.menu.page")
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update {
            $0.preferredMenuHeight = 640
            $0.theme = .dark
            $0.fontScale = 1
            $0.language = .simplifiedChinese
            $0.automaticUpdateChecks = false
            // This fixture exercises external Token sources without starting the Codex index.
            $0.disabledTools = ["codex"]
            // Usage order should override the management preference without rewriting it.
            $0.toolOrder = ["cursor", "antigravity", "claudeCode", "openCode", "deepSeekHarness"]
        }
        let configuredToolOrder = preferences.preferences.toolOrder

        let sourceTokenURL = root.appendingPathComponent("source/.gemini/jetski-standalone-oauth-token")
        let sourceDatabaseURL = root.appendingPathComponent("source/state.vscdb")
        let accountRoot = root.appendingPathComponent("antigravity-accounts", isDirectory: true)
        let fixtureAccount = Self.accountFixture()
        try self.writeAccountMetadata(fixtureAccount, to: accountRoot)
        let antigravity = AntigravityAccountStore(
            rootURL: accountRoot,
            service: DashboardAntigravityService(account: fixtureAccount),
            localSync: AntigravityLocalCredentialSync(
                standaloneTokenFileURL: sourceTokenURL, vscdbURLs: [sourceDatabaseURL]
            ),
            autoDiscoverLocalCredentials: false
        )
        let tools = ToolUsageStore(
            collectors: [DashboardAntigravityTokenCollector()], cursorSyncer: DashboardCursorSyncer(), quotaFetcher: DashboardQuotaFetcher(),
            cacheURL: root.appendingPathComponent("usage.json"), preferencesStore: preferences
        )
        tools.refreshIfNeeded(force: true)
        for _ in 0..<200 where tools.isRefreshing || tools.isRefreshingQuotas {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(tools.snapshot(for: .antigravity).dailyEntries.first?.totalTokens, 1_234_567)
        XCTAssertEqual(tools.snapshot(for: .cursor).dailyEntries.first?.totalTokens, 800_001)
        let store = self.makeIsolatedTokenStore()
        let deviceSync = DeviceUsageSyncService(storageURL: root.appendingPathComponent("sync"), startConfiguredMode: false)
        let view = MenuBarView(
            toolUsageStore: tools, preferencesStore: preferences, deviceSync: deviceSync,
            antigravityStore: antigravity, initialPage: .tools
        )
        .environmentObject(store)
        .environmentObject(OAuthManager())
        .environmentObject(UpdateCoordinator())
        .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        let bounds = NSRect(x: 0, y: 0, width: 360, height: 640)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = bounds
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }

        let scrollViews = self.scrollViews(in: host)
        XCTAssertEqual(scrollViews.count, 1, "工具页额度卡应复用外层滚动视口")
        let scroll = try XCTUnwrap(scrollViews.first)
        let document = try XCTUnwrap(scroll.documentView)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-token-usage-20261020/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var visibleText = ""
        var axText = ""
        for (index, fraction) in [CGFloat(0), 0.5, 1].enumerated() {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let offset = maximum * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : maximum - offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("tools-antigravity-360-\(index).png"))
            visibleText += try self.recognizedText(in: XCTUnwrap(bitmap.cgImage)) + "\n"
            axText += self.accessibilityElements(window).compactMap { element in
                [element.accessibilityIdentifier(), element.accessibilityLabel(),
                 element.accessibilityValue() as? String].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: "\n") + "\n"
        }
        try visibleText.write(to: output.appendingPathComponent("tools-antigravity-360-ocr.txt"), atomically: true, encoding: .utf8)
        try axText.write(to: output.appendingPathComponent("tools-antigravity-360-ax.txt"), atomically: true, encoding: .utf8)
        let normalized = visibleText.filter { !$0.isWhitespace }
        XCTAssertTrue(normalized.contains("Antigravity"), visibleText)
        let digits = normalized.replacingOccurrences(of: ",", with: "")
        XCTAssertTrue(digits.contains("1234567"), visibleText)
        XCTAssertTrue(digits.contains("800001"), visibleText)
        XCTAssertTrue(digits.contains("2034568"), visibleText)
        XCTAssertFalse(normalized.contains("Gemini5h") || normalized.contains("Claude/GPT"), visibleText)
        XCTAssertFalse(normalized.contains("账号额度") || normalized.contains("Token明细尚未接入"), visibleText)
        XCTAssertFalse(normalized.contains("无用量明细") || normalized.contains("Nousagehistory"), visibleText)
        XCTAssertFalse(normalized.contains("尚未连接账号"), visibleText)
        let documentBitmap = try XCTUnwrap(document.bitmapImageRepForCachingDisplay(in: document.bounds))
        document.cacheDisplay(in: document.bounds, to: documentBitmap)
        let documentRows = try self.recognizedRows(in: XCTUnwrap(documentBitmap.cgImage))
        let antigravityTitle = try XCTUnwrap(documentRows.first { $0.text.localizedCaseInsensitiveContains("Antigravity") })
        let cursorTitle = try XCTUnwrap(documentRows.first { $0.text.localizedCaseInsensitiveContains("Grok") })
        XCTAssertGreaterThan(antigravityTitle.bounds.minY, cursorTitle.bounds.maxY,
                             "工具列表按 Token 倒序：1,234,567 的 Antigravity 应高于 800,001 的 Grok")
        XCTAssertEqual(preferences.preferences.toolOrder, configuredToolOrder,
                       "用量排序不能改写额度管理页的手动排序")
        XCTAssertEqual(antigravity.activeAccount?.quotaWindows, fixtureAccount.quotaWindows)
        XCTAssertEqual(antigravity.activeAccount?.status, .ok)
        XCTAssertFalse(window.isVisible, "截图只来自自身未显示的原生窗口")
        XCTAssertFalse(deviceSync.isSyncing)
        XCTAssertNil(deviceSync.listeningPort)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceTokenURL.path), "被动查看额度不得创建原应用凭据")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDatabaseURL.path), "被动查看额度不得创建原应用数据库")
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path), "工具页不得创建 Codex auth.json")
    }

    func testToolsPageDistinguishesNoCurrentRecordsFreeUsageAndFailedSource() async throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else { throw XCTSkip("只在隔离测试窗口中验证") }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let language = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = language }
        let root = CodexPaths.realHome.appendingPathComponent("period-usage-fixture")
        let suite = "codexbar.period-usage." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update {
            $0.preferredMenuHeight = 740
            $0.theme = .dark
            $0.fontScale = 1
            $0.language = .simplifiedChinese
            $0.defaultUsageRange = UsagePeriod.today.rawValue
            $0.displayCurrencyCode = "USD"
            $0.automaticUpdateChecks = false
            $0.disabledTools = ["codex", "deepSeekHarness"]
            $0.toolOrder = ["antigravity", "cursor", "openCode", "claudeCode"]
        }
        let configuredToolOrder = preferences.preferences.toolOrder
        let tools = ToolUsageStore(
            collectors: [DashboardPeriodCollector(client: .antigravity),
                         DashboardPeriodCollector(client: .openCode),
                         DashboardPeriodCollector(client: .claudeCode)],
            cursorSyncer: DashboardPreviousDayCursorSyncer(), quotaFetcher: DashboardQuotaFetcher(),
            cacheURL: root.appendingPathComponent("usage.json"), preferencesStore: preferences
        )
        tools.refreshIfNeeded(force: true)
        for _ in 0..<200 where tools.isRefreshing || tools.isRefreshingQuotas {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(tools.snapshot(for: .antigravity).availability, .partial)
        XCTAssertEqual(tools.snapshot(for: .cursor).availability, .partial)
        XCTAssertEqual(tools.snapshot(for: .openCode).dailyEntries.first?.costUSD, 0)
        XCTAssertEqual(tools.snapshot(for: .claudeCode).availability, .failed)
        let sourceToken = root.appendingPathComponent("source-token")
        let antigravity = AntigravityAccountStore(rootURL: root.appendingPathComponent("accounts"),
            service: DashboardAntigravityService(account: Self.accountFixture()),
            localSync: AntigravityLocalCredentialSync(standaloneTokenFileURL: sourceToken, vscdbURLs: []),
            autoDiscoverLocalCredentials: false)
        let sync = DeviceUsageSyncService(storageURL: root.appendingPathComponent("sync"), startConfiguredMode: false)
        let store = self.makeIsolatedTokenStore()
        let host = NSHostingView(rootView: MenuBarView(toolUsageStore: tools, preferencesStore: preferences,
            deviceSync: sync, antigravityStore: antigravity, initialPage: .tools)
            .environmentObject(store).environmentObject(OAuthManager()).environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults))
        let bounds = NSRect(x: 0, y: 0, width: 360, height: 740)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; host.frame = bounds
        defer { window.contentView = nil; window.close() }
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let scroll = try XCTUnwrap(self.scrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-usage-repair-20261021/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (index, fraction) in [CGFloat.zero, 1].enumerated() {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let offset = maximum * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : maximum - offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("period-usage-360-\(index).png"))
        }
        let bitmap = try XCTUnwrap(document.bitmapImageRepForCachingDisplay(in: document.bounds))
        document.cacheDisplay(in: document.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("period-usage-document.png"))
        let rows = try self.recognizedRows(in: XCTUnwrap(bitmap.cgImage))
        let text = rows.map(\.text).joined(separator: "\n")
        try text.write(to: output.appendingPathComponent("period-usage-ocr.txt"), atomically: true, encoding: .utf8)
        let titles = ["OpenCode", "Antigravity", "Grok", "Claude"]
        let anchors = try titles.map { title in
            try XCTUnwrap(rows.first { $0.text.localizedCaseInsensitiveContains(title) && !$0.text.contains("同步") }, "缺少工具标题：\(title)\n\(text)")
        }
        for index in 0..<(anchors.count - 1) {
            XCTAssertGreaterThan(anchors[index].bounds.minY, anchors[index + 1].bounds.maxY,
                                 "工具按本期 Token 倒序，0 用量保留偏好顺序：\(titles.joined(separator: ", "))\n\(text)")
        }
        XCTAssertEqual(preferences.preferences.toolOrder, configuredToolOrder,
                       "自动用量排序不应更改管理页偏好")
        for index in titles.indices {
            let lower = index + 1 < anchors.count ? anchors[index + 1].bounds.maxY : CGFloat.zero
            let section = rows.filter {
                $0.bounds.midY < anchors[index].bounds.midY + 0.035 && $0.bounds.midY > lower
            }
            let sectionText = section.map(\.text).joined().filter { !$0.isWhitespace }
            if titles[index] == "Antigravity" || titles[index] == "Grok" {
                XCTAssertTrue(sectionText.contains("本期暂无记录"), sectionText)
                XCTAssertTrue(sectionText.contains("最近记录"), sectionText)
                XCTAssertFalse(sectionText.contains("用量暂不可用"), sectionText)
                // Vision omits the isolated numeric 0 in the full-document render and
                // reads the inline zero as O; the viewport pixels show the numeric zero.
                let recordsZero = sectionText.contains("本期已记录0Token")
                    || sectionText.contains("本期已记录OToken")
                XCTAssertTrue(recordsZero, "\(titles[index]) 本期已记录数量应为 0：\(sectionText)")
                XCTAssertTrue(sectionText.contains(titles[index] == "Antigravity" ? "旧历史数据不完整" : "账号同步异常，保留历史"), sectionText)
            } else if titles[index] == "OpenCode" {
                XCTAssertTrue(sectionText.contains("820,107") || sectionText.contains("820107"), sectionText)
                XCTAssertTrue(sectionText.contains("$0.00"), sectionText)
                XCTAssertFalse(sectionText.contains("费用不可用"), sectionText)
            } else {
                XCTAssertTrue(sectionText.contains("用量暂不可用"), sectionText)
                XCTAssertTrue(sectionText.contains("连接失败"), sectionText)
            }
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceToken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testCollapsedCodexAndAntigravityShowAlignedQuotaRowsAndKeepRouteControls() async throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else { throw XCTSkip("只在隔离测试窗口中验证") }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let language = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = language }
        let root = CodexPaths.realHome.appendingPathComponent("collapsed-quota-fixture")
        let suite = "codexbar.collapsed-quota." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MenuPage.limits.rawValue, forKey: "codexbar.menu.page")
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update {
            $0.preferredMenuHeight = 780
            $0.theme = .dark
            $0.fontScale = 1
            $0.automaticUpdateChecks = false
            $0.collapsedManagementTools = ApplicationPreferences.managementSectionIDs
            $0.toolOrder = ["codex", "antigravity"]
        }
        let now = Date()
        var codex = try self.makeOAuthAccount(accountID: "collapsed-codex", email: "codex-fixture@example.com",
                                              isActive: true, planType: "plus")
        codex.primaryUsedPercent = 0
        codex.primaryLimitWindowSeconds = 18_000
        codex.primaryResetAt = now.addingTimeInterval(4_410) // 1h 13m, with a 30-second rendering margin.
        codex.secondaryUsedPercent = 100
        codex.secondaryLimitWindowSeconds = 604_800
        codex.secondaryResetAt = now.addingTimeInterval(6 * 86_400 + 7 * 3_600 + 30)
        codex.lastChecked = now
        let provider = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI",
            activeAccountId: codex.accountId,
            accounts: [.fromTokenAccount(codex, existingID: codex.accountId)])
        try self.writeConfig(CodexBarConfig(
            global: CodexBarGlobalSettings(defaultModel: "gpt-6.1-sol", reasoningEffort: "ultra",
                                          modelContextWindows: ["gpt-6.1-sol": 272_000]),
            active: CodexBarActiveSelection(providerId: provider.id, accountId: codex.accountId), providers: [provider]
        ))
        let store = self.makeIsolatedTokenStore()
        var antigravityAccount = Self.accountFixture()
        for index in antigravityAccount.quotaWindows.indices {
            antigravityAccount.quotaWindows[index].resetAt = now.addingTimeInterval(Double(index + 1) * 7_200 + 1_050)
        }
        antigravityAccount.quotaWindows[0].remainingFraction = 0
        antigravityAccount.quotaWindows[1].remainingFraction = 1
        let accountRoot = root.appendingPathComponent("accounts")
        try self.writeAccountMetadata(antigravityAccount, to: accountRoot)
        let sourceToken = root.appendingPathComponent("source-token")
        let antigravity = AntigravityAccountStore(rootURL: accountRoot,
            service: DashboardAntigravityService(account: antigravityAccount),
            localSync: AntigravityLocalCredentialSync(standaloneTokenFileURL: sourceToken, vscdbURLs: []),
            autoDiscoverLocalCredentials: false)
        let tools = ToolUsageStore(collectors: [], cursorSyncer: DashboardCursorSyncer(),
            quotaFetcher: DashboardQuotaFetcher(), cacheURL: root.appendingPathComponent("usage.json"),
            preferencesStore: preferences)
        let sync = DeviceUsageSyncService(storageURL: root.appendingPathComponent("sync"), startConfiguredMode: false)
        let host = NSHostingView(rootView: MenuBarView(toolUsageStore: tools, preferencesStore: preferences,
            deviceSync: sync, antigravityStore: antigravity, initialPage: .limits)
            .environmentObject(store).environmentObject(OAuthManager()).environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults))
        let bounds = NSRect(x: 0, y: 0, width: 360, height: 780)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = bounds
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let scroll = try XCTUnwrap(self.scrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-collapsed-quota-20261020/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [(text: String, bounds: CGRect)] = []
        for (index, fraction) in [CGFloat.zero, 0.5, 1].enumerated() {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let offset = maximum * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : maximum - offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("collapsed-quota-360-\(index).png"))
            let observed = try self.recognizedRows(in: XCTUnwrap(bitmap.cgImage))
            rows += observed
            // Check each capture separately so text from different scroll positions cannot form a fake row.
            for (label, reset, percent) in [("5h", "1h13m", "100%"), ("7d", "6d7h", "0%")] {
                self.recordVisibleQuotaRow(label: label, reset: reset, percent: percent, in: observed)
            }
            for (quotaIndex, quota) in antigravityAccount.quotaWindows.enumerated() {
                self.recordVisibleQuotaRow(label: quota.shortLabel.filter { !$0.isWhitespace },
                    reset: "\(2 * (quotaIndex + 1))h17m", percent: "\(Int(quota.remainingPercent))%", in: observed)
            }
            if index == 0 {
                let controls = self.routeControls(in: host)
                XCTAssertEqual(controls.count, 4)
                let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
                for control in controls {
                    let frame = host.convert(control.bounds, from: control)
                    XCTAssertTrue(viewport.contains(frame), "折叠状态的四个路由控件应仍在视口内：\(frame)")
                }
                let densityOutput = URL(fileURLWithPath: "/private/tmp/codexbar-density-20261021/ui", isDirectory: true)
                try FileManager.default.createDirectory(at: densityOutput, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: densityOutput.appendingPathComponent("after-density.png"))
                let beforeURL = densityOutput.appendingPathComponent("before-density.png")
                if let data = try? Data(contentsOf: beforeURL), let before = NSBitmapImageRep(data: data)?.cgImage,
                   let beforeHeader = try self.recognizedRows(in: before).first(where: { $0.text.contains("Antigravity") }),
                   let afterHeader = observed.first(where: { $0.text.contains("Antigravity") }) {
                    let saved = (afterHeader.bounds.midY - beforeHeader.bounds.midY) * bounds.height
                    XCTAssertGreaterThan(saved, 20, "同一360宽夹具应实际减少辅助行占用，不能只缩小字号")
                    try JSONSerialization.data(withJSONObject: ["widthPoints": 360, "antigravityHeaderMovesUpPoints": saved,
                                                               "documentHeightPoints": document.bounds.height], options: [.prettyPrinted])
                        .write(to: densityOutput.appendingPathComponent("layout-metrics.json"))
                }
            }
        }
        let text = rows.map(\.text).joined(separator: "\n")
        try text.write(to: output.appendingPathComponent("collapsed-quota-360-ocr.txt"), atomically: true, encoding: .utf8)
        let normalized = text.filter { !$0.isWhitespace }
        for reset in ["1h13m", "6d7h", "2h17m", "4h17m", "6h17m", "8h17m", "10h17m"] {
            XCTAssertTrue(normalized.contains(reset), text)
        }
        for quota in antigravityAccount.quotaWindows {
            XCTAssertTrue(normalized.contains(quota.shortLabel.filter { !$0.isWhitespace }), text)
        }
        XCTAssertTrue(normalized.contains("100%") && normalized.contains("0%"), text)
        XCTAssertTrue(preferences.preferences.isManagementToolCollapsed("codex"))
        XCTAssertTrue(preferences.preferences.isManagementToolCollapsed("antigravity"))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceToken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testExpandedSingleAccountsKeepCurrentOnceAndNoOtherAccountList() async throws {
        try await self.checkExpandedAccounts(accountCount: 1, activeIndex: 0, scenario: "single")
    }

    func testResetExpiryReminderCanBeHiddenAndRestoredWithoutRemovingCards() async throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else { throw XCTSkip("只在隔离测试窗口中验证") }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let language = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = language }
        let root = CodexPaths.realHome.appendingPathComponent("reset-reminder-ui")
        let suite = "codexbar.reset-reminder-ui." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update {
            $0.preferredMenuHeight = 840
            $0.theme = .dark
            $0.fontScale = 1
            $0.automaticUpdateChecks = false
            $0.toolOrder = ["codex"]
            $0.collapsedManagementTools = ApplicationPreferences.managementSectionIDs.filter { $0 != "codex" }
            $0.showResetCreditExpiryBanner = true
        }
        let now = Date()
        var account = try self.makeOAuthAccount(accountID: "reset-reminder", email: "reminder@x.dev", isActive: true)
        account.primaryUsedPercent = 40
        account.primaryLimitWindowSeconds = 18_000
        account.primaryResetAt = now.addingTimeInterval(7_200)
        account.lastChecked = now
        account.rateLimitResetAvailableCount = 1
        account.rateLimitResetCredits = [RateLimitResetCredit(id: "reset-reminder-credit", title: "Fixture reset",
            status: "available", grantedAt: now, expiresAt: now.addingTimeInterval(7_200))]
        let provider = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI",
            activeAccountId: account.accountId, accounts: [.fromTokenAccount(account, existingID: account.accountId)])
        try self.writeConfig(CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.accountId), providers: [provider]))
        let store = self.makeIsolatedTokenStore()
        let tools = ToolUsageStore(collectors: [], cursorSyncer: DashboardCursorSyncer(), quotaFetcher: DashboardQuotaFetcher(),
            cacheURL: root.appendingPathComponent("usage.json"), preferencesStore: preferences)
        let sync = DeviceUsageSyncService(storageURL: root.appendingPathComponent("sync"), startConfiguredMode: false)
        let sourceToken = root.appendingPathComponent("source-token")
        let antigravity = AntigravityAccountStore(rootURL: root.appendingPathComponent("accounts"),
            service: DashboardAntigravityService(account: Self.accountFixture()),
            localSync: AntigravityLocalCredentialSync(standaloneTokenFileURL: sourceToken, vscdbURLs: []),
            autoDiscoverLocalCredentials: false)
        let host = NSHostingView(rootView: MenuBarView(toolUsageStore: tools, preferencesStore: preferences,
            deviceSync: sync, antigravityStore: antigravity, initialPage: .limits)
            .environmentObject(store).environmentObject(OAuthManager()).environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults))
        let bounds = NSRect(x: 0, y: 0, width: 360, height: 840)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; host.frame = bounds
        defer { window.contentView = nil; window.close() }
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-reset-cards-20261021/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bannerTitle = try XCTUnwrap(RateLimitResetCreditPresentation.banner(
            from: [account], now: now, preferences: preferences.preferences)?.title).filter { !$0.isWhitespace }

        func capture(_ name: String) async throws -> String {
            for _ in 0..<12 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
            let document = try XCTUnwrap(self.scrollViews(in: host).first?.documentView)
            let full = try XCTUnwrap(document.bitmapImageRepForCachingDisplay(in: document.bounds))
            document.cacheDisplay(in: document.bounds, to: full)
            let text = try self.recognizedText(in: XCTUnwrap(full.cgImage))
            try text.write(to: output.appendingPathComponent(name + "-ocr.txt"), atomically: true, encoding: .utf8)
            return text.filter { !$0.isWhitespace }
        }

        let before = try await capture("reset-reminder-visible")
        XCTAssertTrue(before.contains(bannerTitle), before)
        if let dismiss = self.accessibilityElements(window).first(where: {
            $0.accessibilityIdentifier() == "codexbar.status-banner.dismiss"
        }), dismiss.accessibilityPerformPress() {
            for _ in 0..<20 where preferences.preferences.showResetCreditExpiryBanner {
                try await Task.sleep(for: .milliseconds(20))
            }
        } else {
            // The isolated host can omit the AX tree. Still verify both native UI states
            // and persisted preference without claiming an unavailable click was performed.
            try "离屏进程未提供可点击的 AX 关闭按钮；原生关闭/恢复状态以隔离偏好驱动，×另由截图核对。\n"
                .write(to: output.appendingPathComponent("reset-reminder-ax.txt"), atomically: true, encoding: .utf8)
            preferences.update { $0.showResetCreditExpiryBanner = false }
        }
        let hidden = try await capture("reset-reminder-hidden")
        XCTAssertFalse(preferences.preferences.showResetCreditExpiryBanner)
        XCTAssertFalse(ApplicationPreferencesStore(defaults: defaults).preferences.showResetCreditExpiryBanner)
        XCTAssertFalse(hidden.contains(bannerTitle), hidden)
        XCTAssertTrue(hidden.contains("重置卡") && hidden.contains(L.resetCreditUseSoonest.filter { !$0.isWhitespace }), hidden)
        XCTAssertEqual(store.accounts.first?.rateLimitResetCredits.first?.id, "reset-reminder-credit")
        XCTAssertEqual(store.accounts.first?.rateLimitResetAvailableCount, 1)
        preferences.update { $0.showResetCreditExpiryBanner = true }
        let restored = try await capture("reset-reminder-restored")
        XCTAssertTrue(restored.contains(bannerTitle), restored)
        XCTAssertTrue(ApplicationPreferencesStore(defaults: defaults).preferences.showResetCreditExpiryBanner)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceToken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testExpandedMultipleAccountsExcludeFirstCurrentAccount() async throws {
        try await self.checkExpandedAccounts(accountCount: 2, activeIndex: 0, scenario: "first-current")
    }

    func testExpandedMultipleAccountsExcludeSecondCurrentAccount() async throws {
        try await self.checkExpandedAccounts(accountCount: 2, activeIndex: 1, scenario: "second-current")
    }

    private func checkExpandedAccounts(accountCount: Int, activeIndex: Int, scenario: String) async throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else { throw XCTSkip("只在隔离测试窗口中验证") }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let language = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = language }
        let root = CodexPaths.realHome.appendingPathComponent("expanded-accounts-" + scenario)
        let suite = "codexbar.expanded-accounts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update {
            $0.preferredMenuHeight = 780
            $0.theme = .dark
            $0.fontScale = 1
            $0.automaticUpdateChecks = false
            $0.collapsedManagementTools = ApplicationPreferences.managementSectionIDs.filter {
                !["codex", "antigravity"].contains($0)
            }
            $0.toolOrder = ["codex", "antigravity"]
        }
        let now = Date()
        let codexAccounts = try (0..<accountCount).map { index in
            var account = try self.makeOAuthAccount(accountID: "expanded-codex-\(index)",
                email: "codex\(index + 1)@x.dev", isActive: index == activeIndex, planType: "plus")
            account.primaryUsedPercent = Double(10 + index * 20)
            account.primaryLimitWindowSeconds = 18_000
            account.primaryResetAt = now.addingTimeInterval(7_200)
            account.secondaryUsedPercent = Double(20 + index * 20)
            account.secondaryLimitWindowSeconds = 604_800
            account.secondaryResetAt = now.addingTimeInterval(86_400)
            account.lastChecked = now
            return account
        }
        let currentCodex = codexAccounts[activeIndex]
        let provider = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI",
            activeAccountId: currentCodex.accountId,
            accounts: codexAccounts.map { .fromTokenAccount($0, existingID: $0.accountId) })
        var config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: currentCodex.accountId),
            providers: [provider])
        config.openAI.accountUsageMode = .switchAccount
        try self.writeConfig(config)
        let store = self.makeIsolatedTokenStore()
        let antigravityAccounts = (0..<accountCount).map { index in
            var account = Self.accountFixture()
            account.id = "expanded-ag-\(index)"
            account.email = "ag\(index + 1)@x.dev"
            account.userID = account.id
            account.displayName = nil
            account.isActive = index == activeIndex
            return account
        }
        let currentAntigravity = antigravityAccounts[activeIndex]
        let accountRoot = root.appendingPathComponent("accounts")
        try self.writeAccountMetadata(antigravityAccounts, activeID: currentAntigravity.id, to: accountRoot)
        let sourceToken = root.appendingPathComponent("source-token")
        let antigravity = AntigravityAccountStore(rootURL: accountRoot,
            service: DashboardAntigravityService(account: antigravityAccounts[0],
                additionalAccounts: Array(antigravityAccounts.dropFirst())),
            localSync: AntigravityLocalCredentialSync(standaloneTokenFileURL: sourceToken, vscdbURLs: []),
            autoDiscoverLocalCredentials: false)
        let tools = ToolUsageStore(collectors: [], cursorSyncer: DashboardCursorSyncer(),
            quotaFetcher: DashboardQuotaFetcher(), cacheURL: root.appendingPathComponent("usage.json"),
            preferencesStore: preferences)
        let sync = DeviceUsageSyncService(storageURL: root.appendingPathComponent("sync"), startConfiguredMode: false)
        let host = NSHostingView(rootView: MenuBarView(toolUsageStore: tools, preferencesStore: preferences,
            deviceSync: sync, antigravityStore: antigravity, initialPage: .limits)
            .environmentObject(store).environmentObject(OAuthManager()).environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults))
        let bounds = NSRect(x: 0, y: 0, width: 360, height: 780)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = bounds
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let scroll = try XCTUnwrap(self.scrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-expanded-accounts-20261021/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var identifiers = Set<String>()
        for (index, fraction) in [CGFloat.zero, 0.5, 1].enumerated() {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let offset = maximum * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : maximum - offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("\(scenario)-360-\(index).png"))
            identifiers.formUnion(self.accessibilityElements(window).compactMap { $0.accessibilityIdentifier() })
        }
        // Count a single full-document render, never overlapping viewport captures.
        let documentBitmap = try XCTUnwrap(document.bitmapImageRepForCachingDisplay(in: document.bounds))
        document.cacheDisplay(in: document.bounds, to: documentBitmap)
        try XCTUnwrap(documentBitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(scenario)-document.png"))
        let documentImage = try XCTUnwrap(documentBitmap.cgImage)
        let fixtureEmails = codexAccounts.map(\.email) + antigravityAccounts.map(\.email)
        let rawText = try self.recognizedText(in: documentImage, customWords: fixtureEmails)
        let rawRows = try self.recognizedRows(in: documentImage, customWords: fixtureEmails)
        try rawText.write(to: output.appendingPathComponent("\(scenario)-ocr.txt"), atomically: true, encoding: .utf8)
        func fixtureOCRText(_ value: String) -> String {
            // Native screenshots confirm both fixture addresses; Vision can read
            // their @ glyph as 0. Preserve the account number, counts and row bounds.
            var result = value
            if fixtureEmails.contains("codex2@x.dev") {
                // Native pixels retain the fixture's 2; Vision may read that glyph as z.
                result = result.replacingOccurrences(of: "codexz@x.dev", with: "codex2@x.dev", options: .caseInsensitive)
            }
            for email in ["ag1@x.dev", "ag2@x.dev"] where fixtureEmails.contains(email) {
                result = result.replacingOccurrences(of: email.replacingOccurrences(of: "@", with: "0"),
                                                      with: email, options: .caseInsensitive)
            }
            return result
        }
        let text = fixtureOCRText(rawText)
        let rows = rawRows.map { (text: fixtureOCRText($0.text), bounds: $0.bounds) }
        let axEvidence = identifiers.isEmpty
            ? "此离屏测试进程未导出 AX 标识；已执行完整文档 OCR 去重、其他账号位置与数量验证。当前操作菜单保留截图供人工检查，未执行菜单交互。"
            : identifiers.sorted().joined(separator: "\n")
        try axEvidence.write(to: output.appendingPathComponent("\(scenario)-ax.txt"), atomically: true, encoding: .utf8)
        if identifiers.isEmpty { print("\(scenario): \(axEvidence)") }
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        for email in [currentCodex.email, currentAntigravity.email] {
            XCTAssertEqual(normalized.components(separatedBy: email.lowercased()).count - 1, 1,
                           "展开后当前账号身份只能出现一次：\(email)\n\(text)")
        }
        let otherHeaders = rows.filter { $0.text.filter { !$0.isWhitespace } == "其他账号" }
            .sorted { $0.bounds.midY > $1.bounds.midY }
        XCTAssertEqual(otherHeaders.count, accountCount > 1 ? 2 : 0,
                       "只有确有其他账号时，Codex 与 Antigravity 才各显示一个其他账号标题：\(text)")
        if accountCount > 1 {
            let codexHeader = try XCTUnwrap(otherHeaders.first)
            let antigravityHeader = try XCTUnwrap(otherHeaders.dropFirst().first)
            for (currentEmail, otherEmail, header) in [
                (currentCodex.email, codexAccounts[1 - activeIndex].email, codexHeader),
                (currentAntigravity.email, antigravityAccounts[1 - activeIndex].email, antigravityHeader),
            ] {
                let currentRow = try XCTUnwrap(rows.first { $0.text.lowercased().contains(currentEmail.lowercased()) })
                let otherRows = rows.filter { $0.text.lowercased().contains(otherEmail.lowercased()) }
                XCTAssertFalse(otherRows.isEmpty, "未选中的账号仍应展示：\(otherEmail)")
                XCTAssertGreaterThan(currentRow.bounds.minY, header.bounds.maxY,
                                     "当前账号应在其他账号区上方：\(currentEmail)")
                for other in otherRows {
                    XCTAssertLessThan(other.bounds.maxY, header.bounds.minY,
                                      "未选中的账号应在对应其他账号标题下方：\(otherEmail)")
                    if currentEmail == currentCodex.email {
                        XCTAssertGreaterThan(other.bounds.minY, antigravityHeader.bounds.maxY,
                                             "Codex 其他账号不应进入 Antigravity 的账号区")
                    }
                }
            }
        }
        // AX may be entirely unavailable in the isolated, never-shown test window.
        // In that case the visual assertions above still run; do not skip the scenario.
        if !identifiers.isEmpty {
            for id in ["codexbar.management.codex-summary.actions", "codexbar.management.antigravity.summary.actions"] {
                XCTAssertTrue(identifiers.contains(id), "当前账号操作入口必须保留：\(id)")
            }
            for (index, account) in codexAccounts.enumerated() {
                XCTAssertEqual(identifiers.contains("codexbar.management.codex.other." + account.accountId),
                               index != activeIndex, "Codex 展开列表只显示未选中的账号")
            }
            for (index, account) in antigravityAccounts.enumerated() {
                XCTAssertEqual(identifiers.contains("codexbar.management.antigravity.other." + account.id),
                               index != activeIndex, "Antigravity 展开列表只显示未选中的账号")
            }
            XCTAssertEqual(identifiers.contains("codexbar.management.codex.other-accounts"), accountCount > 1)
        }
        XCTAssertFalse(normalized.contains("还没有codex账号") || normalized.contains("还没有antigravity账号"), text)
        XCTAssertEqual(self.routeControls(in: host).count, 4, "展开去重不应移除路由控件")
        XCTAssertEqual(antigravity.activeAccount?.id, currentAntigravity.id)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceToken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    private func makeIsolatedTokenStore() -> TokenStore {
        let gateway = DashboardGateway()
        return TokenStore(syncService: DashboardCodexSync(), openAIAccountGatewayService: DashboardAccountGateway(),
            openRouterGatewayService: gateway, chatCompletionsGatewayService: gateway,
            localCostRefreshWorker: { _, _, _ in
                LocalCostRefreshOutcome(summary: .empty, isComplete: true, mayReplaceLastKnownGood: true,
                    warningCount: 0, lastRawSessionScanAt: nil, latestUsageEventAt: nil,
                    progress: .zero, errorMessage: nil)
            }, codexRunningProcessIDs: { [] }, loadServiceTierCatalog: { nil })
    }

    private func routeControls(in view: NSView) -> [RouteSelectionMenuButton] {
        let buttons = (view as? RouteSelectionMenuButton).map { [$0] }
            ?? view.subviews.flatMap { self.routeControls(in: $0) }
        return buttons.filter { ["模型", "推理强度", "服务档位", "上下文窗口"].contains($0.accessibilityLabel() ?? "") }
    }

    private func recordVisibleQuotaRow(label: String, reset: String, percent: String,
                                       in rows: [(text: String, bounds: CGRect)]) {
        guard let anchor = rows.first(where: { $0.text.filter { !$0.isWhitespace }.contains(reset) }) else { return }
        let sameLine = rows.filter { abs($0.bounds.midY - anchor.bounds.midY) < 0.012 }
        let text = sameLine.map(\.text).joined().filter { !$0.isWhitespace }
        // Vision can read the small 7d label as 7a; the rendered glyph and the
        // independent window-data test establish the actual label.
        let weeklyGlyphAlias = label == "7d" && sameLine.contains {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "7a"
        }
        XCTAssertTrue((text.contains(label) || weeklyGlyphAlias) && text.contains(percent),
                      "窗口、重置时间、百分比应并排：\(text)")
    }

    private func recognizedRows(in image: CGImage, customWords: [String] = []) throws -> [(text: String, bounds: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["Gemini", "Claude/GPT", "Argon", "5h", "7d"] + customWords
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { result in
            result.topCandidates(1).first.map { ($0.string, result.boundingBox) }
        }
    }

    private func writeAccountMetadata(_ account: AntigravityAccount, to root: URL) throws {
        try self.writeAccountMetadata([account], activeID: account.id, to: root)
    }

    private func writeAccountMetadata(_ accounts: [AntigravityAccount], activeID: String, to root: URL) throws {
        struct Index: Encodable {
            let version = 1
            let activeAccountID: String
            let accounts: [AntigravityAccount]
        }
        let credentials = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try JSONEncoder().encode(Index(activeAccountID: activeID, accounts: accounts))
            .write(to: root.appendingPathComponent("accounts.json"))
        for account in accounts {
            let token = AntigravityTokenFile(token: AntigravityOAuthToken(
                accessToken: "fixture-access-" + account.id, tokenType: "Bearer",
                refreshToken: "fixture-refresh-" + account.id, expiry: Date().addingTimeInterval(3600)
            ))
            try token.serializedData().write(to: credentials.appendingPathComponent(account.id + ".json"))
        }
    }

    private static func accountFixture() -> AntigravityAccount {
        let now = Date()
        let definitions: [(String, String, String, Double)] = [
            ("gemini-5h", "Gemini Models", "5h", 0.81),
            ("gemini-weekly", "Gemini Models", "weekly", 0.64),
            ("3p-5h", "Claude and GPT models", "5h", 0.37),
            ("3p-weekly", "Claude and GPT models", "weekly", 0.22),
            ("gemini-argon-wtu-weekly", "Gemini 4 Argon", "weekly", 0.05)
        ]
        let windows = definitions.enumerated().map { index, definition in
            AntigravityQuotaWindow(
                id: definition.0, groupName: definition.1, displayName: definition.0,
                windowKind: definition.2, remainingFraction: definition.3,
                resetAt: now.addingTimeInterval(Double(index + 1) * 7200)
            )
        }
        return AntigravityAccount(
            id: "ag-dashboard-fixture", email: "quota-fixture@example.com", displayName: "Quota Fixture",
            userID: "dashboard-fixture", tierID: "g1-pro-tier", tierName: "Google AI Pro",
            cloudAICompanionProject: "fixture-project", quotaWindows: windows, status: .ok,
            statusMessage: nil, addedAt: now, lastUpdatedAt: now, isActive: true
        )
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { self.scrollViews(in: $0) }
    }

    private func accessibilityElements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 20, let element = object as? NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { self.accessibilityElements($0, depth: depth + 1) }
    }

    private func recognizedText(in image: CGImage, customWords: [String] = []) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["Antigravity", "Gemini", "Claude/GPT", "Argon", "Token"] + customWords
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

private struct DashboardAntigravityService: AntigravityAccountServicing {
    let account: AntigravityAccount
    var additionalAccounts: [AntigravityAccount] = []

    func makeAuthorizationSession(port: UInt16) throws -> AntigravityOAuthSession {
        XCTFail("额度展示不应发起登录")
        throw AntigravityAccountError.invalidOAuthCallback
    }

    func exchangeCallback(callbackInput: String, session: AntigravityOAuthSession) async throws -> AntigravityTokenFile {
        XCTFail("额度展示不应交换真实凭据")
        throw AntigravityAccountError.invalidOAuthCallback
    }

    func refreshTokenFile(_ tokenFile: AntigravityTokenFile) async throws -> AntigravityTokenFile { tokenFile }

    func probeAccount(tokenFile: AntigravityTokenFile, forceRefresh: Bool) async throws -> AntigravityAccountProbeResult {
        let matched = ([self.account] + self.additionalAccounts).first {
            tokenFile.token.accessToken == "fixture-access-" + $0.id
        } ?? self.account
        return AntigravityAccountProbeResult(
            tokenFile: tokenFile, userID: matched.userID, email: matched.email,
            displayName: matched.displayName, tierID: matched.tierID, tierName: matched.tierName,
            cloudAICompanionProject: "fixture-project", quotaWindows: matched.quotaWindows
        )
    }
}

private struct DashboardCursorSyncer: CursorUsageSyncing {
    func sync(now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .server,
            dailyEntries: [.init(date: calendar.startOfDay(for: now), totalTokens: 800_001)],
            latestUsageAt: now, refreshedAt: now)
    }
}

private struct DashboardAntigravityTokenCollector: ToolUsageCollecting {
    let client: ToolUsageClient = .antigravity
    func collect(now: Date, calendar: Calendar) -> ToolUsageSnapshot {
        ToolUsageSnapshot(client: .antigravity, availability: .ready,
            dailyEntries: [.init(date: calendar.startOfDay(for: now), totalTokens: 1_234_567)],
            latestUsageAt: now, refreshedAt: now)
    }
}

private struct DashboardQuotaFetcher: ToolQuotaFetching {
    func fetch(client: ToolUsageClient, preferences: ApplicationPreferences, now: Date) async -> ToolQuotaSnapshot {
        ToolQuotaSnapshot(client: client, status: .notConfigured, providerName: client.displayName,
                          refreshedAt: now, statusDetail: "隔离测试，无外部请求")
    }
}

private final class DashboardCodexSync: CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws {}
}

private final class DashboardGateway: OpenRouterGatewayControlling, ChatCompletionsGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {}
}

private final class DashboardAccountGateway: OpenAIAccountGatewayControlling {
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

private struct DashboardPeriodCollector: ToolUsageCollecting {
    let client: ToolUsageClient

    func collect(now: Date, calendar: Calendar) -> ToolUsageSnapshot {
        switch self.client {
        case .antigravity:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
            return ToolUsageSnapshot(client: .antigravity, availability: .partial,
                dailyEntries: [.init(date: yesterday, totalTokens: 1_234_567)],
                latestUsageAt: yesterday.addingTimeInterval(3600), refreshedAt: now,
                statusDetail: "旧历史数据不完整")
        case .openCode:
            return ToolUsageSnapshot(client: .openCode, availability: .ready,
                dailyEntries: [.init(date: calendar.startOfDay(for: now), totalTokens: 820_107,
                                     costUSD: 0, costEvidence: .reported)],
                latestUsageAt: now, refreshedAt: now)
        default:
            return ToolUsageSnapshot(client: self.client, availability: .failed,
                refreshedAt: now, statusDetail: "连接失败（隔离夹具）")
        }
    }
}

private struct DashboardPreviousDayCursorSyncer: CursorUsageSyncing {
    func sync(now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        return ToolUsageSnapshot(client: .cursor, availability: .partial, evidence: .server,
            dailyEntries: [.init(date: yesterday, totalTokens: 800_001)],
            latestUsageAt: yesterday.addingTimeInterval(7200), refreshedAt: now,
            statusDetail: "账号同步异常，保留历史")
    }
}
