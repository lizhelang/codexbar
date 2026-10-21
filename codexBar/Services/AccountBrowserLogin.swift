import AppKit
import Combine
import CoreFoundation
import CryptoKit
import Foundation
import SwiftUI

/// Browser login for accounts other than Codex.
/// Claude uses its public OAuth callback. The others open the official page and import a
/// credential only after the original app writes it locally. Browser cookie stores are not read.
enum AccountBrowserLoginKind: Equatable {
    case claude
    case cursor
    case openCode
    case deepSeek

    var client: ToolUsageClient {
        switch self {
        case .claude: .claudeCode
        case .cursor: .cursor
        case .openCode: .openCode
        case .deepSeek: .deepSeekHarness
        }
    }

    var title: String {
        switch self {
        case .claude: L.zh ? "添加 Claude 账号" : "Add Claude account"
        case .cursor: L.zh ? "添加 Cursor 账号" : "Add Cursor account"
        case .openCode: L.zh ? "添加 OpenCode 账号" : "Add OpenCode account"
        case .deepSeek: L.zh ? "添加 DeepSeek 账号" : "Add DeepSeek account"
        }
    }

    var pageURL: URL? {
        switch self {
        case .claude: nil
        case .cursor: URL(string: "https://cursor.com/dashboard")
        case .openCode: URL(string: "https://opencode.ai/auth")
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")
        }
    }

    var waitingMessage: String {
        switch self {
        case .claude:
            return L.zh
                ? "已在默认浏览器打开 Claude 登录。登录完成后会自动保存。"
                : "Claude sign-in is open in your default browser. It will be saved when login finishes."
        case .cursor:
            return L.zh
                ? "已在默认浏览器打开 Cursor。Cursor 把登录写回本机后会自动保存。"
                : "Cursor is open in your default browser. The account is saved after Cursor writes the login locally."
        case .openCode:
            return L.zh
                ? "已在默认浏览器打开 OpenCode 登录。本机出现新的登录或 API Key 后会自动保存。"
                : "OpenCode sign-in is open in your default browser. A new local login or API key is saved automatically."
        case .deepSeek:
            return L.zh
                ? "已打开 DeepSeek API Key 页面。本机 DeepSeek Harness 或 OpenCode 保存官方 Key 后会自动导入。"
                : "The DeepSeek API key page is open. An official key saved by DeepSeek Harness or OpenCode is imported automatically."
        }
    }
}

enum AccountBrowserLoginPhase: Equatable {
    case idle, checking, waiting, saving, saved, failed
}

nonisolated enum ClaudeLoginError: LocalizedError, Equatable {
    case invalidCallback
    case stateMismatch
    case denied
    case exchangeFailed

    var errorDescription: String? {
        switch self {
        case .invalidCallback: L.zh ? "没有收到登录回调。" : "The login callback did not arrive."
        case .stateMismatch: L.zh ? "登录回调校验失败，请重试。" : "The login callback could not be verified. Try again."
        case .denied: L.zh ? "登录已取消。" : "Login was cancelled."
        case .exchangeFailed: L.zh ? "登录完成了，但没有拿到可用的令牌。" : "Login finished without a usable token."
        }
    }
}

nonisolated struct ClaudeOAuthSession: Equatable, Sendable {
    let state: String
    let codeVerifier: String
    let redirectURI: String
    let authorizationURL: URL
}

nonisolated enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let manualRedirectURI = "https://platform.claude.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    static let userAgent = "claude-cli/2.1.299 (external, cli)"

    static func makeSession(port: UInt16) throws -> ClaudeOAuthSession {
        let verifier = Self.randomBase64URL(byteCount: 32)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomBase64URL(byteCount: 24)
        let redirectURI = "http://localhost:\(port)/callback"
        var components = URLComponents(string: Self.authorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizationURL = components?.url else { throw ClaudeLoginError.exchangeFailed }
        return ClaudeOAuthSession(state: state, codeVerifier: verifier, redirectURI: redirectURI, authorizationURL: authorizationURL)
    }

    static func authorizationCode(callbackURL: String, session: ClaudeOAuthSession) throws -> String {
        try Self.authorizationResponse(callbackURL, session: session).code
    }

    static func manualAuthorizationURL(session: ClaudeOAuthSession) -> URL? {
        var components = URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false)
        let items = components?.queryItems?.map {
            $0.name == "redirect_uri" ? URLQueryItem(name: $0.name, value: Self.manualRedirectURI) : $0
        }
        components?.queryItems = items
        return components?.url
    }

    static func authorizationResponse(_ raw: String, session: ClaudeOAuthSession) throws -> (code: String, manual: Bool) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 16 * 1024,
              input.rangeOfCharacter(from: .controlCharacters) == nil else { throw ClaudeLoginError.invalidCallback }
        if !input.contains("://") {
            let parts = input.split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { throw ClaudeLoginError.invalidCallback }
            guard parts[1] == session.state else { throw ClaudeLoginError.stateMismatch }
            guard !parts[0].contains(where: \.isWhitespace) else { throw ClaudeLoginError.invalidCallback }
            return (String(parts[0]), true)
        }
        guard let components = URLComponents(string: input),
              let expected = URLComponents(string: session.redirectURI),
              components.user == nil, components.password == nil,
              components.fragment == nil else { throw ClaudeLoginError.invalidCallback }
        let manual = components.scheme == "https" && components.host == "platform.claude.com"
            && components.port == nil && components.path == "/oauth/code/callback"
        let local = components.scheme == expected.scheme && components.host == expected.host
            && components.port == expected.port && components.path == expected.path
        guard local || manual else { throw ClaudeLoginError.invalidCallback }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == session.state else { throw ClaudeLoginError.stateMismatch }
        if items.contains(where: { $0.name == "error" }) { throw ClaudeLoginError.denied }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              !code.contains(where: \.isWhitespace), !code.contains("#") else {
            throw ClaudeLoginError.invalidCallback
        }
        return (code, manual)
    }

    static func tokenRequest(code: String, session: ClaudeOAuthSession, manual: Bool = false) throws -> URLRequest {
        guard let url = URL(string: Self.tokenURL) else { throw ClaudeLoginError.exchangeFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": session.codeVerifier,
            "client_id": Self.clientID,
            "redirect_uri": manual ? Self.manualRedirectURI : session.redirectURI,
            "state": session.state,
        ])
        return request
    }

    static func refreshRequest(refreshToken: String, scopes: [String]?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var body = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientID]
        if let scopes, !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func credential(from data: Data, now: Date = Date(),
                           previous: ManagedToolCredential? = nil) throws -> ManagedToolCredential {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = try? ToolConnectionService.secret(object["access_token"] as? String) else {
            throw ClaudeLoginError.exchangeFailed
        }
        let refresh = try ToolConnectionService.secret(object["refresh_token"] as? String) ?? previous?.oauthRefreshToken
        let expires = (object["expires_in"] as? NSNumber).flatMap { value -> Date? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue > 0 else { return nil }
            return now.addingTimeInterval(value.doubleValue)
        }
        let scopes = (object["scope"] as? String).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        return ManagedToolCredential(oauthToken: token, oauthRefreshToken: refresh,
            oauthExpiresAt: expires, oauthScopes: scopes ?? previous?.oauthScopes)
    }

    static func accessToken(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw ClaudeLoginError.exchangeFailed
        }
        return token
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class AccountBrowserLoginCoordinator: ObservableObject {
    static let shared = AccountBrowserLoginCoordinator()
    static let windowID = "add-browser-account"

    @Published private(set) var kind: AccountBrowserLoginKind?
    @Published private(set) var phase: AccountBrowserLoginPhase = .idle
    @Published private(set) var message = ""

    private var connections: ToolConnectionStore?
    private var cursorAccounts: CursorAccountStore?
    private var preferences = ApplicationPreferences()
    private var task: Task<Void, Never>?
    private var claudeTimeoutTask: Task<Void, Never>?
    private let transport: any CursorUsageHTTPTransport
    private let openURL: @MainActor (URL) -> Void
    private let claudeTimeout: Duration
    private var callbackServer: LocalhostOAuthCallbackServer?
    private var claudeSession: ClaudeOAuthSession?
    private var generation = 0

    init(transport: any CursorUsageHTTPTransport = CursorUsageURLSessionTransport(),
         openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
         claudeTimeout: Duration = .seconds(300)) {
        self.transport = transport
        self.openURL = openURL
        self.claudeTimeout = claudeTimeout
    }

    var canSubmitClaudeCallback: Bool {
        self.kind == .claude && self.claudeSession != nil && (self.phase == .waiting || self.phase == .failed)
    }

    func submitClaudeCallback(_ raw: String) async {
        guard self.canSubmitClaudeCallback, let store = self.connections else { return }
        await self.completeClaude(callbackURL: raw, store: store, generation: self.generation)
    }

    func reopenClaudeAuthorization() {
        guard self.canSubmitClaudeCallback, let session = self.claudeSession else { return }
        guard self.callbackServer != nil else { self.retry(); return }
        self.openURL(session.authorizationURL)
    }

    func openClaudeManualAuthorization() {
        guard self.canSubmitClaudeCallback, let session = self.claudeSession,
              let url = ClaudeOAuth.manualAuthorizationURL(session: session) else { return }
        self.openURL(url)
    }

    func start(
        _ kind: AccountBrowserLoginKind,
        connections: ToolConnectionStore,
        cursorAccounts: CursorAccountStore,
        preferences: ApplicationPreferences
    ) {
        self.stop()
        self.generation += 1
        let generation = self.generation
        self.kind = kind
        self.connections = connections
        self.cursorAccounts = cursorAccounts
        self.preferences = preferences
        self.phase = .checking
        self.message = L.zh ? "正在检查本机登录…" : "Checking for a local sign-in…"
        self.task = Task { [weak self] in
            guard let self, generation == self.generation else { return }
            await self.run(kind)
        }
    }

    func retry() {
        guard let kind = self.kind, let connections = self.connections, let cursorAccounts = self.cursorAccounts else { return }
        self.start(kind, connections: connections, cursorAccounts: cursorAccounts, preferences: self.preferences)
    }

    func openManualForm() {
        guard let kind = self.kind, let connections = self.connections, let cursorAccounts = self.cursorAccounts else { return }
        self.stop()
        DetachedWindowPresenter.shared.close(id: Self.windowID)
        ManagedToolAccountsView.presentDetachedAccountForm(
            client: kind.client, cursorAccounts: cursorAccounts, connections: connections
        )
    }

    func stop() {
        self.generation += 1
        self.task?.cancel()
        self.task = nil
        self.claudeTimeoutTask?.cancel()
        self.claudeTimeoutTask = nil
        self.callbackServer?.stop()
        self.callbackServer = nil
        self.claudeSession = nil
        self.kind = nil
        self.connections = nil
        self.cursorAccounts = nil
        self.phase = .idle
    }

    private func run(_ kind: AccountBrowserLoginKind) async {
        switch kind {
        case .claude: await self.runClaude()
        case .cursor: await self.runCursor()
        case .openCode, .deepSeek: await self.runLocalImport(kind)
        }
    }

    private func runClaude() async {
        let generation = self.generation
        guard let connections = self.connections else { return }
        if connections.profiles(for: .claudeCode).isEmpty {
            await connections.discover(client: .claudeCode, preferences: self.preferences)
            if Task.isCancelled || generation != self.generation { return }
            if !connections.profiles(for: .claudeCode).isEmpty {
                for profile in connections.profiles(for: .claudeCode) where profile.isEnabled {
                    await connections.refresh(profileID: profile.id, force: true)
                }
                guard !Task.isCancelled, generation == self.generation else { return }
                if connections.profiles(for: .claudeCode).contains(where: {
                    $0.accountIdentity != nil && connections.quota(for: $0.id)?.status == .ready
                }) {
                    self.finishSaved(L.zh ? "已验证并保存本机 Claude 登录。" : "Verified and saved the local Claude sign-in.", generation: generation)
                    return
                }
            }
        }
        guard generation == self.generation else { return }
        self.beginClaudeOAuth(store: connections)
    }

    private func beginClaudeOAuth(store: ToolConnectionStore) {
        self.callbackServer?.stop()
        let generation = self.generation
        var started: LocalhostOAuthCallbackServer?
        var activeSession: ClaudeOAuthSession?
        for candidate in UInt16(53621)...UInt16(53640) {
            guard let session = try? ClaudeOAuth.makeSession(port: candidate) else { continue }
            let server = LocalhostOAuthCallbackServer(port: candidate, callbackPath: "/callback",
                acceptsCallback: { callback in
                    do { _ = try ClaudeOAuth.authorizationCode(callbackURL: callback, session: session); return true }
                    catch ClaudeLoginError.denied { return true }
                    catch { return false }
                }) { [weak self] callbackURL in
                guard let self else { return }
                Task { await self.completeClaude(callbackURL: callbackURL, store: store, generation: generation) }
            }
            if (try? server.start()) != nil {
                started = server
                activeSession = session
                break
            }
        }
        guard let started, let session = activeSession else {
            self.fail(L.zh ? "本机登录回调端口被占用。" : "The local login callback port is busy.", generation: generation)
            return
        }
        self.callbackServer = started
        self.claudeSession = session
        self.phase = .waiting
        self.message = AccountBrowserLoginKind.claude.waitingMessage
        self.openURL(session.authorizationURL)
        self.claudeTimeoutTask?.cancel()
        let timeout = self.claudeTimeout
        self.claudeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.generation == generation, self.phase == .waiting else { return }
            self.callbackServer?.stop()
            self.callbackServer = nil
            self.fail(L.zh ? "等待登录回调超时。可打开手动授权页并粘贴完整授权码，或重试。"
                : "The login callback timed out. Open manual authorization and paste its full code, or retry.", generation: generation)
        }
    }

    private func completeClaude(callbackURL: String, store: ToolConnectionStore, generation: Int) async {
        guard generation == self.generation, let session = self.claudeSession,
              self.phase == .waiting || self.phase == .failed else { return }
        do {
            let authorization = try ClaudeOAuth.authorizationResponse(callbackURL, session: session)
            self.phase = .saving
            self.message = L.zh ? "正在验证并保存 Claude 登录…" : "Verifying and saving the Claude sign-in…"
            self.claudeSession = nil
            self.claudeTimeoutTask?.cancel()
            self.callbackServer?.stop()
            self.callbackServer = nil
            let request = try ClaudeOAuth.tokenRequest(code: authorization.code, session: session, manual: authorization.manual)
            let (data, http) = try await self.transport.data(for: request, limit: 1024 * 1024)
            guard !Task.isCancelled else { return }
            guard data.count <= 1024 * 1024, http.url == URL(string: ClaudeOAuth.tokenURL),
                  (200..<300).contains(http.statusCode) else {
                throw ClaudeLoginError.exchangeFailed
            }
            let credential = try ClaudeOAuth.credential(from: data)
            guard generation == self.generation else { return }
            try await store.saveClaudeOAuth(credential: credential, shouldCommit: { [weak self] in
                self?.generation == generation
            })
            self.finishSaved(L.zh ? "Claude 账号已保存。" : "Claude account saved.", generation: generation)
        } catch {
            self.fail((error as? LocalizedError)?.errorDescription ?? ClaudeLoginError.exchangeFailed.localizedDescription, generation: generation)
        }
    }

    private func runCursor() async {
        let generation = self.generation
        guard let cursorAccounts = self.cursorAccounts else { return }
        let before = Set(cursorAccounts.accounts.map(\.id))
        await cursorAccounts.discoverDesktopAccount(force: true)
        if Task.isCancelled { return }
        if cursorAccounts.accounts.contains(where: { !before.contains($0.id) }) {
            self.finishSaved(L.zh ? "已保存本机 Cursor 登录。" : "Saved the local Cursor sign-in.", generation: generation)
            return
        }
        guard let url = AccountBrowserLoginKind.cursor.pageURL else { return }
        let baseline = self.cursorFingerprint()
        self.phase = .waiting
        self.message = AccountBrowserLoginKind.cursor.waitingMessage
        NSWorkspace.shared.open(url)
        let changed = await self.poll { self.cursorFingerprint() != baseline }
        if Task.isCancelled || self.kind != .cursor { return }
        guard changed else {
            self.fail(L.zh ? "还没有看到新的 Cursor 本机登录。" : "No new local Cursor sign-in appeared.", generation: generation)
            return
        }
        await cursorAccounts.discoverDesktopAccount(force: true)
        self.finishSaved(L.zh ? "Cursor 账号已保存。" : "Cursor account saved.", generation: generation)
    }

    private func runLocalImport(_ kind: AccountBrowserLoginKind) async {
        let generation = self.generation
        guard let connections = self.connections, let url = kind.pageURL else { return }
        let client = kind.client
        let before = self.fingerprints(client)
        await connections.discover(client: client, preferences: self.preferences)
        if Task.isCancelled { return }
        if !self.fingerprints(client).subtracting(before).isEmpty {
            self.finishSaved(L.zh ? "已保存本机登录。" : "Saved the local sign-in.", generation: generation)
            return
        }
        let baseline = self.fingerprints(client)
        self.phase = .waiting
        self.message = kind.waitingMessage
        NSWorkspace.shared.open(url)
        var changed = false
        for _ in 0..<40 {
            if Task.isCancelled || self.kind != kind { return }
            await connections.discover(client: client, preferences: self.preferences)
            if !self.fingerprints(client).subtracting(baseline).isEmpty {
                changed = true
                break
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        if Task.isCancelled || self.kind != kind { return }
        guard changed else {
            self.fail(L.zh ? "还没有看到新的本机登录。" : "No new local sign-in appeared.", generation: generation)
            return
        }
        self.finishSaved(L.zh ? "账号已保存。" : "Account saved.", generation: generation)
    }

    private func fingerprints(_ client: ToolUsageClient) -> Set<String> {
        Set((self.connections?.profiles(for: client) ?? []).map { $0.credentialFingerprint ?? $0.id })
    }

    private func cursorFingerprint() -> String? {
        let root = self.preferences.dataDirectory(for: "cursor")
        let reader = root.map { CursorDesktopSessionReader(databaseURL: $0.appendingPathComponent("state.vscdb")) }
            ?? CursorDesktopSessionReader()
        guard let cookie = try? reader.sessionCookie() else { return nil }
        return SHA256.hash(data: Data(cookie.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func poll(_ changed: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if Task.isCancelled { return false }
            if changed() { return true }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return !Task.isCancelled && changed()
    }

    private func finishSaved(_ text: String, generation: Int) {
        guard generation == self.generation, !Task.isCancelled else { return }
        self.phase = .saved
        self.message = text
        self.callbackServer?.stop()
        self.callbackServer = nil
        self.claudeSession = nil
        self.claudeTimeoutTask?.cancel()
        self.claudeTimeoutTask = nil
        DetachedWindowPresenter.shared.close(id: Self.windowID)
    }

    private func fail(_ text: String, generation: Int) {
        guard generation == self.generation, !Task.isCancelled else { return }
        self.phase = .failed
        self.message = text
    }
}

struct AccountBrowserLoginSheet: View {
    @ObservedObject var coordinator: AccountBrowserLoginCoordinator
    let onClose: () -> Void
    @State private var callbackInput = ""

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(self.coordinator.kind?.title ?? (L.zh ? "添加账号" : "Add account"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L.cancel) {
                    self.coordinator.stop()
                    self.onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(alignment: .top, spacing: 10) {
                if self.coordinator.phase == .checking || self.coordinator.phase == .waiting || self.coordinator.phase == .saving {
                    ProgressView().controlSize(.small)
                }
                Text(self.coordinator.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.coordinator.canSubmitClaudeCallback {
                Divider()
                Text(L.zh ? "浏览器没有自动返回？" : "Browser did not return automatically?")
                    .font(.system(size: 12, weight: .medium))
                HStack {
                    Button(L.zh ? "重新打开登录页" : "Reopen sign-in") {
                        self.coordinator.reopenClaudeAuthorization()
                    }
                    Button(L.zh ? "获取可粘贴的授权码" : "Get a code to paste") {
                        self.coordinator.openClaudeManualAuthorization()
                    }
                }
                .controlSize(.small)
                SecureField(L.zh ? "粘贴授权码或完整回调地址" : "Paste authorization code or callback URL",
                    text: self.$callbackInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("codexbar.claude-login.callback")
                Text(L.zh ? "授权码来自本次浏览器登录页面；这里不用填写邮箱、密码或 API Key。"
                     : "Use the code from this sign-in. This field does not accept an email, password or API key.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L.zh ? "完成登录" : "Complete sign-in") {
                    let input = self.callbackInput
                    self.callbackInput = ""
                    Task { await self.coordinator.submitClaudeCallback(input) }
                }
                .disabled(self.callbackInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("codexbar.claude-login.complete")
            }
            if self.coordinator.phase == .failed {
                HStack {
                    Button(L.zh ? "重试" : "Retry") { self.coordinator.retry() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            if self.coordinator.kind != nil && self.coordinator.phase != .saving && self.coordinator.phase != .saved {
                Divider()
                Button(L.zh ? "使用已有登录凭据…" : "Use existing credentials…") {
                    self.callbackInput = ""
                    self.coordinator.openManualForm()
                }
                .controlSize(.small)
                .accessibilityIdentifier("codexbar.account-login.existing-credential")
            }
            Spacer(minLength: 0)
          }
          .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(SettingsPalette.foreground)
        .background(SettingsPalette.canvas)
        .preferredColorScheme(SettingsPalette.colorScheme)
        .onDisappear { self.callbackInput = "" }
    }
}
