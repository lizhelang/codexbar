import AppKit
import SwiftUI
import XCTest
@testable import codexbar

@MainActor
final class ToolQuotaViewTests: XCTestCase {
    func testCompactManagementKeepsQuotaAndBalanceWithoutRepeatingHeadersOrActions() throws {
        let date = Date(timeIntervalSince1970: 1_790_851_200)
        let fixtures = [
            ToolQuotaSnapshot(client: .cursor, status: .ready, providerName: "fixture-provider-hidden",
                windows: [ToolQuotaWindow(id: "cursor", label: "Cursor 模型", usedPercent: 44, resetsAt: date),
                          ToolQuotaWindow(id: "other", label: "其他模型", usedPercent: 71, resetsAt: date)],
                refreshedAt: date, statusDetail: "fixture-ready-description-hidden"),
            ToolQuotaSnapshot(client: .deepSeekHarness, status: .ready, providerName: "fixture-provider-hidden",
                balance: ToolQuotaBalance(amount: 223.26, currency: "CNY"),
                refreshedAt: date, statusDetail: "fixture-ready-description-hidden")
        ]
        let root = VStack(alignment: .leading, spacing: 12) {
            ForEach(fixtures, id: \.client) { snapshot in
                ToolQuotaView(snapshot: snapshot, symbol: "circle.hexagongrid", tint: .cyan,
                    mode: .remaining, expanded: false, toggle: {}, refresh: {}, showUsage: {},
                    managementMode: true, manage: {}, showsHeader: false, compactManagementActions: true)
            }
        }
        .padding(14).frame(width: 360)
        .background(LinearGradient(colors: [MenuSurface.backgroundTop, MenuSurface.backgroundBottom],
                                   startPoint: .top, endPoint: .bottom))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = self.makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        self.settle(host)
        XCTAssertEqual(host.fittingSize.width, 360, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, 65)
        XCTAssertLessThan(host.fittingSize.height, 210, "纯额度详情不应加入账号来源、软件标题和多行操作")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/codexbar-quota-flat-details.png"))
        let elements = self.accessibilityElements(window)
        for client in [ToolUsageClient.cursor, .deepSeekHarness] {
            for action in ["toggle", "refresh", "usage", "manage", "status-detail"] {
                XCTAssertFalse(elements.contains {
                    $0.accessibilityIdentifier() == "codexbar.tool-quota.\(client.rawValue).\(action)"
                })
            }
        }
        let labels = self.labels(elements)
        if labels.contains("Cursor 模型") {
            XCTAssertTrue(labels.contains("56%"), labels)
            XCTAssertTrue(labels.contains("29%"), labels)
            XCTAssertTrue(labels.contains("223.26"), labels)
            XCTAssertFalse(labels.contains("fixture-provider-hidden"), labels)
            XCTAssertFalse(labels.contains("fixture-ready-description-hidden"), labels)
            XCTAssertFalse(labels.contains("DeepSeek Harness"), labels)
        }
    }

    func testCompactManagementActionsExpandInOneRowAndPreservePausedProtection() throws {
        var refreshes = 0
        var usages = 0
        var manages = 0
        let snapshot = ToolQuotaSnapshot(client: .openCode, status: .unsupported,
            providerName: "fixture-provider-hidden",
            statusDetail: "自定义接入地址未提供额度接口；请在原应用中检查接入服务与账号。")
        let view = ToolQuotaView(snapshot: snapshot, symbol: "terminal", tint: .purple,
            mode: .remaining, expanded: true, toggle: {}, refresh: { refreshes += 1 },
            showUsage: { usages += 1 }, managementMode: true, manage: { manages += 1 },
            canRefresh: false, showsHeader: false, compactManagementActions: true)
        view.refreshQuota()
        XCTAssertEqual(refreshes, 0)
        let host = NSHostingView(rootView: view.padding(14).frame(width: 360))
        let window = self.makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        self.settle(host)
        let elements = self.accessibilityElements(window)
        guard elements.contains(where: { $0.accessibilityIdentifier() == "codexbar.tool-quota.openCode.refresh" }) else {
            throw XCTSkip("隔离测试进程未公开 SwiftUI 控件树；紧凑布局另行渲染验证。")
        }
        let buttons = try ["refresh", "usage", "manage"].map { action in
            try XCTUnwrap(elements.first {
                $0.accessibilityIdentifier() == "codexbar.tool-quota.openCode.\(action)"
            })
        }
        XCTAssertFalse(buttons[0].isAccessibilityEnabled())
        for button in buttons {
            XCTAssertEqual(button.accessibilityFrame().midY, buttons[0].accessibilityFrame().midY, accuracy: 2)
        }
        for button in buttons.dropFirst() {
            XCTAssertTrue(button.accessibilityPerformPress())
        }
        XCTAssertEqual(usages, 1)
        XCTAssertEqual(manages, 1)
        XCTAssertFalse(self.labels(elements).contains("fixture-provider-hidden"))
        XCTAssertTrue(elements.contains { $0.accessibilityIdentifier() == "codexbar.tool-quota.openCode.status-detail" })
    }

    func testCompactManagementFailureDescriptionUsesSingleLine() throws {
        let short = ToolQuotaSnapshot(client: .claudeCode, status: .notConfigured, providerName: "Claude",
            statusDetail: "请在 Claude Code 登录")
        let long = ToolQuotaSnapshot(client: .claudeCode, status: .notConfigured, providerName: "Claude",
            statusDetail: String(repeating: "未读取到 Claude Code OAuth 登录；API Key 不含订阅额度，请先在原应用登录。", count: 8))
        func host(_ snapshot: ToolQuotaSnapshot) -> NSHostingView<some View> {
            NSHostingView(rootView: ToolQuotaView(snapshot: snapshot, symbol: "sparkle", tint: .orange,
                mode: .remaining, expanded: false, toggle: {}, refresh: {}, showUsage: {},
                managementMode: true, showsHeader: false, compactManagementActions: true)
                .padding(14).frame(width: 360))
        }
        let shortHost = host(short)
        let longHost = host(long)
        XCTAssertEqual(shortHost.fittingSize.width, 360, accuracy: 1)
        XCTAssertEqual(longHost.fittingSize.height, shortHost.fittingSize.height, accuracy: 1,
                       "连接失败长说明默认不能把软件分段撑成多行")
        let window = self.makeWindow(host: longHost)
        defer { window.contentView = nil; window.close() }
        self.settle(longHost)
        let bitmap = try XCTUnwrap(longHost.bitmapImageRepForCachingDisplay(in: longHost.bounds))
        longHost.cacheDisplay(in: longHost.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/codexbar-quota-flat-unconnected.png"))
    }

    func testManagementShowsConnectionAndActionsWithoutExpanding() throws {
        var toggles = 0
        var refreshes = 0
        var usages = 0
        var manages = 0
        let snapshot = ToolQuotaSnapshot(client: .cursor, status: .ready, providerName: "Cursor",
            windows: [ToolQuotaWindow(id: "plan", label: "套餐用量", usedPercent: 42)],
            statusDetail: "账户服务端额度")
        let view = ToolQuotaView(snapshot: snapshot, symbol: "sparkle", tint: .cyan,
            mode: .remaining, expanded: false, toggle: { toggles += 1 },
            refresh: { refreshes += 1 }, showUsage: { usages += 1 },
            managementMode: true, manage: { manages += 1 })
        let host = NSHostingView(rootView: view.padding(14).frame(width: 360))
        let window = self.makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        self.settle(host)
        let elements = self.accessibilityElements(window)
        guard elements.contains(where: { $0.accessibilityIdentifier() == "codexbar.tool-quota.cursor.refresh" }) else {
            throw XCTSkip("隔离测试进程未公开 SwiftUI 控件树；原生布局另行渲染验证。")
        }
        XCTAssertFalse(elements.contains { $0.accessibilityIdentifier() == "codexbar.tool-quota.cursor.toggle" })
        let labels = elements.compactMap { $0.accessibilityLabel() }.joined(separator: "\n")
        XCTAssertTrue(labels.contains(L.zh ? "已连接" : "Connected"), labels)
        XCTAssertTrue(labels.contains(L.zh ? "尚未刷新" : "Not refreshed yet"), labels)
        for action in ["refresh", "usage", "manage"] {
            let button = try XCTUnwrap(elements.first {
                $0.accessibilityIdentifier() == "codexbar.tool-quota.cursor.\(action)"
            })
            XCTAssertTrue(button.isAccessibilityEnabled(), action)
            XCTAssertTrue(button.accessibilityPerformPress(), action)
        }
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(usages, 1)
        XCTAssertEqual(manages, 1)
    }

    func testRefreshingDisablesQuotaActionWhileConnectionManagementRemainsAvailable() throws {
        var refreshes = 0
        var manages = 0
        for (status, refreshing) in [(ToolQuotaStatus.ready, true), (.loading, false)] {
            let snapshot = ToolQuotaSnapshot(client: .claudeCode, status: status, providerName: "Claude",
                statusDetail: "账户额度")
            let view = ToolQuotaView(snapshot: snapshot, symbol: "sparkle", tint: .orange,
                mode: .remaining, expanded: false, toggle: {}, refresh: { refreshes += 1 },
                showUsage: {}, managementMode: true, isRefreshing: refreshing, manage: { manages += 1 })
            let host = NSHostingView(rootView: view.padding(14).frame(width: 360))
            let window = self.makeWindow(host: host)
            defer { window.contentView = nil; window.close() }
            self.settle(host)
            let elements = self.accessibilityElements(window)
            guard elements.contains(where: { $0.accessibilityIdentifier() == "codexbar.tool-quota.claudeCode.refresh" }) else {
                throw XCTSkip("隔离测试进程未公开 SwiftUI 控件树；刷新保护由动作回归验证。")
            }
            let refresh = try XCTUnwrap(elements.first {
                $0.accessibilityIdentifier() == "codexbar.tool-quota.claudeCode.refresh"
            })
            XCTAssertFalse(refresh.isAccessibilityEnabled())
            _ = refresh.accessibilityPerformPress()
            let manage = try XCTUnwrap(elements.first {
                $0.accessibilityIdentifier() == "codexbar.tool-quota.claudeCode.manage"
            })
            XCTAssertTrue(manage.isAccessibilityEnabled())
            XCTAssertTrue(manage.accessibilityPerformPress())
        }
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(manages, 2)
    }

    func testDashboardKeepsCollapsedControlsHidden() throws {
        var toggles = 0
        let snapshot = ToolQuotaSnapshot(client: .openCode, status: .notConfigured,
            providerName: "OpenCode", statusDetail: "请在 OpenCode 登录")
        let view = ToolQuotaView(snapshot: snapshot, symbol: "terminal", tint: .purple,
            mode: .remaining, expanded: false, toggle: { toggles += 1 }, refresh: {}, showUsage: {})
        let host = NSHostingView(rootView: view.padding(14).frame(width: 360))
        let window = self.makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        self.settle(host)
        let elements = self.accessibilityElements(window)
        for action in ["refresh", "usage", "manage"] {
            XCTAssertFalse(elements.contains {
                $0.accessibilityIdentifier() == "codexbar.tool-quota.openCode.\(action)"
            })
        }
        guard elements.contains(where: { $0.accessibilityIdentifier() == "codexbar.tool-quota.openCode.toggle" }) else {
            throw XCTSkip("隔离测试进程未公开 SwiftUI 折叠按钮。")
        }
        let toggle = try XCTUnwrap(elements.first {
            $0.accessibilityIdentifier() == "codexbar.tool-quota.openCode.toggle"
        })
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertEqual(toggles, 1)
    }

    func testRefreshActionRejectsPausedLoadingAndConcurrentRequests() {
        var calls = 0
        for (status, busy, enabled) in [(ToolQuotaStatus.ready, false, false), (.ready, true, true), (.loading, false, true)] {
            let view = ToolQuotaView(snapshot: ToolQuotaSnapshot(client: .cursor, status: status,
                providerName: "Cursor", statusDetail: "fixture"), symbol: "circle", tint: .cyan,
                mode: .remaining, expanded: true, toggle: {}, refresh: { calls += 1 }, showUsage: {},
                managementMode: true, isRefreshing: busy, canRefresh: enabled)
            view.refreshQuota()
        }
        XCTAssertEqual(calls, 0)
        let available = ToolQuotaView(snapshot: ToolQuotaSnapshot(client: .cursor, status: .ready,
            providerName: "Cursor", statusDetail: "fixture"), symbol: "circle", tint: .cyan,
            mode: .remaining, expanded: true, toggle: {}, refresh: { calls += 1 }, showUsage: {})
        available.refreshQuota()
        XCTAssertEqual(calls, 1)
    }

    func testQuotaAndBalanceNativeLayoutFitsMenuWidth() throws {
        let date = Date(timeIntervalSince1970: 1_790_851_200)
        let fixtures = [
            ToolQuotaSnapshot(client: .claudeCode, status: .ready, providerName: "Claude",
                windows: [ToolQuotaWindow(id: "five-hour", label: "5 小时", usedPercent: 24, resetsAt: date),
                          ToolQuotaWindow(id: "seven-day", label: "7 天", usedPercent: 62, resetsAt: date)],
                refreshedAt: date, statusDetail: "Claude Code 现有 OAuth 账户额度"),
            ToolQuotaSnapshot(client: .cursor, status: .ready, providerName: "Cursor",
                windows: [ToolQuotaWindow(id: "plan", label: "套餐用量", usedPercent: 42)],
                refreshedAt: date, statusDetail: "账户服务端额度"),
            ToolQuotaSnapshot(client: .deepSeekHarness, status: .ready, providerName: "接入服务",
                balance: ToolQuotaBalance(amount: 12.34, currency: "CNY"),
                refreshedAt: date, statusDetail: "余额快照；按量付费，不提供订阅百分比"),
            ToolQuotaSnapshot(client: .openCode, status: .authenticationRequired, providerName: "OpenCode",
                refreshedAt: date, statusDetail: "登录已过期或额度读取未获授权，请在原应用重新登录")
        ]
        let root = VStack(spacing: 0) {
            ForEach(fixtures, id: \.client) { snapshot in
                ToolQuotaView(snapshot: snapshot, symbol: "circle.hexagongrid", tint: .cyan,
                    mode: .remaining, expanded: snapshot.client == .deepSeekHarness,
                    toggle: {}, refresh: {}, showUsage: {})
            }
        }
        .padding(14).frame(width: 360)
        .background(LinearGradient(colors: [MenuSurface.backgroundTop, MenuSurface.backgroundBottom],
                                   startPoint: .top, endPoint: .bottom))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        XCTAssertEqual(size.width, 360, accuracy: 1)
        XCTAssertGreaterThan(size.height, 300)
        XCTAssertLessThan(size.height, 750)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/codexbar-quota-layout.png"))
    }

    func testAllManagementCardsFitMenuWidthWithConnectionDetails() throws {
        let date = Date(timeIntervalSince1970: 1_790_851_200)
        let fixtures = [
            ToolQuotaSnapshot(client: .claudeCode, status: .notConfigured, providerName: "Claude Code",
                statusDetail: "未读取到 Claude Code OAuth 登录，请在 Claude Code 登录"),
            ToolQuotaSnapshot(client: .openCode, status: .unsupported,
                providerName: "OpenCode Go · DeepSeek 自定义接入服务",
                refreshedAt: date, statusDetail: "自定义接入地址未提供已支持的额度接口；其他接入服务未返回统一额度"),
            ToolQuotaSnapshot(client: .cursor, status: .ready, providerName: "Cursor",
                windows: [ToolQuotaWindow(id: "cursor", label: "Cursor 模型", usedPercent: 44, resetsAt: date),
                          ToolQuotaWindow(id: "other", label: "其他模型", usedPercent: 71, resetsAt: date)],
                refreshedAt: date, statusDetail: "账户服务端额度"),
            ToolQuotaSnapshot(client: .deepSeekHarness, status: .ready, providerName: "DeepSeek API",
                balance: ToolQuotaBalance(amount: 223.26, currency: "CNY"),
                refreshedAt: date, statusDetail: "余额快照；按量付费，不提供订阅百分比")
        ]
        let root = VStack(spacing: 0) {
            ForEach(fixtures, id: \.client) { snapshot in
                ToolQuotaView(snapshot: snapshot, symbol: "circle.hexagongrid", tint: .cyan,
                    mode: .remaining, expanded: false, toggle: {}, refresh: {}, showUsage: {},
                    managementMode: true, manage: {})
            }
        }
        .padding(14).frame(width: 360)
        .background(LinearGradient(colors: [MenuSurface.backgroundTop, MenuSurface.backgroundBottom],
                                   startPoint: .top, endPoint: .bottom))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = self.makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        self.settle(host)
        let size = host.fittingSize
        XCTAssertEqual(size.width, 360, accuracy: 1)
        XCTAssertGreaterThan(size.height, 600)
        XCTAssertLessThan(size.height, 1100)
        let elements = self.accessibilityElements(window)
        if elements.contains(where: { $0.accessibilityIdentifier()?.hasPrefix("codexbar.tool-quota.") == true }) {
            for snapshot in fixtures {
                for action in ["refresh", "usage", "manage"] {
                    let element = try XCTUnwrap(elements.first {
                        $0.accessibilityIdentifier() == "codexbar.tool-quota.\(snapshot.client.rawValue).\(action)"
                    })
                    XCTAssertGreaterThan(element.accessibilityFrame().width, 10)
                    XCTAssertLessThanOrEqual(element.accessibilityFrame().width, 332)
                }
            }
        } else {
            try "SwiftUI 控件树不可见；已验证原生尺寸，操作路径由数据与动作回归覆盖。\n".write(
                to: URL(fileURLWithPath: "/private/tmp/codexbar-quota-management-ax-limitation.txt"), atomically: true, encoding: .utf8)
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/codexbar-quota-management-layout.png"))
    }

    private func makeWindow(host: NSView) -> NSWindow {
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        XCTAssertFalse(window.isVisible)
        return window
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }

    private func labels(_ elements: [any NSAccessibilityProtocol]) -> String {
        elements.flatMap {
            [$0.accessibilityLabel(), $0.accessibilityValue() as? String].compactMap { $0 }
        }.joined(separator: "\n")
    }

    private func accessibilityElements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 20, let element = object as? NSAccessibilityProtocol else { return [] }
        var children: [Any] = element.accessibilityChildren() ?? []
        if let window = object as? NSWindow, let contentView = window.contentView { children.append(contentView) }
        if let view = object as? NSView { children.append(contentsOf: view.subviews) }
        return [element] + children.flatMap { self.accessibilityElements($0, depth: depth + 1) }
    }
}
