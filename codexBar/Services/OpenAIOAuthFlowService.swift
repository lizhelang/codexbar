import Foundation

struct PendingOAuthFlow: Codable, Equatable {
    let flowID: String
    let codeVerifier: String
    let expectedState: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case flowID = "flow_id"
        case codeVerifier = "code_verifier"
        case expectedState = "expected_state"
        case createdAt = "created_at"
    }
}

struct StartedOpenAIOAuthFlow: Codable, Equatable {
    let flowID: String
    let authURL: String

    enum CodingKeys: String, CodingKey {
        case flowID = "flow_id"
        case authURL = "auth_url"
    }
}

struct CompletedOpenAIOAuthFlow {
    let flowID: String
    let account: TokenAccount
    let active: Bool
    let synchronized: Bool
}

enum OpenAIOAuthError: LocalizedError {
    case invalidURL
    case noToken
    case invalidCallback
    case noPendingFlow
    case flowNotFound(String)
    case serverError(String)

    var isTerminalAuthFailure: Bool {
        guard case .serverError(let message) = self else { return false }
        let code = message
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return code == "invalid_grant" || code == "unauthorized_client"
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的授权 URL"
        case .noToken: return "未获取到 Token"
        case .invalidCallback: return "无法从回调链接中解析 code"
        case .noPendingFlow: return "当前没有待完成的登录流程，请重新发起登录"
        case .flowNotFound(let flowID): return "未找到待完成的登录流程: \(flowID)"
        case .serverError(let message): return "授权失败: \(message)"
        }
    }
}

struct OpenAIOAuthFlowStore {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL = CodexPaths.oauthFlowsDirectoryURL) {
        self.directoryURL = directoryURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func save(_ flow: PendingOAuthFlow) throws {
        try CodexPaths.ensureDirectories()
        let data = try self.encoder.encode(flow)
        try CodexPaths.writeSecureFile(data, to: self.url(for: flow.flowID))
    }

    func load(flowID: String) throws -> PendingOAuthFlow {
        let url = self.url(for: flowID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OpenAIOAuthError.flowNotFound(flowID)
        }
        let data = try Data(contentsOf: url)
        return try self.decoder.decode(PendingOAuthFlow.self, from: data)
    }

    func remove(flowID: String) throws {
        let url = self.url(for: flowID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func cleanupExpiredFlows(olderThan maxAge: TimeInterval, now: Date = Date()) throws -> [String] {
        try CodexPaths.ensureDirectories()

        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: self.directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var removed: [String] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let flow = try? self.decoder.decode(PendingOAuthFlow.self, from: data) else {
                try? fileManager.removeItem(at: url)
                continue
            }

            if now.timeIntervalSince(flow.createdAt) > maxAge {
                try? fileManager.removeItem(at: url)
                removed.append(flow.flowID)
            }
        }
        return removed
    }

    private func url(for flowID: String) -> URL {
        self.directoryURL.appendingPathComponent("\(flowID).json")
    }
}

struct OpenAIOAuthFlowService {
    private let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let redirectURI = "http://localhost:1455/auth/callback"
    private let authURL = "https://auth.openai.com/oauth/authorize"
    private let tokenURL = "https://auth.openai.com/oauth/token"
    private let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    private let accountService: CodexBarOAuthAccountService
    private let flowStore: OpenAIOAuthFlowStore
    private let session: URLSession
    private let now: () -> Date

    init(
        accountService: CodexBarOAuthAccountService = CodexBarOAuthAccountService(),
        flowStore: OpenAIOAuthFlowStore = OpenAIOAuthFlowStore(),
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.accountService = accountService
        self.flowStore = flowStore
        self.session = session
        self.now = now
    }

    func startFlow() throws -> StartedOpenAIOAuthFlow {
        _ = try self.flowStore.cleanupExpiredFlows(olderThan: 24 * 60 * 60, now: self.now())

        let flow = PendingOAuthFlow(
            flowID: UUID().uuidString.lowercased(),
            codeVerifier: self.generateCodeVerifier(),
            expectedState: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            createdAt: self.now()
        )
        try self.flowStore.save(flow)

        let authURL = try RustPortableCoreAdapter.shared.buildOAuthAuthorizationUrl(
            PortableCoreOAuthAuthorizationUrlRequest(
                authUrl: self.authURL,
                clientId: self.clientId,
                redirectUri: self.redirectURI,
                scope: self.scope,
                codeVerifier: flow.codeVerifier,
                expectedState: flow.expectedState,
                originator: "Codex Desktop"
            ),
            buildIfNeeded: false
        )
        return StartedOpenAIOAuthFlow(flowID: flow.flowID, authURL: authURL.authUrl)
    }

    func completeFlow(
        flowID: String,
        callbackInput: String,
        activate: Bool
    ) async throws -> CompletedOpenAIOAuthFlow {
        let fallback = self.parseManualInput(callbackInput)
        let parsed = (try? RustPortableCoreAdapter.shared.interpretOAuthCallback(
            PortableCoreOAuthCallbackInterpretationRequest(
                callbackInput: callbackInput,
                code: nil,
                returnedState: nil,
                expectedState: ""
            ),
            buildIfNeeded: false
        ))
        return try await self.completeFlow(
            flowID: flowID,
            callbackURL: nil,
            code: parsed?.code ?? fallback.code,
            returnedState: parsed?.returnedState ?? fallback.state,
            activate: activate
        )
    }

    func completeFlow(
        flowID: String,
        callbackURL: String? = nil,
        code: String? = nil,
        returnedState: String? = nil,
        activate: Bool
    ) async throws -> CompletedOpenAIOAuthFlow {
        let flow = try self.flowStore.load(flowID: flowID)

        let parsed: (code: String?, state: String?)
        if let callbackURL, callbackURL.isEmpty == false {
            if let interpreted = try? RustPortableCoreAdapter.shared.interpretOAuthCallback(
                PortableCoreOAuthCallbackInterpretationRequest(
                    callbackInput: callbackURL,
                    code: nil,
                    returnedState: nil,
                    expectedState: flow.expectedState
                ),
                buildIfNeeded: false
            ) {
                parsed = (interpreted.code, interpreted.returnedState)
            } else {
                parsed = self.parseManualInput(callbackURL)
            }
        } else {
            parsed = (code?.trimmingCharacters(in: .whitespacesAndNewlines), returnedState)
        }

        guard let code = parsed.code, code.isEmpty == false else {
            throw OpenAIOAuthError.invalidCallback
        }

        if let returnedState = parsed.state,
           returnedState != flow.expectedState {
            NSLog(
                "codexbar OAuth state mismatch on completion: expected=%@ returned=%@; attempting PKCE exchange anyway",
                flow.expectedState,
                returnedState
            )
        }

        let tokens = try await self.exchangeCode(code, flow: flow)
        let account = AccountBuilder.build(from: tokens)
        let importResult = try self.accountService.importAccount(account, activate: activate)
        try self.flowStore.remove(flowID: flow.flowID)

        return CompletedOpenAIOAuthFlow(
            flowID: flow.flowID,
            account: importResult.account,
            active: importResult.active,
            synchronized: importResult.synchronized
        )
    }

    func cancelFlow(flowID: String) throws {
        try self.flowStore.remove(flowID: flowID)
    }

    func cleanupExpiredFlows(maxAge: TimeInterval = 24 * 60 * 60) throws -> [String] {
        try self.flowStore.cleanupExpiredFlows(olderThan: maxAge, now: self.now())
    }

    func refreshAccount(_ account: TokenAccount) async throws -> TokenAccount {
        let clientID = account.oauthClientID ?? self.clientId
        let tokens = try await self.exchangeRefreshToken(
            refreshToken: account.refreshToken,
            currentIDToken: account.idToken,
            currentRefreshToken: account.refreshToken,
            clientID: clientID
        )
        var refreshed = AccountBuilder.build(from: tokens)
        refreshed.accountId = account.accountId
        refreshed.openAIAccountId = account.remoteAccountId
        refreshed.email = refreshed.email.isEmpty ? account.email : refreshed.email
        refreshed.planType = refreshed.planType == "free" ? account.planType : refreshed.planType
        refreshed.primaryUsedPercent = account.primaryUsedPercent
        refreshed.secondaryUsedPercent = account.secondaryUsedPercent
        refreshed.primaryResetAt = account.primaryResetAt
        refreshed.secondaryResetAt = account.secondaryResetAt
        refreshed.primaryLimitWindowSeconds = account.primaryLimitWindowSeconds
        refreshed.secondaryLimitWindowSeconds = account.secondaryLimitWindowSeconds
        refreshed.lastChecked = account.lastChecked
        refreshed.isActive = account.isActive
        refreshed.isSuspended = false
        refreshed.tokenExpired = false
        refreshed.organizationName = account.organizationName
        return refreshed
    }

    private func exchangeCode(_ code: String, flow: PendingOAuthFlow) async throws -> OAuthTokens {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": self.clientId,
            "code": code,
            "redirect_uri": self.redirectURI,
            "code_verifier": flow.codeVerifier,
        ]
        return try await self.performTokenRequest(
            body: body,
            fallbackRefreshToken: nil,
            fallbackIDToken: nil,
            fallbackClientID: self.clientId
        )
    }

    private func exchangeRefreshToken(
        refreshToken: String,
        currentIDToken: String,
        currentRefreshToken: String,
        clientID: String
    ) async throws -> OAuthTokens {
        try await self.performTokenRequest(
            body: [
                "grant_type": "refresh_token",
                "client_id": clientID,
                "refresh_token": refreshToken,
            ],
            fallbackRefreshToken: currentRefreshToken,
            fallbackIDToken: currentIDToken,
            fallbackClientID: clientID
        )
    }

    private func performTokenRequest(
        body: [String: String],
        fallbackRefreshToken: String?,
        fallbackIDToken: String?,
        fallbackClientID: String?
    ) async throws -> OAuthTokens {
        guard let url = URL(string: self.tokenURL) else {
            throw OpenAIOAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        request.httpBody = body
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await self.session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIOAuthError.noToken
        }
        if let error = json["error"] as? String {
            let description = json["error_description"] as? String ?? ""
            throw OpenAIOAuthError.serverError("\(error): \(description)")
        }

        guard let accessToken = json["access_token"] as? String else {
            throw OpenAIOAuthError.noToken
        }
        let resolvedRefreshToken = (json["refresh_token"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? fallbackRefreshToken
        let resolvedIDToken = (json["id_token"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? fallbackIDToken

        guard let refreshToken = resolvedRefreshToken,
              let idToken = resolvedIDToken else {
            throw OpenAIOAuthError.noToken
        }

        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            oauthClientID: (json["client_id"] as? String) ?? fallbackClientID,
            tokenLastRefreshAt: self.now()
        )
    }

    private func parseManualInput(_ input: String) -> (code: String?, state: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value
            if code != nil || state != nil {
                return (code, state)
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"[?&]code=([^&]+)"#),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let codeRange = Range(match.range(at: 1), in: trimmed) {
            let stateRegex = try? NSRegularExpression(pattern: #"[?&]state=([^&]+)"#)
            var state: String?
            if let stateRegex,
               let stateMatch = stateRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let stateRange = Range(stateMatch.range(at: 1), in: trimmed) {
                state = String(trimmed[stateRange]).removingPercentEncoding
            }
            return (String(trimmed[codeRange]).removingPercentEncoding, state)
        }

        return (trimmed, nil)
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
