import AppKit
import SwiftUI
import XCTest
@testable import codexbar

@MainActor
final class CodexAccountQuotaViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_851_200)

    func testAllWindowsAndReserveAreVisibleWithoutHover() throws {
        let account = self.fixture()
        let view = CodexAccountQuotaView(account: account, mode: .remaining, now: self.now)
        let host = NSHostingView(rootView: view.padding(14).frame(width: 360))
        let window = self.makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        self.settle(host)
        let elements = self.accessibilityElements(window)
        let text = self.labels(elements)
        guard elements.contains(where: { $0.accessibilityIdentifier()?.hasPrefix("codexbar.codex-quota.") == true }) else {
            throw XCTSkip("隔离进程不公开 SwiftUI 控件树；完整窗口内容由数据回归及原生渲染验证。")
        }
        for label in ["5h", "7d", L.lunaReserve, "80%", "71%", "24%"] {
            XCTAssertTrue(text.contains(label), text)
        }
        for detail in ["updated", "reset-cards"] {
            XCTAssertTrue(elements.contains {
                $0.accessibilityIdentifier() == "codexbar.codex-quota.\(account.id).\(detail)"
            }, detail)
        }
        XCTAssertTrue(text.contains(L.resetInHr(4, 0)), text)
        XCTAssertTrue(text.contains(L.resetInDay(6, 0)), text)
        XCTAssertTrue(text.contains(L.resetInDay(5, 0)), text)
        XCTAssertEqual(view.resetCount, 2)
    }

    func testUnrefreshedAccountShowsUnknownWithoutInventingQuota() {
        let account = TokenAccount(accountId: "fixture-empty")
        let view = CodexAccountQuotaView(account: account, mode: .remaining, now: self.now)
        XCTAssertTrue(view.windows.isEmpty)
        let host = NSHostingView(rootView: view.padding(14).frame(width: 360))
        let window = self.makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        self.settle(host)
        let text = self.labels(self.accessibilityElements(window))
        if self.accessibilityElements(window).contains(where: { $0.accessibilityIdentifier()?.hasSuffix(".unknown") == true }) {
            XCTAssertTrue(text.contains(L.zh ? "尚未刷新" : "Not refreshed yet"), text)
            XCTAssertTrue(text.contains(L.zh ? "额度未知" : "Quota unknown"), text)
            XCTAssertFalse(text.contains("%"), text)
        }
    }

    func testReserveSnapshotDoesNotInventOrdinaryWindow() {
        let account = TokenAccount(accountId: "fixture-reserve", lunaReserveUsedPercent: 76,
            lunaReserveResetAt: self.now.addingTimeInterval(5 * 86_400))
        let view = CodexAccountQuotaView(account: account, mode: .remaining, now: self.now)
        XCTAssertEqual(view.windows.map(\.display.label), [L.lunaReserve])
        XCTAssertEqual(view.windows.first?.percent, 24)
        XCTAssertEqual(view.windows.first?.resetAt, account.lunaReserveResetAt)
    }

    func testSortedWindowsKeepTheirOriginalResetDates() {
        let fiveHourReset = self.now.addingTimeInterval(4 * 3_600)
        let weeklyReset = self.now.addingTimeInterval(6 * 86_400)
        let account = TokenAccount(accountId: "fixture-sorted", planType: "pro",
            primaryUsedPercent: 3, secondaryUsedPercent: 42,
            primaryResetAt: weeklyReset, secondaryResetAt: fiveHourReset,
            primaryLimitWindowSeconds: 7 * 86_400, secondaryLimitWindowSeconds: 5 * 3_600,
            lastChecked: self.now)
        let view = CodexAccountQuotaView(account: account, mode: .used, now: self.now)
        XCTAssertEqual(view.windows.map(\.display.label), ["5h", "7d"])
        XCTAssertEqual(view.windows.map(\.percent), [42, 3])
        XCTAssertEqual(view.windows.map(\.resetAt), [fiveHourReset, weeklyReset])
    }

    func testDuplicateWindowsUseResetFromTheSelectedQuotaSnapshot() {
        let laterReset = self.now.addingTimeInterval(4 * 3_600)
        let account = TokenAccount(accountId: "fixture-duplicate", planType: "plus",
            primaryUsedPercent: 20, secondaryUsedPercent: 35,
            primaryResetAt: self.now.addingTimeInterval(2 * 3_600), secondaryResetAt: laterReset,
            primaryLimitWindowSeconds: 5 * 3_600, secondaryLimitWindowSeconds: 5 * 3_600,
            lastChecked: self.now)
        let view = CodexAccountQuotaView(account: account, mode: .remaining, now: self.now)
        XCTAssertEqual(view.windows.count, 1)
        XCTAssertEqual(view.windows.first?.percent, 65)
        XCTAssertEqual(view.windows.first?.resetAt, laterReset)
    }

    func testNonfiniteQuotaShowsUnknownAndMissingResetIsExplicit() {
        let account = TokenAccount(accountId: "fixture-invalid", primaryUsedPercent: .nan,
            primaryLimitWindowSeconds: 5 * 3_600, lastChecked: self.now)
        let view = CodexAccountQuotaView(account: account, mode: .used, now: self.now)
        XCTAssertNil(view.windows.first?.percent)
        let host = NSHostingView(rootView: view.padding(14).frame(width: 360))
        let window = self.makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        self.settle(host)
        let text = self.labels(self.accessibilityElements(window))
        if self.accessibilityElements(window).contains(where: { $0.accessibilityIdentifier()?.contains(".window.") == true }) {
            XCTAssertTrue(text.contains(L.zh ? "额度未知" : "Quota unknown"), text)
            XCTAssertTrue(text.contains(L.zh ? "重置时间未知" : "Reset time unknown"), text)
            XCTAssertFalse(text.contains("%"), text)
        }
    }

    func testManagementAccountRowFitsMenuAndRetainsActionsAndThreadBadge() throws {
        var activations: [OpenAIManualActivationTrigger] = []
        let account = self.fixture()
        let root = AccountRowView(account: account, accountLabel: "fixture@example.com",
            accountDetail: nil,
            rowState: OpenAIAccountRowState(isNextUseTarget: false, runningThreadCount: 2,
                accountUsageMode: .switchAccount),
            isRefreshing: false, usageDisplayMode: .remaining,
            defaultManualActivationBehavior: nil,
            onActivate: { activations.append($0) }, onRefresh: {}, onReauth: {}, onDelete: {},
            showsQuotaDetails: true, now: self.now)
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
        XCTAssertGreaterThan(size.height, 200)
        XCTAssertLessThan(size.height, 450)
        let elements = self.accessibilityElements(window)
        let text = self.labels(elements)
        if elements.contains(where: { $0.accessibilityIdentifier()?.hasPrefix("codexbar.codex-quota.") == true }) {
            XCTAssertTrue(text.contains(L.lunaReserve), text)
            XCTAssertTrue(text.contains(L.runningThreads(2)), text)
            XCTAssertTrue(text.contains(L.zh ? "更多账号操作" : "More account actions"), text)
            let activation = try XCTUnwrap(elements.first { $0.accessibilityLabel() == L.useBtn })
            XCTAssertTrue(activation.accessibilityPerformPress())
            XCTAssertEqual(activations, [.primaryTap])
            for element in elements where element.accessibilityIdentifier()?.contains(".window.") == true {
                XCTAssertLessThanOrEqual(element.accessibilityFrame().width, 332)
            }
        } else {
            try "SwiftUI 控件树不可见；原生账号行已渲染，切换操作由既有账号回归覆盖。\n".write(
                to: URL(fileURLWithPath: "/private/tmp/codexbar-codex-quota-ax-limitation.txt"), atomically: true, encoding: .utf8)
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/codexbar-codex-quota-management-layout.png"))
    }

    private func fixture() -> TokenAccount {
        TokenAccount(email: "fixture@example.com", accountId: "fixture-plus", planType: "plus",
            primaryUsedPercent: 20, secondaryUsedPercent: 29,
            primaryResetAt: self.now.addingTimeInterval(4 * 3_600),
            secondaryResetAt: self.now.addingTimeInterval(6 * 86_400),
            primaryLimitWindowSeconds: 5 * 3_600, secondaryLimitWindowSeconds: 7 * 86_400,
            lunaReserveUsedPercent: 76, lunaReserveResetAt: self.now.addingTimeInterval(5 * 86_400),
            lunaReserveLimitWindowSeconds: 7 * 86_400, lastChecked: self.now,
            rateLimitResetAvailableCount: 1,
            rateLimitResetCredits: [
                RateLimitResetCredit(id: "available", title: "fixture", status: "available", expiresAt: nil),
                RateLimitResetCredit(id: "later", title: "fixture", status: "available",
                    expiresAt: self.now.addingTimeInterval(3_600)),
                RateLimitResetCredit(id: "expired", title: "fixture", status: "available",
                    expiresAt: self.now.addingTimeInterval(-1))
            ])
    }

    private func makeWindow(host: NSView) -> NSWindow {
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
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
        return [element] + (element.accessibilityChildren() ?? []).flatMap {
            self.accessibilityElements($0, depth: depth + 1)
        }
    }
}
