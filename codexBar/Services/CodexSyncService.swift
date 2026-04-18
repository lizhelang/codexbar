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

    var errorDescription: String? {
        switch self {
        case .missingActiveProvider: return "未找到当前激活的 provider"
        case .missingActiveAccount: return "未找到当前激活的账号"
        case .missingOAuthTokens: return "当前 OAuth 账号缺少必要 token"
        case .missingAPIKey: return "当前 API Key 账号缺少密钥"
        case .missingOpenRouterModel: return "OpenRouter 需要先选择或输入模型 ID"
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
        guard let provider = config.activeProvider() else { throw CodexSyncError.missingActiveProvider }
        guard let account = config.activeAccount() else { throw CodexSyncError.missingActiveAccount }

        let previousAuthData = self.readData(CodexPaths.authURL)
        let previousTomlData = self.readData(CodexPaths.configTomlURL)
        let existingTomlText = self.readString(CodexPaths.configTomlURL) ?? ""

        try self.ensureDirectories()
        try self.backupFileIfPresent(CodexPaths.configTomlURL, CodexPaths.configBackupURL)
        try self.backupFileIfPresent(CodexPaths.authURL, CodexPaths.authBackupURL)

        let effectiveModel: String
        switch provider.kind {
        case .openRouter:
            guard let selectedModelID = provider.openRouterEffectiveModelID else {
                throw CodexSyncError.missingOpenRouterModel
            }
            effectiveModel = selectedModelID
        case .openAIOAuth, .openAICompatible:
            effectiveModel = config.global.defaultModel
        }

        let authData = try self.renderAuthJSON(config: config, provider: provider, account: account)
        let renderedToml = self.renderConfigTOML(
            config: config,
            existingText: existingTomlText,
            global: config.global,
            provider: provider,
            effectiveModel: effectiveModel
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
        config: CodexBarConfig,
        provider: CodexBarProvider,
        account: CodexBarProviderAccount
    ) throws -> Data {
        let object: [String: Any]
        switch provider.kind {
        case .openAIOAuth:
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
            object = authObject

        case .openAICompatible:
            guard let apiKey = account.apiKey, apiKey.isEmpty == false else {
                throw CodexSyncError.missingAPIKey
            }
            object = [
                "OPENAI_API_KEY": apiKey,
            ]
        case .openRouter:
            guard account.apiKey?.isEmpty == false else {
                throw CodexSyncError.missingAPIKey
            }
            object = [
                "OPENAI_API_KEY": OpenRouterGatewayConfiguration.apiKey,
            ]
        }

        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func renderConfigTOML(
        config: CodexBarConfig,
        existingText: String,
        global: CodexBarGlobalSettings,
        provider: CodexBarProvider,
        effectiveModel: String
    ) -> String {
        var text = existingText
        let modelProviderValue = "\"openai\""

        text = self.upsertSetting(text, key: "model_provider", value: modelProviderValue)
        text = self.upsertSetting(text, key: "model", value: self.quote(effectiveModel))
        text = self.upsertSetting(text, key: "review_model", value: self.quote(provider.kind == .openRouter ? effectiveModel : global.reviewModel))
        text = self.upsertSetting(text, key: "model_reasoning_effort", value: self.quote(global.reasoningEffort))

        // Preserve native OpenAI speed tiers so Codex fast/flex modes survive account sync.
        if provider.kind != .openAIOAuth {
            text = self.removeSetting(text, key: "service_tier")
        }
        text = self.removeSetting(text, key: "oss_provider")
        text = self.removeSetting(text, key: "openai_base_url")
        text = self.removeSetting(text, key: "model_catalog_json")
        text = self.removeSetting(text, key: "preferred_auth_method")
        text = self.removeBlock(text, key: "OpenAI")
        text = self.removeBlock(text, key: "openai")

        if provider.kind == .openAIOAuth,
           config.openAI.accountUsageMode == .aggregateGateway {
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
        } else if provider.kind == .openAICompatible, let baseURL = provider.baseURL {
            text = self.upsertSetting(text, key: "openai_base_url", value: self.quote(baseURL))
        }

        return text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
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
