import Foundation

protocol CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws
    func synchronizeProviderDefinitions(config: CodexBarConfig) throws
}

extension CodexSynchronizing {
    func synchronizeProviderDefinitions(config: CodexBarConfig) throws {}
}

enum CodexSyncError: LocalizedError {
    case missingActiveProvider
    case missingActiveAccount
    case missingOAuthTokens
    case missingAPIKey
    case missingOpenRouterModel
    case missingRemoteConnectionAccount
    case missingRequestTarget
    case missingProviderBaseURL
    case unsafeOpenAIFallback

    var errorDescription: String? {
        switch self {
        case .missingActiveProvider: return "未找到当前激活的 provider"
        case .missingActiveAccount: return "未找到当前激活的账号"
        case .missingOAuthTokens: return "当前 OAuth 账号缺少必要 token"
        case .missingAPIKey: return "当前 API Key 账号缺少密钥"
        case .missingOpenRouterModel: return "OpenRouter 需要先选择或输入模型 ID"
        case .missingRemoteConnectionAccount: return "未找到 OAuth 登录身份"
        case .missingRequestTarget: return "需要先选择请求目标"
        case .missingProviderBaseURL: return "第三方服务需要有效的 HTTP 或 HTTPS API 地址"
        case .unsafeOpenAIFallback: return "无法安全恢复 OpenAI 默认路由：请先登录有效的 OpenAI OAuth 账号"
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
    private let loadServiceTierCatalog: () -> CodexServiceTierCatalog?
    private let webSocketSupportDirective: (CodexBarConfig, ResolvedCodexRoute) -> CodexWebSocketSupportDirective
    private static let remoteConnectionProviderName = "CodexbarRemote"
    private static let managedProviderPrefix = "codexbar."
    private static let openAIBackendBaseURL = "https://chatgpt.com/backend-api/codex"

    static func providerIdentifier(for provider: CodexBarProvider) -> String {
        self.managedProviderPrefix + provider.id
    }

    private static func reserveProviderIdentifier(for provider: CodexBarProvider) -> String {
        self.providerIdentifier(for: provider) + ".reserve"
    }

    private func modelProviderName(
        for route: ResolvedCodexRoute,
        directive: CodexWebSocketSupportDirective?
    ) -> String {
        guard route.targetProvider.kind == .openAIOAuth else {
            return Self.providerIdentifier(for: route.targetProvider)
        }
        if ReserveModelPolicy.isReserve(route.effectiveModel) {
            return Self.reserveProviderIdentifier(for: route.targetProvider)
        }
        return self.usesOpenAIHTTPProvider(route: route, directive: directive)
            ? Self.providerIdentifier(for: route.targetProvider) : "openai"
    }

    private func routesBuiltInOpenAIThroughGateway(config: CodexBarConfig, route: ResolvedCodexRoute) -> Bool {
        if route.targetProvider.kind == .openAIOAuth, ReserveModelPolicy.isReserve(route.effectiveModel) {
            // 普通内置 OpenAI 任务恢复时仍读取根层 URL；Reserve 使用独立 provider，
            // 不改变普通任务原有的聚合或固定身份传输路径。
            return config.openAI.accountUsageMode == .aggregateGateway || config.openAI.remoteConnectionAccountID != nil
        }
        return route.routesOpenAITargetThroughGateway
    }

    private func usesOpenAIHTTPProvider(
        route: ResolvedCodexRoute,
        directive: CodexWebSocketSupportDirective?
    ) -> Bool {
        route.targetProvider.kind == .openAIOAuth &&
            !route.routesOpenAITargetThroughGateway && directive == .write(false)
    }

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
        },
        loadServiceTierCatalog: @escaping () -> CodexServiceTierCatalog? = {
            CodexServiceTierCatalog.load()
        },
        webSocketSupportDirective: @escaping (CodexBarConfig, ResolvedCodexRoute) -> CodexWebSocketSupportDirective = { config, route in
            CodexWebSocketSupportCoordinator.live.directive(for: config, route: route)
        }
    ) {
        self.ensureDirectories = ensureDirectories
        self.backupFileIfPresent = backupFileIfPresent
        self.writeSecureFile = writeSecureFile
        self.readString = readString
        self.readData = readData
        self.fileExists = fileExists
        self.removeFileIfPresent = removeFileIfPresent
        self.loadServiceTierCatalog = loadServiceTierCatalog
        self.webSocketSupportDirective = webSocketSupportDirective
    }

    func synchronize(config: CodexBarConfig) throws {
        let route = try CodexRouteResolver.resolve(config: config)

        let previousAuthData = self.readData(CodexPaths.authURL)
        let previousTomlData = self.readData(CodexPaths.configTomlURL)
        let existingTomlText = self.readString(CodexPaths.configTomlURL) ?? ""

        let authData = try self.renderAuthJSON(route: route)
        let renderedToml = try self.renderConfigTOML(
            config: config,
            existingText: existingTomlText,
            global: config.global,
            route: route
        )
        guard let tomlData = renderedToml.data(using: .utf8) else { return }

        try self.ensureDirectories()
        try self.backupFileIfPresent(CodexPaths.configTomlURL, CodexPaths.configBackupURL)
        if authData != nil {
            try self.backupFileIfPresent(CodexPaths.authURL, CodexPaths.authBackupURL)
        }
        do {
            if let authData {
                try self.writeSecureFile(authData, CodexPaths.authURL)
            }
            try self.writeSecureFile(tomlData, CodexPaths.configTomlURL)
        } catch {
            if authData != nil {
                try? self.restoreSnapshot(previousAuthData, at: CodexPaths.authURL)
            }
            try? self.restoreSnapshot(previousTomlData, at: CodexPaths.configTomlURL)
            throw error
        }
    }

    func synchronizeProviderDefinitions(config: CodexBarConfig) throws {
        let existing = self.readString(CodexPaths.configTomlURL) ?? ""
        let route: ResolvedCodexRoute?
        do {
            route = try CodexRouteResolver.resolve(config: config)
        } catch CodexSyncError.missingActiveProvider where
            config.providers.isEmpty &&
            config.active.providerId == nil &&
            config.active.accountId == nil &&
            config.openAI.hybridTargetSelection == nil {
            // 删除最后一个 provider 后明确没有请求目标；其他解析错误必须原样上报。
            route = nil
        }
        let selected = self.rootSettingValue(existing, key: "model_provider")
        let existingManagedID = selected?.hasPrefix(Self.managedProviderPrefix) == true
            ? String(selected!.dropFirst(Self.managedProviderPrefix.count)) : nil
        let isSelectedReserveAlias = route.map {
            $0.targetProvider.kind == .openAIOAuth && selected == Self.reserveProviderIdentifier(for: $0.targetProvider)
        } ?? false
        if let existingManagedID, existingManagedID != route?.targetProvider.id, !isSelectedReserveAlias {
            if route != nil {
                try self.synchronize(config: config)
                return
            }
        }
        if existingManagedID != nil, route == nil,
           self.hasUsableOpenAIOAuth() == false {
            // auth.json 可能仍是旧版写入的第三方 OPENAI_API_KEY；不能把它用于 OpenAI 内置路由。
            throw CodexSyncError.unsafeOpenAIFallback
        }
        let directive = route.map { self.webSocketSupportDirective(config, $0) }
        var text = try self.renderProviderDefinitions(config: config, route: route, directive: directive, text: existing)
        // 根层键不会被 Codex 读取，清掉历史生成的无效配置。
        text = self.removeSetting(text, key: "supports_websockets")
        if existingManagedID != nil, route == nil {
            // 最后一个第三方服务已删除；清掉失效路由，保留已有 OpenAI 登录。
            text = self.upsertSetting(text, key: "model_provider", value: self.quote("openai"))
            text = self.upsertSetting(text, key: "model", value: self.quote(config.global.defaultModel))
            text = self.upsertSetting(text, key: "review_model", value: self.quote(config.global.reviewModel))
            text = self.removeSetting(text, key: "openai_base_url")
        }
        if let route, route.targetProvider.kind == .openAIOAuth,
           selected == "openai" || selected == Self.providerIdentifier(for: route.targetProvider) || isSelectedReserveAlias {
            let providerName = self.modelProviderName(for: route, directive: directive)
            text = self.upsertSetting(text, key: "model_provider", value: self.quote(providerName))
            if self.routesBuiltInOpenAIThroughGateway(config: config, route: route) {
                text = self.upsertSetting(
                    text,
                    key: "openai_base_url",
                    value: self.quote(OpenAIAccountGatewayConfiguration.baseURLString)
                )
            } else {
                text = self.removeSetting(text, key: "openai_base_url")
            }
        }
        guard text != existing else { return }
        try self.ensureDirectories()
        try self.writeSecureFile(Data(text.utf8), CodexPaths.configTomlURL)
    }

    private func restoreSnapshot(_ snapshot: Data?, at url: URL) throws {
        if let snapshot {
            try self.writeSecureFile(snapshot, url)
        } else if self.fileExists(url) {
            try self.removeFileIfPresent(url)
        }
    }

    private func hasUsableOpenAIOAuth() -> Bool {
        guard let data = self.readData(CodexPaths.authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["auth_mode"] as? String == "chatgpt",
              object["OPENAI_API_KEY"] is NSNull,
              let tokens = object["tokens"] as? [String: Any] else {
            return false
        }
        return ["access_token", "refresh_token", "id_token", "account_id"].allSatisfy { key in
            guard let value = tokens[key] as? String else { return false }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private func renderAuthJSON(
        route: ResolvedCodexRoute
    ) throws -> Data? {
        let object: [String: Any]
        if route.requiresOpenAIAuth {
            object = try self.renderOAuthAuthObject(account: route.authAccount)
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }

        switch route.authProvider.kind {
        case .openAIOAuth:
            object = try self.renderOAuthAuthObject(account: route.authAccount)

        case .openAICompatible, .openRouter:
            // 第三方认证由独立 provider 提供，保留现有 OpenAI 登录和其备份。
            return nil
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
    ) throws -> String {
        var text = existingText
        let provider = route.targetProvider
        let directive = self.webSocketSupportDirective(config, route)
        let usesOpenAIHTTPProvider = self.usesOpenAIHTTPProvider(route: route, directive: directive)
        let modelProviderName = self.modelProviderName(for: route, directive: directive)
        let modelProviderValue = self.quote(modelProviderName)

        text = self.upsertSetting(text, key: "model_provider", value: modelProviderValue)
        text = self.upsertSetting(text, key: "model", value: self.quote(route.effectiveModel))
        let isReserve = provider.kind == .openAIOAuth && ReserveModelPolicy.isReserve(route.effectiveModel)
        let catalog = self.loadServiceTierCatalog()
        let reviewModel = isReserve || provider.kind != .openAIOAuth
            ? route.effectiveModel : global.reviewModel
        let reasoningEffort = isReserve
            ? CodexBarGlobalSettings.compatibleReasoningEffort(global.reasoningEffort, for: route.effectiveModel, catalog: catalog)
            : global.reasoningEffort
        text = self.upsertSetting(text, key: "review_model", value: self.quote(reviewModel))
        text = self.upsertSetting(text, key: "model_reasoning_effort", value: self.quote(reasoningEffort))
        if let contextWindow = global.syncContextWindow(for: route.effectiveModel) {
            text = self.upsertSetting(text, key: "model_context_window", value: "\(contextWindow)")
        } else if isReserve {
            let contextWindow = CodexBarGlobalSettings.defaultContextWindow(for: route.effectiveModel, catalog: catalog)
            text = self.upsertSetting(text, key: "model_context_window", value: "\(contextWindow)")
        } else {
            text = self.removeSetting(text, key: "model_context_window")
        }

        // service_tier 每次同步都对照 Codex 自己的模型目录缓存重新校验：
        // 只写当前模型真正支持的档位，标准档位默认删键，避免把后端已不再接受的值（如 flex）写进去。
        if provider.kind == .openAIOAuth,
           let serviceTier = global.codexConfigServiceTier(
               for: route.effectiveModel,
               catalog: catalog
           ) {
            text = self.upsertSetting(text, key: "service_tier", value: self.quote(serviceTier))
        } else {
            text = self.removeSetting(text, key: "service_tier")
        }
        text = self.removeSetting(text, key: "oss_provider")
        text = self.removeSetting(text, key: "openai_base_url")
        text = self.removeSetting(text, key: "supports_websockets")
        // model_catalog_json 由用户或服务商工具指南管理，可能声明第三方模型的工具能力。
        // 切换路由只更新连接配置，保留目录引用，也不替用户创建目录配置。
        text = self.removeSetting(text, key: "preferred_auth_method")
        text = self.removeBlock(text, key: Self.remoteConnectionProviderName)
        text = self.removeBlock(text, key: "openai")

        if self.routesBuiltInOpenAIThroughGateway(config: config, route: route) &&
            (isReserve || !usesOpenAIHTTPProvider) {
            text = self.upsertSetting(
                text,
                key: "openai_base_url",
                value: self.quote(OpenAIAccountGatewayConfiguration.baseURLString)
            )
        }
        return try self.renderProviderDefinitions(config: config, route: route, directive: directive, text: text)
    }

    private func renderProviderDefinitions(
        config: CodexBarConfig,
        route: ResolvedCodexRoute?,
        directive: CodexWebSocketSupportDirective?,
        text: String
    ) throws -> String {
        var text = self.removeManagedProviderBlocks(text)
        if let oauthProvider = config.oauthProvider() {
            // 旧任务保存普通 provider ID；选择 Reserve 只改变新任务默认配置，
            // 普通别名继续遵循已有的聚合或固定身份模式。
            let usesGateway = config.openAI.accountUsageMode == .aggregateGateway ||
                config.openAI.remoteConnectionAccountID != nil
            text = self.appendOpenAIHTTPProviderBlock(
                to: text,
                providerIdentifier: Self.providerIdentifier(for: oauthProvider),
                usesGateway: usesGateway
            )
            // Reserve 的 HTTP/WebSocket 任务始终使用独立直连别名；切回普通模型后也保留其定义。
            text = self.appendOpenAIHTTPProviderBlock(
                to: text,
                providerIdentifier: Self.reserveProviderIdentifier(for: oauthProvider),
                usesGateway: false,
                supportsWebSockets: directive != .write(false)
            )
        }
        // 全部第三方配置各自保留；删除服务时也移除其生成配置和凭据。
        // 未完成配置的非当前服务不影响正常 OpenAI 路由。
        for savedProvider in config.providers where savedProvider.kind != .openAIOAuth {
            let isSelected = savedProvider.id == route?.targetProvider.id
            guard let account = isSelected ? route?.targetAccount : savedProvider.activeAccount else { continue }
            if isSelected {
                text = try self.appendProviderBlock(to: text, provider: savedProvider, account: account,
                                                    requiresOpenAIAuth: route?.requiresOpenAIAuth == true,
                                                    webSocketSupport: directive)
            } else if savedProvider.enabled,
                      let updated = try? self.appendProviderBlock(to: text, provider: savedProvider, account: account,
                                                                  requiresOpenAIAuth: false) {
                text = updated
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func appendOpenAIHTTPProviderBlock(
        to text: String,
        providerIdentifier: String,
        usesGateway: Bool,
        supportsWebSockets: Bool = false
    ) -> String {
        let baseURL = usesGateway ? OpenAIAccountGatewayConfiguration.baseURLString : Self.openAIBackendBaseURL
        let block = [
            "[model_providers.\(self.quote(providerIdentifier))]",
            "name = \"OpenAI\"",
            "base_url = \(self.quote(baseURL))",
            "wire_api = \"responses\"",
            "requires_openai_auth = true",
            "supports_websockets = \(supportsWebSockets ? "true" : "false")",
            "supports_standalone_web_search = true",
            "env_http_headers = { \"OpenAI-Organization\" = \"OPENAI_ORGANIZATION\", \"OpenAI-Project\" = \"OPENAI_PROJECT\" }",
        ].joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n"
    }

    private func appendProviderBlock(
        to text: String,
        provider: CodexBarProvider,
        account: CodexBarProviderAccount,
        requiresOpenAIAuth: Bool,
        webSocketSupport: CodexWebSocketSupportDirective? = nil
    ) throws -> String {
        guard let apiKey = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              apiKey.isEmpty == false else { throw CodexSyncError.missingAPIKey }
        let baseURL: String?
        let bearerToken: String?
        switch provider.kind {
        case .openAICompatible:
            guard let upstream = provider.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: upstream),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { throw CodexSyncError.missingProviderBaseURL }
            baseURL = provider.usesChatCompletionsGateway
                ? ChatCompletionsGatewayConfiguration.baseURLString
                : upstream
            bearerToken = apiKey
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
            throw CodexSyncError.missingProviderBaseURL
        }
        guard let url = URL(string: trimmedBaseURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw CodexSyncError.missingProviderBaseURL }
        let normalizedBaseURL = provider.kind == .openAICompatible
            ? self.normalizedProviderBaseURL(trimmedBaseURL)
            : trimmedBaseURL

        var lines = [
            "[model_providers.\(self.quote(Self.providerIdentifier(for: provider)))]",
            "name = \(self.quote(provider.label))",
            "wire_api = \"responses\"",
            "requires_openai_auth = \(requiresOpenAIAuth)",
            "base_url = \(self.quote(normalizedBaseURL))",
            "experimental_bearer_token = \(self.quote(trimmedBearerToken))",
        ]
        if case .write(let enabled) = webSocketSupport,
           !(enabled && provider.usesChatCompletionsGateway) {
            lines.append("supports_websockets = \(enabled)")
        }
        let block = lines.joined(separator: "\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n"
    }

    private func normalizedProviderBaseURL(_ baseURL: String) -> String {
        guard baseURL.hasSuffix("/") else { return baseURL }
        return String(baseURL.dropLast())
    }

    private func quote(_ value: String) -> String {
        let escaped = value.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x22: return "\\\""
            case 0x5c: return "\\\\"
            case 0...0x1f, 0x7f: return String(format: "\\u%04X", scalar.value)
            default: return String(scalar)
            }
        }.joined()
        return "\"\(escaped)\""
    }

    private func upsertSetting(_ text: String, key: String, value: String) -> String {
        let line = "\(key) = \(value)"
        let ranges = self.rootSettingLines(text, key: key)
        if !ranges.isEmpty {
            var result = text
            for range in ranges.reversed() { result.replaceSubrange(range, with: line) }
            return result
        }
        return line + "\n" + text
    }

    private func removeSetting(_ text: String, key: String) -> String {
        var result = text
        for range in self.rootSettingLines(text, key: key).reversed() {
            let end = range.upperBound < text.endIndex ? text.index(after: range.upperBound) : range.upperBound
            result.removeSubrange(range.lowerBound..<end)
        }
        return result
    }

    private func rootSettingLines(_ text: String, key: String) -> [Range<String.Index>] {
        let rootEnd = self.tableHeaders(in: text).first?.lowerBound ?? text.endIndex
        let pattern = "^[ \\t]*" + NSRegularExpression.escapedPattern(for: key) + "[ \\t]*="
        return self.topLevelLines(in: text).filter { range in
            range.lowerBound < rootEnd && text[range].range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func rootSettingValue(_ text: String, key: String) -> String? {
        guard let range = self.rootSettingLines(text, key: key).first,
              let separator = text[range].firstIndex(of: "=") else { return nil }
        let value = text[text.index(after: separator)..<range.upperBound].trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(value[value.index(after: value.startIndex)..<end])
    }

    private func removeBlock(_ text: String, key: String) -> String {
        self.removingTables(text) { header in
            ["[model_providers.\(key)]", "[model_providers.\(self.quote(key))]"]
                .contains(header.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func removeManagedProviderBlocks(_ text: String) -> String {
        self.removingTables(text) { header in
            header.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("[model_providers.\"\(Self.managedProviderPrefix)")
        }
    }

    private func removingTables(_ text: String, matching: (String) -> Bool) -> String {
        let headers = self.tableHeaders(in: text)
        var result = text
        for index in headers.indices.reversed() where matching(String(text[headers[index]])) {
            let end = index + 1 < headers.count ? headers[index + 1].lowerBound : text.endIndex
            result.removeSubrange(headers[index].lowerBound..<end)
        }
        return result
    }

    private func tableHeaders(in text: String) -> [Range<String.Index>] {
        self.topLevelLines(in: text).filter {
            text[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }
    }

    /// 避开多行字符串和数组中的配置示例，只修改实际的 TOML 键和表。
    private func topLevelLines(in text: String) -> [Range<String.Index>] {
        var lines: [Range<String.Index>] = []
        var multilineQuote: String?
        var arrayDepth = 0
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if multilineQuote == nil, arrayDepth == 0 { lines.append(lineStart..<lineEnd) }
            if multilineQuote == nil, arrayDepth == 0,
               line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                // 表头中的引号不跨行，也不属于数组。
            } else {
                var quote: Character?
                var cursor = line.startIndex
                while cursor < line.endIndex {
                    let rest = line[cursor...]
                    let char = line[cursor]
                    if let delimiter = multilineQuote {
                        if rest.hasPrefix(delimiter) {
                            multilineQuote = nil
                            cursor = line.index(cursor, offsetBy: 3)
                            continue
                        }
                        if delimiter == "\"\"\"", char == "\\" {
                            cursor = line.index(after: cursor)
                            if cursor < line.endIndex { cursor = line.index(after: cursor) }
                            continue
                        }
                    } else if let activeQuote = quote {
                        if char == activeQuote { quote = nil }
                        else if activeQuote == "\"", char == "\\" {
                            cursor = line.index(after: cursor)
                            if cursor < line.endIndex { cursor = line.index(after: cursor) }
                            continue
                        }
                    } else if char == "#" {
                        break
                    } else if rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") {
                        multilineQuote = String(rest.prefix(3))
                        cursor = line.index(cursor, offsetBy: 3)
                        continue
                    } else if char == "\"" || char == "'" {
                        quote = char
                    } else if char == "[" {
                        arrayDepth += 1
                    } else if char == "]" {
                        arrayDepth = max(0, arrayDepth - 1)
                    }
                    cursor = line.index(after: cursor)
                }
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return lines
    }
}
