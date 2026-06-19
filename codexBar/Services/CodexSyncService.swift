import Foundation

protocol CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws
}

enum CodexSyncError: LocalizedError {
    case missingActiveProvider
    case missingActiveAccount
    case missingOAuthTokens
    case missingAPIKey
    case missingOpenRouterModel
    case missingRemoteConnectionAccount
    case missingRequestTarget

    var errorDescription: String? {
        switch self {
        case .missingActiveProvider: return "未找到当前激活的 provider"
        case .missingActiveAccount: return "未找到当前激活的账号"
        case .missingOAuthTokens: return "当前 OAuth 账号缺少必要 token"
        case .missingAPIKey: return "当前 API Key 账号缺少密钥"
        case .missingOpenRouterModel: return "OpenRouter 需要先选择或输入模型 ID"
        case .missingRemoteConnectionAccount: return "未找到 OAuth 登录身份"
        case .missingRequestTarget: return "需要先选择请求目标"
        }
    }
}

struct CodexSyncService: CodexSynchronizing {
    private let ensureDirectories: () throws -> Void
    private let backupFileIfPresent: (URL, URL) throws -> Void
    private let writeSecureFile: (Data, URL) throws -> Void
    private let readString: (URL) -> String?
    private let readData: (URL) -> Data?
    private let fileExists: (URL) -> Bool
    private let removeFileIfPresent: (URL) throws -> Void
    private static let remoteConnectionProviderName = "CodexbarRemote"

    init(
        ensureDirectories: @escaping () throws -> Void = { try CodexPaths.ensureDirectories() },
        backupFileIfPresent: @escaping (URL, URL) throws -> Void = { source, destination in
            try CodexPaths.backupFileIfPresent(from: source, to: destination)
        },
        writeSecureFile: @escaping (Data, URL) throws -> Void = { data, url in
            try CodexPaths.writeSecureFile(data, to: url)
        },
        readString: @escaping (URL) -> String? = { url in
            try? String(contentsOf: url, encoding: .utf8)
        },
        readData: @escaping (URL) -> Data? = { url in
            try? Data(contentsOf: url)
        },
        fileExists: @escaping (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        removeFileIfPresent: @escaping (URL) throws -> Void = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    ) {
        self.ensureDirectories = ensureDirectories
        self.backupFileIfPresent = backupFileIfPresent
        self.writeSecureFile = writeSecureFile
        self.readString = readString
        self.readData = readData
        self.fileExists = fileExists
        self.removeFileIfPresent = removeFileIfPresent
    }

    func synchronize(config: CodexBarConfig) throws {
        let route = try CodexRouteResolver.resolve(config: config)

        let previousAuthData = self.readData(CodexPaths.authURL)
        let previousTomlData = self.readData(CodexPaths.configTomlURL)
        let existingTomlText = self.readString(CodexPaths.configTomlURL) ?? ""

        try self.ensureDirectories()
        try self.backupFileIfPresent(CodexPaths.configTomlURL, CodexPaths.configBackupURL)
        try self.backupFileIfPresent(CodexPaths.authURL, CodexPaths.authBackupURL)

        let authData = try self.renderAuthJSON(route: route)
        let renderedToml = self.renderConfigTOML(
            config: config,
            existingText: existingTomlText,
            global: config.global,
            route: route
        )
        guard let tomlData = renderedToml.data(using: .utf8) else { return }

        do {
            try self.writeSecureFile(authData, CodexPaths.authURL)
            try self.writeSecureFile(tomlData, CodexPaths.configTomlURL)
        } catch {
            try? self.restoreSnapshot(previousAuthData, at: CodexPaths.authURL)
            try? self.restoreSnapshot(previousTomlData, at: CodexPaths.configTomlURL)
            throw error
        }
    }

    private func restoreSnapshot(_ snapshot: Data?, at url: URL) throws {
        if let snapshot {
            try self.writeSecureFile(snapshot, url)
        } else if self.fileExists(url) {
            try self.removeFileIfPresent(url)
        }
    }

    private func renderAuthJSON(
        route: ResolvedCodexRoute
    ) throws -> Data {
        let object: [String: Any]
        if route.requiresOpenAIAuth {
            object = try self.renderOAuthAuthObject(account: route.authAccount)
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }

        switch route.authProvider.kind {
        case .openAIOAuth:
            object = try self.renderOAuthAuthObject(account: route.authAccount)

        case .openAICompatible:
            guard let apiKey = route.authAccount.apiKey, apiKey.isEmpty == false else {
                throw CodexSyncError.missingAPIKey
            }
            object = [
                "OPENAI_API_KEY": apiKey,
            ]
        case .openRouter:
            guard route.authAccount.apiKey?.isEmpty == false else {
                throw CodexSyncError.missingAPIKey
            }
            object = [
                "OPENAI_API_KEY": OpenRouterGatewayConfiguration.apiKey,
            ]
        }

        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func renderOAuthAuthObject(account: CodexBarProviderAccount) throws -> [String: Any] {
        guard let accessToken = account.accessToken,
              let refreshToken = account.refreshToken,
              let idToken = account.idToken,
              let accountId = account.openAIAccountId else {
            throw CodexSyncError.missingOAuthTokens
        }

        var authObject: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "last_refresh": ISO8601DateFormatter().string(from: account.tokenLastRefreshAt ?? account.lastRefresh ?? Date()),
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "id_token": idToken,
                "account_id": accountId,
            ],
        ]
        if let clientID = account.oauthClientID, clientID.isEmpty == false {
            authObject["client_id"] = clientID
        }
        return authObject
    }

    private func renderConfigTOML(
        config: CodexBarConfig,
        existingText: String,
        global: CodexBarGlobalSettings,
        route: ResolvedCodexRoute
    ) -> String {
        var text = existingText
        let provider = route.targetProvider
        let usesRemoteConnectionProvider = route.requiresOpenAIAuth
        let modelProviderName = usesRemoteConnectionProvider
            ? Self.remoteConnectionProviderName
            : "openai"
        let modelProviderValue = self.quote(modelProviderName)

        text = self.upsertSetting(text, key: "model_provider", value: modelProviderValue)
        text = self.upsertSetting(text, key: "model", value: self.quote(route.effectiveModel))
        text = self.upsertSetting(text, key: "review_model", value: self.quote(provider.kind == .openRouter ? route.effectiveModel : global.reviewModel))
        text = self.upsertSetting(text, key: "model_reasoning_effort", value: self.quote(global.reasoningEffort))

        if provider.kind == .openAIOAuth {
            text = self.upsertSetting(text, key: "service_tier", value: self.quote(global.serviceTier))
        } else {
            text = self.removeSetting(text, key: "service_tier")
        }
        text = self.removeSetting(text, key: "oss_provider")
        text = self.removeSetting(text, key: "openai_base_url")
        text = self.removeSetting(text, key: "model_catalog_json")
        text = self.removeSetting(text, key: "preferred_auth_method")
        text = self.removeBlock(text, key: Self.remoteConnectionProviderName)
        text = self.removeBlock(text, key: "OpenAI")
        text = self.removeBlock(text, key: "openai")

        if usesRemoteConnectionProvider {
            text = self.appendRemoteConnectionProviderBlock(
                to: text,
                provider: provider,
                account: route.targetAccount
            )
        } else {
            if route.routesOpenAITargetThroughGateway {
                text = self.upsertSetting(
                    text,
                    key: "openai_base_url",
                    value: self.quote(OpenAIAccountGatewayConfiguration.baseURLString)
                )
            } else if provider.kind == .openRouter {
                text = self.upsertSetting(
                    text,
                    key: "openai_base_url",
                    value: self.quote(OpenRouterGatewayConfiguration.baseURLString)
                )
            } else if provider.usesChatCompletionsGateway {
                text = self.upsertSetting(
                    text,
                    key: "openai_base_url",
                    value: self.quote(ChatCompletionsGatewayConfiguration.baseURLString)
                )
            } else if provider.kind == .openAICompatible, let baseURL = provider.baseURL {
                text = self.upsertSetting(text, key: "openai_base_url", value: self.quote(baseURL))
            }
        }

        return text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func appendRemoteConnectionProviderBlock(
        to text: String,
        provider: CodexBarProvider,
        account: CodexBarProviderAccount
    ) -> String {
        let baseURL: String?
        let bearerToken: String?
        switch provider.kind {
        case .openAICompatible:
            baseURL = provider.usesChatCompletionsGateway
                ? ChatCompletionsGatewayConfiguration.baseURLString
                : provider.baseURL
            bearerToken = account.apiKey
        case .openRouter:
            baseURL = OpenRouterGatewayConfiguration.baseURLString
            bearerToken = OpenRouterGatewayConfiguration.apiKey
        case .openAIOAuth:
            baseURL = nil
            bearerToken = nil
        }

        guard let trimmedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmedBaseURL.isEmpty == false,
              let trimmedBearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmedBearerToken.isEmpty == false else {
            return text
        }
        let normalizedBaseURL = provider.kind == .openAICompatible
            ? self.normalizedProviderBaseURL(trimmedBaseURL)
            : trimmedBaseURL

        let block = [
            "[model_providers.\(Self.remoteConnectionProviderName)]",
            "name = \(self.quote(Self.remoteConnectionProviderName))",
            "wire_api = \"responses\"",
            "requires_openai_auth = true",
            "base_url = \(self.quote(normalizedBaseURL))",
            "experimental_bearer_token = \(self.quote(trimmedBearerToken))",
        ].joined(separator: "\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n"
    }

    private func normalizedProviderBaseURL(_ baseURL: String) -> String {
        guard baseURL.hasSuffix("/") else { return baseURL }
        return String(baseURL.dropLast())
    }

    private func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func upsertSetting(_ text: String, key: String, value: String) -> String {
        let line = "\(key) = \(value)"
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^#(key)\s*=.*$"#.replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        if regex.firstMatch(in: text, range: range) != nil {
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: line)
        }
        return line + "\n" + text
    }

    private func removeSetting(_ text: String, key: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^#(key)\s*=.*$\n?"#.replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func removeBlock(_ text: String, key: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?ms)^\[model_providers\.#(key)\]\n.*?(?=^\[|\Z)"#.replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
