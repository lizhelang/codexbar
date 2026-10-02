import AppKit
import SwiftUI
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

    func testMenuDashboardAndManagementRenderOffscreenWithMergedToolbar() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let suiteName = "codexbar.layout-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update { $0.preferredMenuHeight = 640; $0.theme = .dark; $0.fontScale = 1 }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("fixture-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore()
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var dashboardModeFrames: [String: NSRect] = [:]
        for (name, management, identity) in [
            ("dashboard", false, ApplicationPreferences.AccountIdentityDisplay.email),
            ("management", true, .email),
            ("management-name", true, .name),
        ] {
            preferences.update { $0.accountIdentityDisplay = identity }
            defaults.set(management ? "management" : "dashboard", forKey: "codexbar.menu.workspace-mode")
            let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync, startsInManagement: management)
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
            let modeButtons = elements.filter {
                ["codexbar.workspace.dashboard", "codexbar.workspace.management"].contains($0.accessibilityIdentifier() ?? "")
            }
            if modeButtons.count == 2 {
                XCTAssertEqual(modeButtons[0].accessibilityFrame().midY, modeButtons[1].accessibilityFrame().midY, accuracy: 1)
                for button in modeButtons {
                    XCTAssertLessThanOrEqual(button.accessibilityFrame().width, 180)
                    if let identifier = button.accessibilityIdentifier() {
                        if management, let previous = dashboardModeFrames[identifier] {
                            XCTAssertEqual(button.accessibilityFrame().minX, previous.minX, accuracy: 1, identifier)
                        } else if !management {
                            dashboardModeFrames[identifier] = button.accessibilityFrame()
                        }
                    }
                }
            }
            let secondRowIdentifier = management
                ? OpenAIAccountCSVToolbarUI.accessibilityIdentifier : "codexbar.header.metric-toggle"
            if let settings = elements.first(where: { $0.accessibilityIdentifier() == "codexbar.header.settings" }),
               let secondRow = elements.first(where: { $0.accessibilityIdentifier() == secondRowIdentifier }) {
                XCTAssertEqual(settings.accessibilityFrame().midX, secondRow.accessibilityFrame().midX, accuracy: 1)
            } else {
                try "Offscreen AX did not expose header controls; column alignment requires image review.\n"
                    .write(to: output.appendingPathComponent(name + "-ax-limitation.txt"), atomically: true, encoding: .utf8)
            }
            if management {
                let controls = self.routeControls(in: host).sorted {
                    host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX
                }
                XCTAssertEqual(controls.count, 4)
                XCTAssertEqual(controls.map(\.title), ["gpt-6.1-sol", "ultra", "standard", "272k"])
                try self.assertRouteControlsFillManagementRow(controls, in: host)
            } else {
                func scrollViews(in view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
                }
                let scrollView = try XCTUnwrap(scrollViews(in: host).first)
                XCTAssertGreaterThan(scrollView.frame.height, 100)
                XCTAssertLessThanOrEqual(scrollView.frame.width, 360)
                XCTAssertEqual(host.frame.height, 640, accuracy: 0.5)
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
        preferences.update { $0.preferredMenuHeight = 640; $0.theme = .dark; $0.fontScale = 1 }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("route-width-empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("route-width-fixture-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore()
        let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync, startsInManagement: true)
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

    func testWorkspaceModeDefaultsToManagementAndRestoresSavedSelectionAfterRecreation() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("Offscreen fixture must run in the isolated test runner.")
        }
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["CODEXBAR_HOME"])
        let suiteName = "codexbar.workspace-restoration-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update { $0.preferredMenuHeight = 640 }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("workspace-empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("workspace-fixture-device-sync"), startConfiguredMode: false)
        let store = try self.makeManagementStore()
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-settings-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let modeKey = "codexbar.menu.workspace-mode"
        XCTAssertNil(defaults.object(forKey: modeKey))

        func renderRecreatedView(named name: String) throws -> Int {
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
            return self.routeControls(in: host).count
        }

        XCTAssertEqual(try renderRecreatedView(named: "workspace-first-launch"), 4, "全新安装首次打开应默认管理")
        defaults.set("dashboard", forKey: modeKey)
        XCTAssertEqual(try renderRecreatedView(named: "workspace-restored-dashboard"), 0, "重新创建界面应恢复看板")
        XCTAssertEqual(defaults.string(forKey: modeKey), "dashboard", "缺省管理不能覆盖已保存的看板选择")
        defaults.set("management", forKey: modeKey)
        XCTAssertEqual(try renderRecreatedView(named: "workspace-restored-management"), 4, "重新创建界面应恢复管理")
        XCTAssertEqual(defaults.string(forKey: modeKey), "management")
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
        }
        let tools = ToolUsageStore(collectors: [], cacheURL: CodexPaths.realHome.appendingPathComponent("reserve-empty-tool-cache.json"))
        let sync = DeviceUsageSyncService(storageURL: CodexPaths.realHome.appendingPathComponent("reserve-fixture-device-sync"), startConfiguredMode: false)
        let view = MenuBarView(toolUsageStore: tools, preferencesStore: preferences, deviceSync: sync, startsInManagement: true)
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

    private func makeManagementStore() throws -> TokenStore {
        var account = try self.makeOAuthAccount(accountID: "fixture-layout", email: "layout@example.com", isActive: true, planType: "pro")
        account.displayName = "布局验证"
        account.primaryUsedPercent = 35
        account.primaryResetAt = Date(timeIntervalSinceNow: 86_400)
        account.lunaReserveUsedPercent = 0
        account.lunaReserveResetAt = Date(timeIntervalSinceNow: 604_800)
        account.lunaReserveLimitWindowSeconds = 604_800
        account.lastChecked = Date()
        let provider = CodexBarProvider(
            id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: account.accountId,
            accounts: [CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)]
        )
        try self.writeConfig(CodexBarConfig(
            global: CodexBarGlobalSettings(defaultModel: "gpt-6.1-sol", reasoningEffort: "ultra", modelContextWindows: ["gpt-6.1-sol": 272_000]),
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.accountId), providers: [provider]
        ))
        return self.makeEmptyStore()
    }

    private func routeControls(in view: NSView) -> [RouteSelectionMenuButton] {
        (view as? RouteSelectionMenuButton).map { [$0] } ?? view.subviews.flatMap { self.routeControls(in: $0) }
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
        XCTAssertEqual(firstFrame.minX, 27, accuracy: 0.5, "下拉框应从账号卡内容左边缘开始", file: file, line: line)
        XCTAssertEqual(lastFrame.maxX, 333, accuracy: 0.5, "最后一个下拉框应填满账号卡内容右边缘", file: file, line: line)
        var previousFrame: NSRect?
        for (control, frame) in zip(controls, frames) {
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, 27, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, 333, file: file, line: line)
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
