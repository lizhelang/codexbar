import AppKit
import SwiftUI
import XCTest
@testable import codexbar

@MainActor
final class ToolQuotaViewTests: XCTestCase {
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
}
