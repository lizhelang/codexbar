import AppKit
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import codexbar

/// 仅渲染未显示的测试窗口；网络、身份、额度与凭据均为临时 fixture。
@MainActor
final class ClaudeAccountFlowTests: CodexBarTestCase {
    func testWaitingSheetShowsEditableAuthorizationFieldAndExistingCredentialEntry() async throws {
        let fixture = try self.makeFixture()
        defer { fixture.cleanup() }
        var opened: [URL] = []
        let coordinator = AccountBrowserLoginCoordinator(transport: fixture.transport, openURL: { opened.append($0) })
        defer { coordinator.stop() }
        coordinator.start(.claude, connections: fixture.connections, cursorAccounts: fixture.cursor,
                          preferences: fixture.preferences.preferences)
        try await self.waitUntil { coordinator.phase == .waiting }
        XCTAssertEqual(opened.count, 1)
        let originalLanguage = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = originalLanguage }
        let rendered = try self.render(AccountBrowserLoginSheet(coordinator: coordinator, onClose: {}),
                                       size: CGSize(width: 480, height: 460), name: "claude-waiting")
        defer { rendered.close() }
        let visibleText = try self.recognizedText(rendered.host)
        XCTAssertTrue(visibleText.contains("授权码"), visibleText)
        XCTAssertTrue(visibleText.contains("使用已有登录凭据"), visibleText)
        let field = try XCTUnwrap(self.secureFields(in: rendered.host).first,
                                 "离屏控件树未暴露 NSSecureTextField，无法宣称已验证原生可编辑性")
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(field.isEditable)
        let frame = rendered.host.convert(field.bounds, from: field)
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(rendered.host.bounds.intersects(frame), "授权码输入框必须位于 480×460 视口内")
        let requests = await fixture.transport.requests
        XCTAssertTrue(requests.isEmpty, "仅打开登录页不能交换令牌或查询真实网络")
        XCTAssertFalse(rendered.window.isVisible)
    }

    func testCorrectedCallbackVerifiesIdentityQuotaAndPersistsSecretsOnlyOnce() async throws {
        let fixture = try self.makeFixture()
        defer { fixture.cleanup() }
        var opened: [URL] = []
        let coordinator = AccountBrowserLoginCoordinator(transport: fixture.transport, openURL: { opened.append($0) })
        defer { coordinator.stop() }
        coordinator.start(.claude, connections: fixture.connections, cursorAccounts: fixture.cursor,
                          preferences: fixture.preferences.preferences)
        try await self.waitUntil { coordinator.phase == .waiting }
        let authorization = try XCTUnwrap(opened.first)
        await coordinator.submitClaudeCallback(try self.callback(from: authorization, stateOverride: "incorrect-state"))
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertTrue(coordinator.canSubmitClaudeCallback, "错误 state 后仍可提交本次正确回调")
        let rejectedRequests = await fixture.transport.requests
        XCTAssertTrue(rejectedRequests.isEmpty)
        XCTAssertTrue(fixture.connections.profiles.isEmpty)

        let validCallback = try self.callback(from: authorization)
        let before = Date()
        await coordinator.submitClaudeCallback(validCallback)
        XCTAssertEqual(coordinator.phase, .saved)
        XCTAssertFalse(coordinator.canSubmitClaudeCallback)
        let profile = try XCTUnwrap(fixture.connections.profiles(for: .claudeCode).first)
        XCTAssertEqual(profile.accountIdentity, "account:flow-account:organization:flow-org")
        let quota = try XCTUnwrap(fixture.connections.quota(for: profile.id))
        XCTAssertEqual(quota.status, .ready)
        XCTAssertEqual(quota.windows.map(\.usedPercent), [35, 20])
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/oauth/token", "/api/oauth/profile", "/api/oauth/usage"])
        XCTAssertEqual(requests.map { $0.url?.host }, ["platform.claude.com", "api.anthropic.com", "api.anthropic.com"])
        let exchange = try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: String]
        XCTAssertEqual(exchange?["grant_type"], "authorization_code")
        XCTAssertEqual(exchange?["code"], "fixture-authorization-code")
        XCTAssertEqual(exchange?["state"], try self.query("state", from: authorization))
        XCTAssertEqual(exchange?["redirect_uri"], try self.query("redirect_uri", from: authorization))
        XCTAssertTrue(requests.dropFirst().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(ClaudeFlowTokens.access)"
        })

        let files = ["connections.json", "quota-cache.json", "credentials.json"]
        let saved = try Dictionary(uniqueKeysWithValues: files.map {
            ($0, try Data(contentsOf: fixture.directory.appendingPathComponent($0)))
        })
        for name in files.prefix(2) {
            let text = String(decoding: try XCTUnwrap(saved[name]), as: UTF8.self)
            XCTAssertFalse(text.contains(ClaudeFlowTokens.access))
            XCTAssertFalse(text.contains(ClaudeFlowTokens.refresh))
        }
        let credentials = try JSONDecoder().decode([String: ManagedToolCredential].self,
                                                   from: XCTUnwrap(saved["credentials.json"]))
        let privateCredential = try XCTUnwrap(credentials[profile.id])
        XCTAssertEqual(privateCredential.oauthToken, ClaudeFlowTokens.access)
        XCTAssertEqual(privateCredential.oauthRefreshToken, ClaudeFlowTokens.refresh)
        XCTAssertEqual(privateCredential.oauthScopes, ["user:profile", "user:inference"])
        let expiry = try XCTUnwrap(privateCredential.oauthExpiresAt)
        XCTAssertGreaterThanOrEqual(expiry, before.addingTimeInterval(3_600))
        XCTAssertLessThanOrEqual(expiry, Date().addingTimeInterval(3_600))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.directory.appendingPathComponent("credentials.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        await coordinator.submitClaudeCallback(validCallback)
        let afterDuplicate = await fixture.transport.requests
        XCTAssertEqual(afterDuplicate.count, 3)
        XCTAssertEqual(fixture.connections.profiles.count, 1)
        for name in files {
            XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent(name)), try XCTUnwrap(saved[name]),
                           "重复提交不能重复保存 \(name)")
        }
    }

    func testTimedOutLoginReopensWithNewStateAndRejectsPreviousCallback() async throws {
        let fixture = try self.makeFixture()
        defer { fixture.cleanup() }
        var opened: [URL] = []
        let coordinator = AccountBrowserLoginCoordinator(
            transport: fixture.transport, openURL: { opened.append($0) }, claudeTimeout: .milliseconds(200))
        defer { coordinator.stop() }
        coordinator.start(.claude, connections: fixture.connections, cursorAccounts: fixture.cursor,
                          preferences: fixture.preferences.preferences)
        try await self.waitUntil { coordinator.phase == .waiting }
        let original = try XCTUnwrap(opened.first)
        try await self.waitUntil { coordinator.phase == .failed }
        coordinator.reopenClaudeAuthorization()
        try await self.waitUntil { opened.count == 2 && coordinator.phase == .waiting }
        let reopened = try XCTUnwrap(opened.last)
        XCTAssertNotEqual(try self.query("state", from: original), try self.query("state", from: reopened))
        await coordinator.submitClaudeCallback(try self.callback(from: original))
        XCTAssertEqual(coordinator.phase, .failed)
        let rejectedRequests = await fixture.transport.requests
        XCTAssertTrue(rejectedRequests.isEmpty)
        await coordinator.submitClaudeCallback(try self.callback(from: reopened))
        XCTAssertEqual(coordinator.phase, .saved)
        XCTAssertEqual(fixture.connections.profiles.count, 1)
    }

    func testManualOAuthFieldIsEditableBeforeAnyOrganizationHasBeenLoaded() throws {
        let fixture = try self.makeFixture()
        defer { fixture.cleanup() }
        let originalLanguage = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = originalLanguage }
        let view = ManagedToolAccountForm(client: .claudeCode, form: AccountForm(kind: .credential),
            cursorAccounts: fixture.cursor, connections: fixture.connections, openURL: { _ in }, onDone: {})
        let rendered = try self.render(view, size: CGSize(width: 480, height: 480), name: "claude-manual-empty")
        defer { rendered.close() }
        XCTAssertTrue(fixture.connections.organizations.isEmpty)
        let field = try XCTUnwrap(self.secureFields(in: rendered.host).first,
                                 "未发现原生保密输入框，不能宣称可输入")
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(field.isEditable)
        field.stringValue = ClaudeFlowTokens.access
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        self.settle(rendered.host)
        XCTAssertEqual(field.stringValue, ClaudeFlowTokens.access)
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(field.isEditable)
        let text = try self.recognizedText(rendered.host)
        XCTAssertTrue(text.contains("OAuth"), text)
        XCTAssertFalse(text.contains("读取组织"), "OAuth 输入不应要求先读取网站组织")
        let save = self.accessibilityElements(rendered.window).first {
            $0.accessibilityIdentifier() == "codexbar.account-form.save"
        }
        if let save {
            XCTAssertTrue(save.isAccessibilityEnabled(), "粘贴 OAuth 令牌后保存入口应启用")
        } else if let button = self.nativeButtons(in: rendered.host).first(where: { $0.title == "保存" }) {
            XCTAssertTrue(button.isEnabled)
        } else {
            let note = XCTAttachment(string: "离屏 SwiftUI 未暴露原生/AX 保存按钮。已验证 NSSecureTextField 可编辑、delegate 更新与 OAuth 组织分支；未声称验证实体键盘操作或保存按钮的原生 enabled 状态。")
            note.name = "claude-manual-native-button-limitation"
            note.lifetime = .keepAlways
            self.add(note)
            XCTAssertTrue(text.contains("保存"), text)
        }
    }

    @MainActor private struct Fixture {
        let transport: ClaudeFlowTransport
        let connections: ToolConnectionStore
        let cursor: CursorAccountStore
        let preferences: ApplicationPreferencesStore
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }

    private func makeFixture() throws -> Fixture {
        XCTAssertNotEqual(CodexPaths.realHome, FileManager.default.homeDirectoryForCurrentUser)
        let suite = "codexbar.claude-flow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        let transport = ClaudeFlowTransport()
        let directory = CodexPaths.realHome.appendingPathComponent("claude-flow-connections")
        let service = ToolConnectionService(transport: transport, home: CodexPaths.realHome,
                                            environment: [:], keychainReader: { nil })
        let connections = ToolConnectionStore(directory: directory, service: service, preferencesStore: preferences)
        let cursor = CursorAccountStore(rootURL: CodexPaths.realHome.appendingPathComponent("claude-flow-cursor"),
            service: CursorAccountService(transport: transport),
            sessionReader: CursorDesktopSessionReader(databaseURL: CodexPaths.realHome.appendingPathComponent("absent-cursor.db")),
            preferencesStore: preferences)
        return Fixture(transport: transport, connections: connections, cursor: cursor, preferences: preferences,
                       directory: directory, defaults: defaults, suite: suite)
    }

    private func query(_ name: String, from url: URL) throws -> String {
        try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value)
    }

    private func callback(from authorization: URL, stateOverride: String? = nil) throws -> String {
        var callback = try XCTUnwrap(URLComponents(string: self.query("redirect_uri", from: authorization)))
        callback.queryItems = [
            URLQueryItem(name: "code", value: "fixture-authorization-code"),
            URLQueryItem(name: "state", value: try stateOverride ?? self.query("state", from: authorization)),
        ]
        return try XCTUnwrap(callback.url?.absoluteString)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "等待 fixture 状态变化超时")
    }

    @MainActor private struct Rendered {
        let host: NSView
        let window: NSWindow
        func close() { window.contentView = nil; window.close() }
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) throws -> Rendered {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: SettingsPalette.colorScheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        self.settle(host)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-claude-flow-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        self.add(attachment)
        XCTAssertFalse(window.isVisible)
        return Rendered(host: host, window: window)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private func recognizedText(_ host: NSView) throws -> String {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["Claude", "OAuth", "授权码", "使用已有登录凭据"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().filter { !$0.isWhitespace }
    }

    private func secureFields(in view: NSView) -> [NSSecureTextField] {
        (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { self.secureFields(in: $0) }
    }

    private func nativeButtons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { self.nativeButtons(in: $0) }
    }

    private func accessibilityElements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 20, let element = object as? NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { self.accessibilityElements($0, depth: depth + 1) }
    }
}

nonisolated private enum ClaudeFlowTokens {
    static let access = "sk-ant-oat-fixture-browser-access"
    static let refresh = "fixture-browser-refresh"
}

private actor ClaudeFlowTransport: CursorUsageHTTPTransport {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        let body: String
        switch (url.host, url.path) {
        case ("platform.claude.com", "/v1/oauth/token"):
            body = #"{"access_token":"\#(ClaudeFlowTokens.access)","refresh_token":"\#(ClaudeFlowTokens.refresh)","expires_in":3600,"scope":"user:profile user:inference"}"#
        case ("api.anthropic.com", "/api/oauth/profile"):
            body = #"{"account":{"uuid":"flow-account","email_address":"flow@example.test"},"organization":{"uuid":"flow-org"}}"#
        case ("api.anthropic.com", "/api/oauth/usage"):
            body = #"{"five_hour":{"utilization":35},"seven_day":{"utilization":20}}"#
        default:
            throw URLError(.unsupportedURL)
        }
        let data = Data(body.utf8)
        guard data.count <= limit, let response = HTTPURLResponse(url: url, statusCode: 200,
                                                                 httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}
