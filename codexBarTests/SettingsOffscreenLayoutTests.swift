import AppKit
import SwiftUI
import Vision
import XCTest

/// Renders an unshown test window with an isolated empty account store; never captures the desktop.
@MainActor
final class SettingsOffscreenLayoutTests: CodexBarTestCase {
    func testSettingsCatalogRendersOffscreenWithoutHorizontalOverflow() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner, not the installed app.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["CODEXBAR_HOME"])
        let store = self.makeEmptyStore()
        let view = SettingsWindowView(store: store, updateCoordinator: UpdateCoordinator(), onClose: {})
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        XCTAssertFalse(window.isVisible)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try self.render(host: host, window: window, size: CGSize(width: 540, height: 900), to: output.appendingPathComponent("settings-catalog.png"))
        let elements = self.accessibilityElements(host)
        let labels = elements.compactMap { $0.accessibilityLabel() }
        try labels.joined(separator: "\n").write(to: output.appendingPathComponent("settings-labels.txt"), atomically: true, encoding: .utf8)
        for element in elements where element.accessibilityRole() == .button {
            XCTAssertLessThanOrEqual(element.accessibilityFrame().width, 541, "Settings button overflow: \(element.accessibilityLabel() ?? "")")
        }
        XCTAssertEqual(Set(SettingsPage.applicationPages), Set([.general, .main, .window, .appearance, .tools, .usage, .subscriptions, .sync]))
        XCTAssertFalse(SettingsPage.allCases.contains { $0.rawValue == "records" })
        try self.render(host: host, window: window, size: CGSize(width: 540, height: 720), to: output.appendingPathComponent("settings-default-window.png"))
        if let mainButton = elements.first(where: { $0.accessibilityRole() == .button && ($0.accessibilityLabel().map { $0.contains("主画面") || $0.contains("Main") } ?? false) }) {
            _ = mainButton.accessibilityPerformPress()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            try self.render(host: host, window: window, size: CGSize(width: 540, height: 900), to: output.appendingPathComponent("settings-main-expanded.png"))
        }
    }

    func testMenuPagesRenderOffscreenWithSingleSelectorAtBothLanguages() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let suiteName = "codexbar.layout-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update { $0.preferredMenuHeight = 640; $0.theme = .dark; $0.fontScale = 1; $0.collapsedManagementTools = [] }
        let originalLanguage = L.languageOverride
        defer { L.languageOverride = originalLanguage }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("fixture-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore()
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var viewportHeights: [Bool: CGFloat] = [:]
        for (name, page, identity, chinese) in [
            ("statistics-zh", MenuPage.home, ApplicationPreferences.AccountIdentityDisplay.email, true),
            ("limits-zh", .limits, .email, true),
            ("limits-name-zh", .limits, .name, true),
            ("statistics-en", .home, .email, false),
            ("limits-en", .limits, .email, false),
            ("limits-name-en", .limits, .name, false),
        ] {
            L.languageOverride = chinese
            preferences.update { $0.accountIdentityDisplay = identity }
            defaults.set(page.rawValue, forKey: "codexbar.menu.page")
            let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync, initialPage: page)
                .environmentObject(store)
                .environmentObject(OAuthManager())
                .environmentObject(UpdateCoordinator())
                .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try self.render(host: host, window: window, size: CGSize(width: 360, height: 640), to: output.appendingPathComponent(name + ".png"))
            let elements = self.accessibilityElements(window)
            let labels = elements.compactMap { $0.accessibilityLabel() }
            try labels.joined(separator: "\n").write(to: output.appendingPathComponent(name + "-labels.txt"), atomically: true, encoding: .utf8)
            let oldModeButtons = elements.filter {
                ["codexbar.workspace.dashboard", "codexbar.workspace.management"].contains($0.accessibilityIdentifier() ?? "")
            }
            XCTAssertTrue(oldModeButtons.isEmpty, "顶部只保留一个页面选择入口")
            let selector = try self.pageSelector(in: host)
            XCTAssertEqual(selector.title, page.title)
            XCTAssertEqual(selector.accessibilityLabel(), chinese ? "页面切换" : "Switch page")
            XCTAssertTrue(selector.image?.isTemplate == true, "当前页面应显示原有图标：\(name)")
            let selectorFrame = host.convert(selector.bounds, from: selector)
            XCTAssertEqual(selectorFrame.width, chinese ? 74 : 104, accuracy: 0.5, name)
            XCTAssertLessThanOrEqual(selector.intrinsicContentSize.width, selectorFrame.width + 0.5,
                                     "图标、标题和箭头应完整容纳，不互相挤占：\(name)")
            XCTAssertGreaterThanOrEqual(selectorFrame.minX, 0)
            XCTAssertLessThanOrEqual(selectorFrame.maxX, 360)
            for control in self.dropdownControls(in: host) {
                let frame = host.convert(control.bounds, from: control)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, name)
                XCTAssertLessThanOrEqual(frame.maxX, 360.5, name)
            }
            let secondRowIdentifier = "codexbar.header.metric-toggle"
            if let settings = elements.first(where: { $0.accessibilityIdentifier() == "codexbar.header.settings" }),
               let secondRow = elements.first(where: { $0.accessibilityIdentifier() == secondRowIdentifier }) {
                XCTAssertEqual(settings.accessibilityFrame().midX, secondRow.accessibilityFrame().midX, accuracy: 1)
            } else {
                try "Offscreen AX did not expose header controls; column alignment requires image review.\n"
                    .write(to: output.appendingPathComponent(name + "-ax-limitation.txt"), atomically: true, encoding: .utf8)
            }
            if page == .limits {
                let controls = self.routeControls(in: host).sorted {
                    host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX
                }
                XCTAssertEqual(controls.count, 4)
                XCTAssertEqual(controls.map(\.title), ["gpt-6.1-sol", "ultra", "standard", "272k"])
                try self.assertRouteControlsFillManagementRow(controls, in: host)
            }
            let scrollView = try XCTUnwrap(self.nativeScrollViews(in: host).first)
            XCTAssertGreaterThan(scrollView.frame.height, 100)
            XCTAssertLessThanOrEqual(scrollView.frame.width, 360)
            XCTAssertEqual(host.frame.height, 640, accuracy: 0.5)
            if let previousHeight = viewportHeights[chinese] {
                XCTAssertEqual(scrollView.frame.height, previousHeight, accuracy: 0.5,
                               "额度与统计使用相同的滚动视口，不保留底部导航占位")
            } else {
                viewportHeights[chinese] = scrollView.frame.height
            }
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(sync.isSyncing)
            XCTAssertNil(sync.listeningPort)
            XCTAssertFalse(tools.isRefreshing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testManagementRouteControlsFillWidthAfterSelectionChanges() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["CODEXBAR_HOME"])
        let suiteName = "codexbar.route-width-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update { $0.preferredMenuHeight = 640; $0.theme = .dark; $0.fontScale = 1; $0.collapsedManagementTools = [] }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("route-width-empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("route-width-fixture-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore()
        let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync, initialPage: .limits)
            .environmentObject(store)
            .environmentObject(OAuthManager())
            .environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // 复用同一个原生窗口，覆盖文本先变短、再变长以及再次回到原选择的布局更新。
        for (name, model, reasoning, tier, contextWindow, contextTitle) in [
            ("initial", "gpt-6.1-sol", "ultra", "standard", 272_000, "272k"),
            ("short", "gpt-5.5", "low", "fast", 1_000_000, "1M"),
            ("long", "gpt-5.6-terra", "ultra", "standard", 272_000, "272k"),
            ("reserve", ReserveModelPolicy.modelID, "low", "fast", 1_000_000, "1M"),
            ("restored", "gpt-6.1-sol", "ultra", "standard", 272_000, "272k"),
        ] {
            try store.updateRouteModel(model)
            try store.updateReasoningEffort(reasoning)
            try store.updateServiceTier(tier)
            try store.updateModelContextWindow(contextWindow, for: model)
            try self.render(host: host, window: window, size: CGSize(width: 360, height: 640),
                            to: output.appendingPathComponent("route-width-" + name + ".png"))
            let controls = self.routeControls(in: host).sorted {
                host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX
            }
            XCTAssertEqual(controls.map(\.title), [ReserveModelPolicy.displayName(for: model), reasoning, tier, contextTitle], name)
            try self.assertRouteControlsFillManagementRow(controls, in: host)
            XCTAssertEqual(store.activeModel, model)
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.listeningPort)
        XCTAssertFalse(tools.isRefreshing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testRouteSelectionAdaptersFillBothNativeScrollerViewports() throws {
        // A native container lets each fixture explicitly own its scroller style.
        // Do not force an internal SwiftUI ScrollView style: its layout proposal
        // is driven by system notifications, not a direct AppKit property mutation.
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, style) in [("overlay", NSScroller.Style.overlay), ("legacy", NSScroller.Style.legacy)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = false
            window.contentView = scroll
            scroll.scrollerStyle = style
            scroll.tile()
            let width = scroll.contentView.bounds.width
            let view = VStack {
                HStack(spacing: 4) {
                    ForEach(Array(zip(["gpt-6.1-sol", "low", "standard", "272k"],
                                      ["Model", "Reasoning effort", "Service tier", "Context window"])), id: \.0) { title, label in
                        RouteSelectionMenu(title: title, accessibilityLabel: label, items: [], compact: true, fillsAvailableWidth: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                Spacer()
            }.padding(.horizontal, 14).frame(width: width, height: 500)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 500)
            scroll.documentView = host
            defer { scroll.documentView = nil; window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(scroll.scrollerStyle, style)
            let controls = self.routeControls(in: host).sorted {
                host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX
            }
            try self.assertRouteControlsFillManagementRow(controls, in: host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("route-width-scroller-" + name + ".png"))
            XCTAssertFalse(window.isVisible)
        }
    }

    func testManagementIncludesUsageOverviewAccountQuotasAndAllToolConnections() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["CODEXBAR_HOME"])
        let suiteName = "codexbar.management-quota-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update {
            $0.preferredMenuHeight = 640
            $0.theme = .dark
            $0.fontScale = 1
            $0.collapsedManagementTools = []
            $0.hideAccountEmail = false
            $0.disabledTools = [ToolUsageClient.openCode.rawValue]
            $0.toolOrder = ["codex", "deepSeekHarness", "cursor", "openCode", "claudeCode"]
        }
        let tools = try self.makeManagementToolStore()
        self.settleUntil { tools.quotaSnapshots.count == ToolUsageClient.allCases.count }
        self.settleUntil { tools.snapshot(for: .deepSeekHarness).dailyEntries.count == 2 }
        XCTAssertEqual(tools.quotaSnapshots.count, ToolUsageClient.allCases.count)
        XCTAssertEqual(tools.snapshot(for: .deepSeekHarness).dailyEntries.count, 2)
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("management-quota-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore(includesAdditionalQuotaAccount: true)
        let originalAccountID = store.config.active.accountId
        let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync, initialPage: .limits)
            .environmentObject(store)
            .environmentObject(OAuthManager())
            .environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = CGSize(width: 360, height: 640)
        try self.render(host: host, window: window, size: size, to: output.appendingPathComponent("management-quota-top.png"))
        var limitations: [String] = []
        let initialElements = self.accessibilityElements(window)
        if initialElements.contains(where: { $0.accessibilityIdentifier() == "codexbar.usage.hero-value" }) {
            let hero = try XCTUnwrap(initialElements.first { $0.accessibilityIdentifier() == "codexbar.usage.hero-value" })
            XCTAssertGreaterThan(hero.accessibilityFrame().width, 0)
            XCTAssertLessThanOrEqual(hero.accessibilityFrame().width, 332)
        } else {
            limitations.append("Offscreen AX did not expose the usage overview; review management-quota-top.png.")
        }

        // 窗口内事件只投递自己的屏幕外测试窗口；真实渲染的数字验证事件确实生效。
        // AX 未暴露 SwiftUI 按钮时，使用固定 360pt 工具栏已验收的按钮中心。
        var interactionEvidence: [String] = []
        for period in [UsagePeriod.allTime, .today] {
            let point = NSPoint(x: period == .allTime ? 286 : 172, y: 75)
            if self.pressControl("codexbar.period.\(period.rawValue)", host: host, window: window, fallbackPointFromTop: point) {
                let expectedRange = period == .allTime
                    ? (L.zh ? "全部历史" : "All history")
                    : Date().formatted(.dateTime.month().day())
                let expectedTokens = period == .allTime ? "34567" : "12345"
                let hero = try self.waitForHero(expectedDigits: expectedTokens, host: host)
                XCTAssertEqual(hero.filter(\.isNumber), expectedTokens, "真实日期按钮应更新所选期间的合计")
                interactionEvidence.append("\(period.rawValue): rendered hero = \(hero)")
                let periodSummary = self.accessibilityElements(window).first {
                    $0.accessibilityIdentifier() == "codexbar.usage.period-summary"
                }
                if let periodSummary {
                    XCTAssertTrue(periodSummary.accessibilityLabel()?.contains(expectedRange) ?? false,
                                  "管理中的日期按钮应更新汇总展示期间")
                }
                try self.render(host: host, window: window, size: size,
                                to: output.appendingPathComponent("management-quota-\(period.rawValue).png"))
            } else {
                XCTFail("无法投递管理页日期按钮事件：\(period.rawValue)")
            }
        }
        if self.pressControl("codexbar.header.metric-toggle", host: host, window: window, fallbackPointFromTop: NSPoint(x: 330, y: 75)) {
            let costHero = try self.waitForHero(expectedDigits: "050", host: host)
            XCTAssertEqual(costHero.filter(\.isNumber), "050", "真实指标按钮应将今天的合计切换为费用")
            interactionEvidence.append("cost: rendered hero = \(costHero)")
            let expectedMetric = L.zh ? "费用" : "Cost"
            let metric = self.accessibilityElements(window).first {
                $0.accessibilityIdentifier() == "codexbar.header.metric-toggle"
            }
            if let metric {
                XCTAssertEqual(metric.accessibilityValue() as? String, expectedMetric)
            }
            try self.render(host: host, window: window, size: size, to: output.appendingPathComponent("management-quota-cost.png"))
            _ = self.pressControl("codexbar.header.metric-toggle", host: host, window: window, fallbackPointFromTop: NSPoint(x: 330, y: 75))
            XCTAssertEqual(try self.waitForHero(expectedDigits: "12345", host: host).filter(\.isNumber), "12345")
        } else {
            XCTFail("无法投递管理页指标按钮事件")
        }

        let scrollView = try XCTUnwrap(self.nativeScrollViews(in: host).first)
        let document = try XCTUnwrap(scrollView.documentView)
        XCTAssertGreaterThan(document.bounds.height, scrollView.contentView.bounds.height)
        var identifiers = Set<String>()
        var labels = Set<String>()
        let maximumOffset = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        let offsets = Array(stride(from: CGFloat.zero, to: maximumOffset, by: max(1, scrollView.contentView.bounds.height * 0.7))) + [maximumOffset]
        for offset in offsets {
            self.scroll(scrollView, to: offset)
            let elements = self.accessibilityElements(window)
            identifiers.formUnion(elements.compactMap { $0.accessibilityIdentifier() })
            labels.formUnion(elements.compactMap { $0.accessibilityLabel() })
        }
        try self.render(host: host, window: window, size: size, to: output.appendingPathComponent("management-quota-bottom.png"))
        if identifiers.contains(where: { $0.hasPrefix("codexbar.management.tool.") }) {
            for client in ToolUsageClient.allCases {
                XCTAssertTrue(identifiers.contains("codexbar.management.tool.\(client.rawValue)"), client.displayName)
                XCTAssertTrue(identifiers.contains("codexbar.management.\(client.rawValue).header"), client.displayName)
                XCTAssertTrue(identifiers.contains("codexbar.management.\(client.rawValue).actions"), client.displayName)
                XCTAssertTrue(identifiers.contains("codexbar.tool-quota.\(client.rawValue).usage"), client.displayName)
            }
        } else {
            limitations.append("Offscreen AX did not expose management cards; review top/bottom screenshots and ToolQuotaViewTests.")
        }
        if identifiers.contains(where: { $0.hasPrefix("codexbar.codex-quota.") }) {
            for account in store.accounts {
                let prefix = "codexbar.codex-quota.\(account.id)."
                XCTAssertTrue(identifiers.contains(prefix + "updated"), "每个账号应显示额度更新时间")
                XCTAssertTrue(identifiers.contains(prefix + "reset-cards"), "每个账号应显示重置卡")
                let quotaWindows = identifiers.filter { $0.hasPrefix(prefix + "window.") }
                XCTAssertEqual(quotaWindows.count, 3, "每个账号应同时显示 5h、7d 与 Reserve")
            }
        } else {
            limitations.append("Offscreen AX did not expose account quota details; review management-quota-top.png.")
        }
        XCTAssertEqual(preferences.preferences.disabledTools, [ToolUsageClient.openCode.rawValue], "呈现暂停的软件不应自动启用它")

        // 额度页的“查看用量”应通过同一页面状态进入工具详情。
        var didOpenUsage = false
        for offset in offsets {
            self.scroll(scrollView, to: offset)
            let point = try self.toolUsagePoint(client: .deepSeekHarness, in: host)
            if self.pressControl("codexbar.tool-quota.deepSeekHarness.usage", host: host, window: window, fallbackPointFromTop: point) {
                didOpenUsage = true
                break
            }
        }
        if didOpenUsage {
            self.settleUntil { defaults.string(forKey: "codexbar.menu.page") == "tools" }
            XCTAssertEqual(defaults.string(forKey: "codexbar.menu.page"), "tools")
            XCTAssertEqual(try self.pageSelector(in: host).title, MenuPage.tools.title)
            interactionEvidence.append("View usage: page=tools")
            try self.render(host: host, window: window, size: size, to: output.appendingPathComponent("management-quota-view-usage.png"))
            let detailIdentifiers = self.accessibilityElements(window).compactMap { $0.accessibilityIdentifier() }
            if detailIdentifiers.contains(where: { $0.hasPrefix("codexbar.tools.detail.") }) {
                XCTAssertTrue(detailIdentifiers.contains("codexbar.tools.detail.deepSeekHarness"))
            } else {
                limitations.append("Offscreen AX did not expose the selected tool detail after navigating; review management-quota-view-usage.png.")
            }
        } else {
            limitations.append("Offscreen AX/native hierarchy did not expose View usage; navigation was not exercised.")
        }
        try identifiers.sorted().joined(separator: "\n").write(to: output.appendingPathComponent("management-quota-identifiers.txt"), atomically: true, encoding: .utf8)
        try labels.sorted().joined(separator: "\n").write(to: output.appendingPathComponent("management-quota-labels.txt"), atomically: true, encoding: .utf8)
        try interactionEvidence.joined(separator: "\n").write(to: output.appendingPathComponent("management-quota-interaction-evidence.txt"), atomically: true, encoding: .utf8)
        if !limitations.isEmpty {
            try limitations.joined(separator: "\n").write(to: output.appendingPathComponent("management-quota-ax-limitation.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(store.config.active.accountId, originalAccountID)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.listeningPort)
        XCTAssertFalse(tools.isRefreshing)
        XCTAssertFalse(tools.isRefreshingQuotas)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testManagementSectionsFoldAndReorderThroughNativeWindowEvents() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["CODEXBAR_HOME"])
        let suiteName = "codexbar.management-sections-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        let initialOrder = ["codex", "deepSeekHarness", "cursor", "openCode", "claudeCode"]
        preferences.update {
            $0.preferredMenuHeight = 640
            $0.theme = .dark
            $0.fontScale = 1
            $0.toolOrder = initialOrder
            $0.disabledTools = ["openCode"]
        }
        XCTAssertEqual(preferences.preferences.collapsedManagementTools, ApplicationPreferences.allTools)
        let tools = try self.makeManagementToolStore()
        self.settleUntil { tools.quotaSnapshots.count == ToolUsageClient.allCases.count }
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("management-sections-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore()
        let originalAccountID = store.config.active.accountId
        let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync, initialPage: .limits)
            .environmentObject(store)
            .environmentObject(OAuthManager())
            .environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = CGSize(width: 360, height: 640)
        try self.render(host: host, window: window, size: size, to: output.appendingPathComponent("management-sections-default-collapsed.png"))
        let initialRoutes = self.routeControls(in: host).sorted {
            host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX
        }
        XCTAssertEqual(initialRoutes.map(\.title), ["gpt-6.1-sol", "ultra", "standard", "272k"],
                       "折叠 Codex 后仍须保留四项可编辑路线")
        try self.assertRouteControlsFillManagementRow(initialRoutes, in: host)
        let collapsedTexts = try self.recognizedTexts(in: host)
        try self.assertCollapsedCodexSummary(texts: collapsedTexts)
        XCTAssertTrue(collapsedTexts.contains {
            $0.text.contains("连接中转站") || $0.text.localizedCaseInsensitiveContains("Connect provider")
        }, "折叠 Codex 后仍须显示连接中转站入口")
        let codexHeader = try XCTUnwrap(self.managementHeaderPoint("codex", texts: collapsedTexts))
        XCTAssertTrue(self.pressControl("codexbar.management.codex.header", host: host, window: window, fallbackPointFromTop: codexHeader))
        self.settleUntil { self.routeControls(in: host).count == 4 }
        XCTAssertFalse(preferences.preferences.isManagementToolCollapsed("codex"))
        XCTAssertEqual(self.routeControls(in: host).count, 4, "展开只增加账号管理详情，不应复制路线控件")
        try self.render(host: host, window: window, size: size, to: output.appendingPathComponent("management-sections-expanded.png"))
        let expandedHeader = try XCTUnwrap(self.managementHeaderPoint("codex", texts: self.recognizedTexts(in: host)))
        XCTAssertTrue(self.pressControl("codexbar.management.codex.header", host: host, window: window, fallbackPointFromTop: expandedHeader))
        self.settleUntil { preferences.preferences.isManagementToolCollapsed("codex") }
        XCTAssertTrue(preferences.preferences.isManagementToolCollapsed("codex"))
        XCTAssertEqual(self.routeControls(in: host).count, 4, "收起后仍可调整当前账号路线")
        try self.assertCollapsedCodexSummary(texts: self.recognizedTexts(in: host))

        // 每个软件使用同一个标题折叠交互，不得再从标题创建账号管理窗口。
        let originalWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        for client in ToolUsageClient.allCases {
            preferences.update { $0.toolOrder = [client.rawValue] + initialOrder.filter { $0 != client.rawValue } }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            self.scroll(try XCTUnwrap(self.nativeScrollViews(in: host).first), to: 0)
            let header = try XCTUnwrap(self.managementHeaderPoint(client.rawValue, texts: self.recognizedTexts(in: host)))
            XCTAssertTrue(self.pressControl("codexbar.management.\(client.rawValue).header", host: host, window: window,
                                           fallbackPointFromTop: header), client.displayName)
            self.settleUntil { !preferences.preferences.isManagementToolCollapsed(client.rawValue) }
            XCTAssertFalse(preferences.preferences.isManagementToolCollapsed(client.rawValue), client.displayName)
            XCTAssertEqual(Set(NSApplication.shared.windows.map(ObjectIdentifier.init)), originalWindows,
                           "软件标题应在当前页面展开，不能新开账号窗口：\(client.displayName)")
            try self.render(host: host, window: window, size: size,
                            to: output.appendingPathComponent("management-sections-\(client.rawValue)-expanded.png"))
            let expandedTitle = try XCTUnwrap(self.managementHeaderPoint(client.rawValue, texts: self.recognizedTexts(in: host)))
            XCTAssertTrue(self.pressControl("codexbar.management.\(client.rawValue).header", host: host, window: window,
                                           fallbackPointFromTop: expandedTitle), client.displayName)
            self.settleUntil { preferences.preferences.isManagementToolCollapsed(client.rawValue) }
            XCTAssertTrue(preferences.preferences.isManagementToolCollapsed(client.rawValue), client.displayName)
            XCTAssertEqual(preferences.preferences.disabledTools, ["openCode"])
        }
        preferences.update { $0.toolOrder = initialOrder }

        // 重新创建偏好对象和整个界面，验证折叠选择确实来自持久化记录。
        let restoredPreferences = ApplicationPreferencesStore(defaults: defaults)
        XCTAssertEqual(restoredPreferences.preferences.collapsedManagementTools, ApplicationPreferences.allTools)
        let recreatedView = MenuBarView(toolUsageStore: tools, preferencesStore: restoredPreferences, deviceSync: sync, initialPage: .limits)
            .environmentObject(store)
            .environmentObject(OAuthManager())
            .environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults)
        let recreatedHost = NSHostingView(rootView: recreatedView)
        let recreatedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        recreatedWindow.isReleasedWhenClosed = false
        recreatedWindow.contentView = recreatedHost
        defer { recreatedWindow.contentView = nil; recreatedWindow.close() }
        try self.render(host: recreatedHost, window: recreatedWindow, size: size, to: output.appendingPathComponent("management-sections-restored-collapsed.png"))
        let restoredRoutes = self.routeControls(in: recreatedHost).sorted {
            recreatedHost.convert($0.bounds, from: $0).minX < recreatedHost.convert($1.bounds, from: $1).minX
        }
        XCTAssertEqual(restoredRoutes.count, 4)
        try self.assertRouteControlsFillManagementRow(restoredRoutes, in: recreatedHost)
        let restoredTexts = try self.recognizedTexts(in: recreatedHost)
        try self.assertCollapsedCodexSummary(texts: restoredTexts)
        XCTAssertTrue(restoredTexts.contains {
            $0.text.contains("连接中转站") || $0.text.localizedCaseInsensitiveContains("Connect provider")
        })
        let reorderText = try XCTUnwrap(restoredTexts.first {
            $0.text.contains("排序") || $0.text.localizedCaseInsensitiveContains("Reorder")
        })
        // Vision 会将 Label 的箭头和文字合并；中点可能落在两者间的空隙。
        // 取末尾文字内部，避免把事件投到 plain Button 的非命中区域。
        let reorderPoint = self.trailingTextPoint(reorderText)
        XCTAssertTrue(self.pressControl("codexbar.management.reorder", host: recreatedHost, window: recreatedWindow, fallbackPointFromTop: reorderPoint))
        _ = try XCTUnwrap(self.waitForRecognizedText(in: recreatedHost) {
            $0.text.contains("完成") || $0.text.localizedCaseInsensitiveContains("Done")
        }, "真实排序按钮点击后应先进入排序模式，才能点击行上的箭头")
        try self.render(host: recreatedHost, window: recreatedWindow, size: size, to: output.appendingPathComponent("management-sections-reordering.png"))
        let sortingTexts = try self.recognizedTexts(in: recreatedHost)
        XCTAssertEqual(self.managementHeaderOrder(texts: sortingTexts), initialOrder, "排序模式应展示所有五个软件，包含已暂停软件")
        var evidence = ["collapsed → expanded → collapsed route controls = 4; summary includes current account and remaining quota",
                        "restored collapse = all five software sections"]

        // 23pt 箭头按钮沿 14pt section 右边缘排列；Y 来自当前实际渲染的软件标题。
        for (direction, offset, expected) in [
            ("up", -1, ["codex", "cursor", "deepSeekHarness", "openCode", "claudeCode"]),
            ("down", 1, initialOrder),
        ] {
            let texts = try self.recognizedTexts(in: recreatedHost)
            let header = try XCTUnwrap(self.managementHeaderPoint("cursor", texts: texts))
            let x = recreatedHost.bounds.width - 14 - 11.5 - (offset < 0 ? 31 : 0)
            let arrow = NSPoint(x: x, y: header.y)
            XCTAssertTrue(self.pressControl("codexbar.management.reorder.\(direction).cursor", host: recreatedHost, window: recreatedWindow, fallbackPointFromTop: arrow))
            self.settleUntil { restoredPreferences.preferences.toolOrder == expected }
            XCTAssertEqual(restoredPreferences.preferences.toolOrder, expected, "原生排序按钮应更新共享软件顺序")
            XCTAssertEqual(ApplicationPreferencesStore(defaults: defaults).preferences.toolOrder, expected, "排序应写入隔离偏好存储")
            try self.render(host: recreatedHost, window: recreatedWindow, size: size, to: output.appendingPathComponent("management-sections-move-\(direction).png"))
            let observedOrder = self.managementHeaderOrder(texts: try self.recognizedTexts(in: recreatedHost))
            XCTAssertEqual(observedOrder, expected, "标题的实际渲染顺序应同步更新")
            evidence.append("cursor \(direction): " + observedOrder.joined(separator: ", "))
        }
        let doneText = try XCTUnwrap(self.recognizedTexts(in: recreatedHost).first {
            $0.text.contains("完成") || $0.text.localizedCaseInsensitiveContains("Done")
        })
        XCTAssertTrue(self.pressControl("codexbar.management.reorder", host: recreatedHost, window: recreatedWindow,
                                       fallbackPointFromTop: self.trailingTextPoint(doneText)))
        try self.render(host: recreatedHost, window: recreatedWindow, size: size, to: output.appendingPathComponent("management-sections-reordering-done.png"))
        XCTAssertEqual(self.routeControls(in: recreatedHost).count, 4)
        XCTAssertEqual(restoredPreferences.preferences.disabledTools, ["openCode"])
        try evidence.joined(separator: "\n").write(to: output.appendingPathComponent("management-sections-interaction-evidence.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.config.active.accountId, originalAccountID)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(recreatedWindow.isVisible)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.listeningPort)
        XCTAssertFalse(tools.isRefreshing)
        XCTAssertFalse(tools.isRefreshingQuotas)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testPageDefaultsToLimitsIgnoresLegacyWorkspaceAndRestoresSavedSelection() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["CODEXBAR_HOME"])
        let suiteName = "codexbar.page-restoration-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update { $0.preferredMenuHeight = 640; $0.collapsedManagementTools = [] }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("page-empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("page-fixture-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore()
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pageKey = "codexbar.menu.page"
        XCTAssertNil(defaults.object(forKey: pageKey))

        func assertRecreatedPage(_ page: MenuPage, named name: String) throws {
            let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync)
                .environmentObject(store)
                .environmentObject(OAuthManager())
                .environmentObject(UpdateCoordinator())
                .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try self.render(host: host, window: window, size: CGSize(width: 360, height: 640), to: output.appendingPathComponent(name + ".png"))
            let selector = try self.pageSelector(in: host)
            XCTAssertEqual(selector.title, page.title)
            XCTAssertEqual(selector.makeMenu().items.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }, [page.rawValue])
            XCTAssertEqual(self.routeControls(in: host).count, page == .limits ? 4 : 0)
        }

        try assertRecreatedPage(.limits, named: "page-first-launch-limits")
        defaults.set("dashboard", forKey: "codexbar.menu.workspace-mode")
        defaults.set("tools", forKey: "codexbar.menu.dashboard-page")
        try assertRecreatedPage(.limits, named: "page-legacy-workspace-default-limits")
        defaults.set(MenuPage.home.rawValue, forKey: pageKey)
        try assertRecreatedPage(.home, named: "page-restored-statistics")
        XCTAssertEqual(defaults.string(forKey: pageKey), MenuPage.home.rawValue,
                       "已保存的统计页应正常恢复，不能强制重置为额度")
        defaults.set(MenuPage.projects.rawValue, forKey: pageKey)
        try assertRecreatedPage(.projects, named: "page-restored-projects")
        XCTAssertEqual(defaults.string(forKey: pageKey), MenuPage.projects.rawValue,
                       "缺省额度页不能覆盖明确保存的新页面选择")
        defaults.set(MenuPage.limits.rawValue, forKey: pageKey)
        try assertRecreatedPage(.limits, named: "page-restored-limits")
        XCTAssertEqual(defaults.string(forKey: pageKey), MenuPage.limits.rawValue)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.listeningPort)
        XCTAssertFalse(tools.isRefreshing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testPageMenuReachesEveryPageInSameHostAndPersistsNativeSelection() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let suiteName = "codexbar.page-navigation-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyPageOrder = ["home", "limits", "tools", "models", "projects", "sessions", "devices", "trends"]
        defaults.set(try JSONSerialization.data(withJSONObject: ["pageOrder": legacyPageOrder]),
                     forKey: ApplicationPreferencesStore.defaultsKey)
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update { $0.preferredMenuHeight = 640; $0.collapsedManagementTools = [] }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("navigation-empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("navigation-fixture-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore()
        let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync)
            .environmentObject(store)
            .environmentObject(OAuthManager())
            .environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = CGSize(width: 360, height: 640)
        try self.render(host: host, window: window, size: size, to: output.appendingPathComponent("page-menu-default-limits.png"))
        let initialSelector = try self.pageSelector(in: host)
        XCTAssertEqual(initialSelector.title, MenuPage.limits.title)
        let selectorWidth = L.zh ? CGFloat(74) : 104
        XCTAssertEqual(initialSelector.bounds.width, selectorWidth, accuracy: 0.5)
        XCTAssertNotNil(initialSelector.image)
        let expectedIDs = ["limits", "home", "tools", "models", "projects", "sessions", "devices", "trends"]
        let pageMenu = initialSelector.makeMenu()
        XCTAssertEqual(pageMenu.items.compactMap { $0.identifier?.rawValue }, expectedIDs)
        XCTAssertEqual(pageMenu.items.map(\.title), MenuPage.allCases.map(\.title))
        XCTAssertEqual(pageMenu.items.count, 8)
        XCTAssertTrue(pageMenu.showsStateColumn)
        var pageIcons = Set<Data>()
        for item in pageMenu.items {
            XCTAssertNil(item.image, "普通菜单图标可能被系统隐藏，应使用状态列：\(item.title)")
            XCTAssertTrue(item.offStateImage?.isTemplate == true, "未选中页在状态列保留自己的图标：\(item.title)")
            XCTAssertNotNil(item.onStateImage, "选中页面保留系统勾选标识：\(item.title)")
            let image = try XCTUnwrap(item.offStateImage)
            XCTAssertEqual(image.size.width, 14, accuracy: 0.5)
            XCTAssertEqual(image.size.height, 14, accuracy: 0.5)
            pageIcons.insert(try XCTUnwrap(image.tiffRepresentation))
        }
        XCTAssertEqual(pageIcons.count, 8, "八个页面应各自保留原有图标，不能复用同一个图标")
        let viewportHeight = try XCTUnwrap(self.nativeScrollViews(in: host).first).frame.height
        let originalWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        for page in [MenuPage.home, .tools, .models, .projects, .sessions, .devices, .trends, .limits] {
            let selector = try self.pageSelector(in: host)
            var didSelect = false
            selector.menuPresenter = { menu, _, _ in
                guard let item = menu.items.first(where: { $0.identifier?.rawValue == page.rawValue }),
                      let action = item.action else {
                    XCTFail("页面菜单缺少 \(page.rawValue)")
                    return
                }
                XCTAssertTrue(RouteSelectionMenuTracking.isActive)
                didSelect = NSApplication.shared.sendAction(action, to: item.target, from: item)
            }
            selector.performClick(nil)
            selector.menuPresenter = nil
            XCTAssertTrue(didSelect, page.rawValue)
            self.settleUntil { defaults.string(forKey: "codexbar.menu.page") == page.rawValue }
            try self.render(host: host, window: window, size: size, to: output.appendingPathComponent("page-menu-\(page.rawValue).png"))
            let selected = try self.pageSelector(in: host)
            XCTAssertEqual(selected.title, page.title, page.rawValue)
            XCTAssertTrue(selected.image?.isTemplate == true, "页面切换后恢复对应图标：\(page.rawValue)")
            XCTAssertEqual(selected.bounds.width, selectorWidth, accuracy: 0.5, "切换页面不能改变下拉框宽度")
            XCTAssertLessThanOrEqual(selected.intrinsicContentSize.width, selected.bounds.width + 0.5,
                                     "图标、标题和箭头应完整容纳：\(page.rawValue)")
            XCTAssertEqual(defaults.string(forKey: "codexbar.menu.page"), page.rawValue)
            let selectedPageMenu = selected.makeMenu()
            XCTAssertTrue(selectedPageMenu.showsStateColumn)
            XCTAssertEqual(selectedPageMenu.items.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }, [page.rawValue])
            for item in selectedPageMenu.items {
                XCTAssertEqual(item.state, item.identifier?.rawValue == page.rawValue ? .on : .off)
                XCTAssertNil(item.image)
                XCTAssertTrue(item.offStateImage?.isTemplate == true, "切换后其他页面应继续保留状态列图标：\(item.title)")
                XCTAssertNotNil(item.onStateImage, "切换后选中页面应继续保留系统勾：\(item.title)")
            }
            XCTAssertEqual(self.routeControls(in: host).count, page == .limits ? 4 : 0)
            XCTAssertEqual(try XCTUnwrap(self.nativeScrollViews(in: host).first).frame.height, viewportHeight, accuracy: 0.5)
            XCTAssertEqual(Set(NSApplication.shared.windows.map(ObjectIdentifier.init)), originalWindows,
                           "切换页面应复用当前菜单窗口")
            XCTAssertFalse(RouteSelectionMenuTracking.isActive)
        }
        XCTAssertNil(defaults.object(forKey: "codexbar.menu.workspace-mode"))
        XCTAssertNil(defaults.object(forKey: "codexbar.menu.dashboard-page"))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.listeningPort)
        XCTAssertFalse(tools.isRefreshing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testReserveModelMenuRequiresAvailableQuotaOnCurrentAccount() throws {
        try self.assertReserveManagementLayout(currentReserveUsedPercent: 40, expectsReserveOption: true, name: "reserve-available")
        try self.assertReserveManagementLayout(currentReserveUsedPercent: nil, expectsReserveOption: false, name: "reserve-absent")
        try self.assertReserveManagementLayout(currentReserveUsedPercent: 100, expectsReserveOption: false, name: "reserve-exhausted")
    }

    func testSelectedReserveModelRendersNormalEditableRouteControls() throws {
        try self.assertReserveManagementLayout(
            currentReserveUsedPercent: 40,
            selectedModel: ReserveModelPolicy.modelID,
            expectsReserveOption: true,
            name: "reserve-selected"
        )
    }

    private func assertReserveManagementLayout(
        currentReserveUsedPercent: Double?,
        selectedModel: String = "gpt-6.1-sol",
        expectsReserveOption: Bool,
        name: String
    ) throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["CODEXBAR_HOME"])
        var alpha = try self.makeOAuthAccount(accountID: "fixture-alpha", email: "alpha@example.com", isActive: true)
        alpha.displayName = "Alpha"
        alpha.lunaReserveUsedPercent = currentReserveUsedPercent
        alpha.lunaReserveResetAt = Date(timeIntervalSinceNow: 86_400)
        alpha.lunaReserveLimitWindowSeconds = 604_800
        alpha.lastChecked = Date()
        // 另一个账号始终有额度；它不能让当前账号的菜单获得 Reserve 选项。
        var beta = try self.makeOAuthAccount(accountID: "fixture-beta", email: "beta@example.com")
        beta.displayName = "Beta"
        beta.lunaReserveUsedPercent = 15
        beta.lastChecked = Date()
        let provider = CodexBarProvider(
            id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI",
            activeAccountId: alpha.accountId,
            accounts: [alpha, beta].map { CodexBarProviderAccount.fromTokenAccount($0, existingID: $0.accountId) }
        )
        try self.writeConfig(CodexBarConfig(
            global: CodexBarGlobalSettings(defaultModel: selectedModel, reasoningEffort: "ultra"),
            active: CodexBarActiveSelection(providerId: provider.id, accountId: alpha.accountId),
            providers: [provider]
        ))
        let store = self.makeEmptyStore()
        XCTAssertEqual(store.config.active.accountId, alpha.accountId)
        XCTAssertEqual(store.activeModel, selectedModel)

        let suiteName = "codexbar.reserve-layout-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update {
            $0.preferredMenuHeight = 760
            $0.theme = .dark
            $0.fontScale = 1
            $0.hideAccountEmail = false
            $0.collapsedManagementTools = []
        }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("reserve-empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("reserve-fixture-device-sync"), startConfiguredMode: false)
        let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync, initialPage: .limits)
            .environmentObject(store)
            .environmentObject(OAuthManager())
            .environmentObject(UpdateCoordinator())
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try self.render(host: host, window: window, size: CGSize(width: 360, height: 760), to: output.appendingPathComponent(name + ".png"))

        let controls = self.routeControls(in: host).sorted {
            host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX
        }
        XCTAssertEqual(controls.count, 4, "Reserve 应通过普通模型菜单选择，保留四个可编辑下拉框")
        let modelControl = try XCTUnwrap(controls.first)
        XCTAssertEqual(modelControl.title, ReserveModelPolicy.displayName(for: selectedModel))
        let menu = modelControl.makeMenu()
        let reserveItems = menu.items.filter { $0.identifier?.rawValue == ReserveModelPolicy.modelID }
        XCTAssertEqual(reserveItems.count, expectsReserveOption ? 1 : 0)
        if let reserveItem = reserveItems.first {
            XCTAssertEqual(reserveItem.title, "GPT Reserve")
            XCTAssertEqual(reserveItem.state, ReserveModelPolicy.isReserve(selectedModel) ? .on : .off)
        }
        if ReserveModelPolicy.isReserve(selectedModel) {
            let reasoningControl = try XCTUnwrap(controls.dropFirst().first)
            XCTAssertTrue(CodexBarGlobalSettings.supportsReasoningEffort(reasoningControl.title, for: selectedModel))
            XCTAssertNotEqual(reasoningControl.title, "ultra")
        }
        try self.assertRouteControlsFillManagementRow(controls, in: host)
        let texts = self.accessibilityElements(window).flatMap { element in
            [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }
        }
        XCTAssertFalse(texts.contains {
            $0.contains("强制 Reserve") || $0.contains("Force Reserve") || $0.contains("取消强制") || $0.contains("Stop forcing Reserve")
        })
        try texts.joined(separator: "\n").write(to: output.appendingPathComponent(name + "-labels.txt"), atomically: true, encoding: .utf8)
        // 仅呈现菜单不会替用户切换账号或模型，也不会同步真实认证文件。
        XCTAssertEqual(store.config.active.accountId, alpha.accountId)
        XCTAssertEqual(store.activeModel, selectedModel)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.listeningPort)
        XCTAssertFalse(tools.isRefreshing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testUnifiedDropdownFieldsFitNarrowSettingsColumn() throws {
        let view = VStack(spacing: 16) {
            SettingsSelectionField("界面语言", selection: .constant("zh"), options: [("system", "跟随系统"), ("zh", "简体中文")])
            SettingsSelectionField("额度刷新频率", selection: .constant(60), options: [(30, "30 秒"), (60, "1 分钟")])
            SettingsSelectionField("账户", selection: .constant("fixture"), options: [("fixture", "一个很长的账户名称用于验证控件不会超出设置窗口")], showsLabel: false)
        }
        .padding(16)
        .frame(width: 360, height: 180)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func controls(in view: NSView) -> [RouteSelectionMenuButton] {
            (view as? RouteSelectionMenuButton).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        let buttons = controls(in: host)
        XCTAssertEqual(buttons.count, 3)
        for button in buttons {
            let frame = host.convert(button.bounds, from: button)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, 360)
            XCTAssertEqual(button.font?.pointSize, 12)
        }
        XCTAssertFalse(window.isVisible)
    }

    private func makeManagementStore(includesAdditionalQuotaAccount: Bool = false) throws -> TokenStore {
        var account = try self.makeOAuthAccount(accountID: "fixture-layout", email: "manage@example.com", isActive: true, planType: "pro")
        account.displayName = "布局验证"
        account.primaryUsedPercent = 35
        account.primaryResetAt = Date(timeIntervalSinceNow: 86_400)
        account.lunaReserveUsedPercent = 0
        account.lunaReserveResetAt = Date(timeIntervalSinceNow: 604_800)
        account.lunaReserveLimitWindowSeconds = 604_800
        account.lastChecked = Date()
        var accounts = [account]
        if includesAdditionalQuotaAccount {
            account.primaryLimitWindowSeconds = 18_000
            account.primaryResetAt = Date(timeIntervalSinceNow: 18_000)
            account.secondaryUsedPercent = 52
            account.secondaryLimitWindowSeconds = 604_800
            account.secondaryResetAt = Date(timeIntervalSinceNow: 604_800)
            account.rateLimitResetAvailableCount = 1
            var secondary = try self.makeOAuthAccount(accountID: "fixture-layout-secondary", email: "secondary@example.com", planType: "plus")
            secondary.displayName = "第二个布局账号"
            secondary.primaryUsedPercent = 78
            secondary.primaryLimitWindowSeconds = 18_000
            secondary.primaryResetAt = Date(timeIntervalSinceNow: 12_000)
            secondary.secondaryUsedPercent = 24
            secondary.secondaryLimitWindowSeconds = 604_800
            secondary.secondaryResetAt = Date(timeIntervalSinceNow: 500_000)
            secondary.lunaReserveUsedPercent = 40
            secondary.lunaReserveLimitWindowSeconds = 604_800
            secondary.lunaReserveResetAt = Date(timeIntervalSinceNow: 500_000)
            secondary.rateLimitResetAvailableCount = 2
            secondary.lastChecked = Date(timeIntervalSinceNow: -60)
            accounts = [account, secondary]
        }
        let provider = CodexBarProvider(
            id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: account.accountId,
            accounts: accounts.map { CodexBarProviderAccount.fromTokenAccount($0, existingID: $0.accountId) }
        )
        try self.writeConfig(CodexBarConfig(
            global: CodexBarGlobalSettings(defaultModel: "gpt-6.1-sol", reasoningEffort: "ultra", modelContextWindows: ["gpt-6.1-sol": 272_000]),
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.accountId), providers: [provider]
        ))
        return self.makeEmptyStore()
    }

    private func makeManagementToolStore() throws -> ToolUsageStore {
        let folder = CodexPaths.realHome.appendingPathComponent("management-quota-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let reset = now.addingTimeInterval(604_800)
        let quotas = [
            ToolQuotaSnapshot(client: .claudeCode, status: .notConfigured, providerName: "Claude Code",
                statusDetail: "未读取到 Claude Code OAuth 登录，请在 Claude Code 登录"),
            ToolQuotaSnapshot(client: .openCode, status: .unsupported, providerName: "OpenCode Go",
                refreshedAt: now, statusDetail: "接入服务未提供统一额度接口"),
            ToolQuotaSnapshot(client: .cursor, status: .ready, providerName: "Cursor",
                windows: [ToolQuotaWindow(id: "cursor", label: "Cursor 模型", usedPercent: 44, resetsAt: reset),
                          ToolQuotaWindow(id: "other", label: "其他模型", usedPercent: 71, resetsAt: reset)],
                refreshedAt: now, statusDetail: "账户服务端额度"),
            ToolQuotaSnapshot(client: .deepSeekHarness, status: .ready, providerName: "DeepSeek API",
                balance: ToolQuotaBalance(amount: 223.26, currency: "CNY"),
                refreshedAt: now, statusDetail: "余额快照；按量付费，不提供订阅百分比")
        ]
        try JSONEncoder().encode(quotas).write(to: folder.appendingPathComponent("tool-quota-summary.json"), options: .atomic)
        let cacheURL = folder.appendingPathComponent("tool-usage-summary.json")
        let today = Calendar.current.startOfDay(for: now)
        let older = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -45, to: today))
        let usage = ToolUsageSnapshot(client: .deepSeekHarness, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: older, totalTokens: 22_222, costUSD: 1),
                           ToolUsageDailyEntry(date: today, totalTokens: 12_345, costUSD: 0.5)],
            latestUsageAt: now, refreshedAt: now)
        try JSONEncoder().encode([usage]).write(to: cacheURL, options: .atomic)
        // 不配置真实采集器、登录同步器或额度刷新动作；仅呈现隔离目录中的缓存。
        return ToolUsageStore(collectors: [], cacheURL: cacheURL)
    }

    private func nativeScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { self.nativeScrollViews(in: $0) }
    }

    private func scroll(_ scrollView: NSScrollView, to offset: CGFloat) {
        guard let document = scrollView.documentView else { return }
        let maximumOffset = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        let clamped = min(max(0, offset), maximumOffset)
        let origin = document.isFlipped ? clamped : maximumOffset - clamped
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func pressControl(_ identifier: String, host: NSView, window: NSWindow,
                              fallbackPointFromTop: NSPoint? = nil) -> Bool {
        if let element = self.accessibilityElements(window).first(where: { $0.accessibilityIdentifier() == identifier }) {
            XCTAssertTrue(element.isAccessibilityEnabled(), "控件应可用：\(identifier)")
            if element.accessibilityPerformPress() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                return true
            }
        }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        if let button = buttons(in: host).first(where: {
            $0.accessibilityIdentifier() == identifier || $0.identifier?.rawValue == identifier
        }) {
            XCTAssertTrue(button.isEnabled, "原生控件应可用：\(identifier)")
            button.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return true
        }
        guard let point = fallbackPointFromTop else { return false }
        XCTAssertFalse(window.isVisible, "只允许操作自己未显示的 fixture 窗口")
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let location = NSPoint(x: point.x, y: host.bounds.height - point.y)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0) else { return false }
        // SwiftUI 按钮可能同步跟踪 mouseUp；先入自身应用队列，避免跟踪阻塞。
        NSApplication.shared.postEvent(up, atStart: true)
        window.sendEvent(down)
        window.sendEvent(up)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return true
    }

    private func waitForHero(expectedDigits: String, host: NSView) throws -> String {
        let deadline = Date().addingTimeInterval(4)
        var hero = ""
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let texts = try self.recognizedTexts(in: host, topRange: 108...150)
            hero = texts.max(by: { $0.bounds.height < $1.bounds.height })?.text ?? ""
            if hero.filter(\.isNumber) == expectedDigits { return hero }
        } while Date() < deadline
        return hero
    }

    private func toolUsagePoint(client: ToolUsageClient, in host: NSView) throws -> NSPoint? {
        let texts = try self.recognizedTexts(in: host)
        guard let title = texts.first(where: { $0.text.contains(client.displayName) }) else { return nil }
        let lowerTitle = texts.filter { text in
            ToolUsageClient.allCases.contains(where: { $0.displayName != client.displayName && text.text.contains($0.displayName) })
        }
        let nextTitleY = lowerTitle.map(\.bounds.midY).filter { $0 > title.bounds.midY }.min() ?? host.bounds.height
        guard let usage = texts.first(where: {
            ($0.text.contains("查看用量") || $0.text.localizedCaseInsensitiveContains("View usage"))
                && $0.bounds.midY > title.bounds.midY && $0.bounds.midY < nextTitleY
        }), usage.bounds.maxY < host.bounds.height - 24 else { return nil }
        return NSPoint(x: usage.bounds.midX, y: usage.bounds.midY)
    }

    private func managementHeaderPoint(_ key: String, texts: [(text: String, bounds: CGRect)]) -> NSPoint? {
        guard let title = texts.filter({ self.managementHeaderKey($0) == key })
            .min(by: { $0.bounds.midY < $1.bounds.midY }) else { return nil }
        return NSPoint(x: title.bounds.midX, y: title.bounds.midY)
    }

    private func assertCollapsedCodexSummary(
        texts: [(text: String, bounds: CGRect)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let text = texts.map(\.text).joined(separator: "\n")
        let identityIsVisible = texts.contains {
            // Vision 实测仅把该邮箱的 @ 识别为 l/1；只接受同一行这一处已知字形误读。
            $0.text.contains("manage@example.com") || $0.text.contains("managelexample.com")
                || $0.text.contains("manage1example.com")
        }
        XCTAssertTrue(identityIsVisible,
                      "Codex 折叠后应显示当前账号身份：\(text)", file: file, line: line)
        XCTAssertTrue(text.contains("65%"), "Codex 折叠后应显示当前账号剩余额度：\(text)", file: file, line: line)
    }

    private func managementHeaderOrder(texts: [(text: String, bounds: CGRect)]) -> [String] {
        texts.sorted { $0.bounds.midY < $1.bounds.midY }.compactMap(self.managementHeaderKey)
    }

    private func managementHeaderKey(_ text: (text: String, bounds: CGRect)) -> String? {
        guard text.bounds.midY > 190, text.bounds.minX < 180 else { return nil }
        func words(_ title: String) -> [String] {
            title.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.filter(\.isLetter).lowercased() }.filter { !$0.isEmpty }
        }
        let observed = words(text.text)
        // OCR 可能将左侧图标识成独立前缀（实测 "i- CurSOr"）；
        // 软件名须仍是完整尾部词组，"Cursor 模型" 不会被识成软件标题。
        let titles = [("codex", "Codex")] + ToolUsageClient.allCases.map { ($0.rawValue, $0.displayName) }
        return titles.first { _, title in
            let expected = words(title)
            return Array(observed.suffix(expected.count)) == expected
        }?.0
    }

    private func trailingTextPoint(_ text: (text: String, bounds: CGRect)) -> NSPoint {
        NSPoint(x: text.bounds.maxX - min(8, text.bounds.width / 4), y: text.bounds.midY)
    }

    private func waitForRecognizedText(in host: NSView, timeout: TimeInterval = 3,
                                      matches: ((text: String, bounds: CGRect)) -> Bool) throws -> (text: String, bounds: CGRect)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if let text = try self.recognizedTexts(in: host).first(where: matches) { return text }
        } while Date() < deadline
        return nil
    }

    private func recognizedTexts(in host: NSView, topRange: ClosedRange<CGFloat>? = nil) throws -> [(text: String, bounds: CGRect)] {
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["Cursor", "manage@example.com"]
        request.usesLanguageCorrection = false
        if let topRange {
            request.regionOfInterest = CGRect(x: 0, y: 1 - topRange.upperBound / host.bounds.height,
                                             width: 1, height: (topRange.upperBound - topRange.lowerBound) / host.bounds.height)
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { result in
            guard let text = result.topCandidates(1).first?.string else { return nil }
            let bounds = result.boundingBox
            return (text, CGRect(x: bounds.minX * host.bounds.width,
                                 y: (1 - bounds.maxY) * host.bounds.height,
                                 width: bounds.width * host.bounds.width,
                                 height: bounds.height * host.bounds.height))
        }
    }

    private func settleUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func dropdownControls(in view: NSView) -> [RouteSelectionMenuButton] {
        (view as? RouteSelectionMenuButton).map { [$0] } ?? view.subviews.flatMap { self.dropdownControls(in: $0) }
    }

    private func pageSelector(in view: NSView, file: StaticString = #filePath, line: UInt = #line) throws -> RouteSelectionMenuButton {
        let selectors = self.dropdownControls(in: view).filter {
            ["页面切换", "Switch page"].contains($0.accessibilityLabel() ?? "")
        }
        XCTAssertEqual(selectors.count, 1, "页面切换只能有一个原生下拉框", file: file, line: line)
        return try XCTUnwrap(selectors.first, file: file, line: line)
    }

    private func routeControls(in view: NSView) -> [RouteSelectionMenuButton] {
        let routeLabels = ["模型", "Model", "推理强度", "Reasoning effort", "服务档位", "Service tier", "上下文窗口", "Context window"]
        return self.dropdownControls(in: view).filter { routeLabels.contains($0.accessibilityLabel() ?? "") }
    }

    private func scrollAncestor(of view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? NSScrollView { return scroll }
            ancestor = current.superview
        }
        return nil
    }

    private func assertRouteControlsFillManagementRow(
        _ controls: [RouteSelectionMenuButton],
        in host: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(controls.count, 4, file: file, line: line)
        let frames = controls.map { host.convert($0.bounds, from: $0) }
        let firstFrame = try XCTUnwrap(frames.first, file: file, line: line)
        let lastFrame = try XCTUnwrap(frames.last, file: file, line: line)
        let scrollView = try XCTUnwrap(self.scrollAncestor(of: XCTUnwrap(controls.first)), file: file, line: line)
        let viewport = host.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let document = try XCTUnwrap(scrollView.documentView, file: file, line: line)
        let documentFrame = host.convert(document.bounds, from: document)
        let rowMinX = viewport.minX + 14
        let rowMaxX = viewport.maxX - 14
        XCTAssertGreaterThan(viewport.width, 0, file: file, line: line)
        XCTAssertEqual(documentFrame.width, viewport.width, accuracy: 0.5, "垂直内容应与实际视口等宽", file: file, line: line)
        let geometry = "scrollerStyle=\(scrollView.scrollerStyle.rawValue), viewport=\(viewport), document=\(documentFrame), first=\(firstFrame), last=\(lastFrame)"
        XCTContext.runActivity(named: "路由填满实际滚动内容区域") { activity in
            let attachment = XCTAttachment(string: geometry)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        XCTAssertEqual(firstFrame.minX, rowMinX, accuracy: 0.5, "下拉框应从软件 section 内容左边缘开始", file: file, line: line)
        XCTAssertEqual(lastFrame.maxX, rowMaxX, accuracy: 0.5, "最后一个下拉框应填满软件 section 内容右边缘", file: file, line: line)
        var previousFrame: NSRect?
        for (control, frame) in zip(controls, frames) {
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, rowMinX, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, rowMaxX, file: file, line: line)
            XCTAssertEqual(frame.midY, firstFrame.midY, accuracy: 0.5, "四个下拉框应位于同一行", file: file, line: line)
            if let previousFrame {
                XCTAssertGreaterThanOrEqual(frame.minX, previousFrame.maxX, "相邻下拉框不能重叠", file: file, line: line)
                XCTAssertEqual(frame.minX - previousFrame.maxX, 4, accuracy: 0.5, "下拉框之间应保持紧凑间隔", file: file, line: line)
            }
            previousFrame = frame
            XCTAssertEqual(control.font?.pointSize, 10, file: file, line: line)
            XCTAssertEqual(frame.height, 24, accuracy: 0.5, file: file, line: line)
        }
    }

    private func makeEmptyStore() -> TokenStore {
        let gateway = OffscreenProviderGateway()
        return TokenStore(
            syncService: OffscreenCodexSync(),
            openAIAccountGatewayService: OffscreenAccountGateway(),
            openRouterGatewayService: gateway,
            chatCompletionsGatewayService: gateway,
            localCostRefreshWorker: { _, _, _ in
                LocalCostRefreshOutcome(summary: .empty, isComplete: true, mayReplaceLastKnownGood: true,
                    warningCount: 0, lastRawSessionScanAt: nil, latestUsageEventAt: nil, progress: .zero, errorMessage: nil)
            },
            codexRunningProcessIDs: { [] },
            loadServiceTierCatalog: { nil }
        )
    }

    private func render(host: NSView, window: NSWindow, size: CGSize, to url: URL) throws {
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: url, options: .atomic)
        XCTAssertEqual(host.bounds.width, size.width, accuracy: 0.5)
        XCTAssertFalse(window.isVisible)
    }

    private func accessibilityElements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 20, let element = object as? NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { self.accessibilityElements($0, depth: depth + 1) }
    }
}

private final class OffscreenCodexSync: CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws {}
}

private final class OffscreenProviderGateway: OpenRouterGatewayControlling, ChatCompletionsGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {}
}

private final class OffscreenAccountGateway: OpenAIAccountGatewayControlling {
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
