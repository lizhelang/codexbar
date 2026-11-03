import AppKit
import SwiftUI
import XCTest

@MainActor
final class CodexQuotaResumeViewTests: CodexBarTestCase {
    func testDefaultCurrentAccountOptionEnablesThroughToggleBindingAndRenders() throws {
        let account = try self.makeOAuthAccount(accountID: "desktop-current", email: "current@example.test")
        let coordinator = CodexQuotaResumeCoordinator(
            storageURL: CodexPaths.codexBarRoot.appendingPathComponent("current-option.json"),
            list: { _, _ in [] }, read: { _ in nil }, quota: { _, _ in .unavailable(reason: "fixture") },
            identityIsValid: { $0 == account.id }, bridge: ViewBridge(),
            resolveDesktopAccount: { .resolved(accountID: account.id) })
        defer { coordinator.stop() }
        // 曾选择过另一个账号，默认“当前账号”也不能偷偷回退到旧值。
        coordinator.configure(enabled: false, accountID: "previous-account")
        let oldLanguage = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = oldLanguage }
        let view = CodexQuotaResumeView(coordinator: coordinator, accounts: [account])
        let host = NSHostingView(rootView: view
            .frame(width: 332).padding(14).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 450)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.displayIfNeeded()
        let initialBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: initialBitmap)
        try XCTUnwrap(initialBitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/codexbar-quota-current-account-default.png"))
        // 离屏 SwiftUI 不暴露 AX 子节点；直接使用界面同一 Binding，并独立核对渲染。
        XCTAssertFalse(view.enabledBinding.wrappedValue)
        view.enabledBinding.wrappedValue = true
        XCTAssertTrue(coordinator.state.enabled)
        XCTAssertEqual(coordinator.state.accountID, account.id)
        XCTAssertNil(coordinator.errorMessage)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/codexbar-quota-current-account-enabled.png"))
        XCTAssertFalse(window.isVisible)
    }

    func testWaitingAndUncertainStatesFitNarrowMenuAndRender() throws {
        let now = Date()
        let account = try self.makeOAuthAccount(accountID: "fixture", email: "fixture@example.test")
        var state = CodexQuotaResumeCoordinator.State()
        state.enabled = true
        state.enabledAt = now
        state.accountID = account.id
        var waiting = CodexQuotaResumeCoordinator.Entry(id: UUID(), threadID: UUID().uuidString,
            failedTurnID: "failure-1", accountID: account.id, title: "修复展开算法，继续核对边角覆盖", failureAt: now,
            revision: "fixture", nextCheckAt: now.addingTimeInterval(300))
        waiting.detail = "等待额度恢复"
        var uncertain = waiting
        uncertain = .init(id: UUID(), threadID: UUID().uuidString, failedTurnID: "failure-2", accountID: account.id,
            title: "验证自动恢复是否重复发送", failureAt: now, revision: "fixture-2", status: .uncertain,
            nextCheckAt: now, detail: "上次发送结果未确认，请查看原线程；不会重复发送")
        state.entries = [uncertain, waiting]
        let journal = CodexPaths.codexBarRoot.appendingPathComponent("ui-resume.json")
        try CodexPaths.writeSecureFile(JSONEncoder().encode(state), to: journal)
        let coordinator = CodexQuotaResumeCoordinator(storageURL: journal, list: { _, _ in [] }, read: { _ in nil },
            quota: { _, _ in .unavailable(reason: "fixture") }, identityIsValid: { _ in false }, bridge: ViewBridge())
        defer { coordinator.stop() }
        let oldLanguage = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = oldLanguage }
        let view = CodexQuotaResumeView(coordinator: coordinator, accounts: [account])
            .frame(width: 332).padding(14).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 361)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 600)
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-quota-resume-view.png")
        try png.write(to: output)
        XCTAssertFalse(window.isVisible)
    }
}

@MainActor
private final class ViewBridge: CodexThreadContinuing {
    func capability() -> CodexThreadContinuationBridge.Capability { .unavailable(reason: "fixture") }
    func enqueue(threadID: String, operationID: UUID, authorize: @escaping @MainActor () -> Bool) async -> CodexThreadContinuationBridge.Outcome {
        XCTFail("界面渲染不得启动线程")
        return .notDispatched(reason: "fixture")
    }
}
