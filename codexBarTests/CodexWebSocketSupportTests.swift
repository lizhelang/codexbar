import XCTest

final class CodexWebSocketSupportTests: CodexBarTestCase {
    func testOAuthHTTPSModeUsesManagedProviderAndRestoresBuiltInRoute() throws {
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(
            Data(
                """
                supports_websockets = true
                model = "gpt-5.5"

                [profiles.personal]
                supports_websockets = true
                model = "keep-profile-model"
                """.utf8
            ),
            to: CodexPaths.configTomlURL
        )

        let service = CodexSyncService(webSocketSupportDirective: { _, _ in .write(false) })
        try service.synchronize(config: self.oauthConfig())

        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        let root = String(tomlText.prefix { $0 != "[" })
        XCTAssertTrue(root.contains(#"model_provider = "codexbar.openai-oauth""#))
        XCTAssertFalse(root.contains("supports_websockets"))
        XCTAssertTrue(tomlText.contains(#"[model_providers."codexbar.openai-oauth"]"#))
        XCTAssertTrue(tomlText.contains("supports_websockets = false"))
        XCTAssertTrue(tomlText.contains("requires_openai_auth = true"))
        XCTAssertTrue(tomlText.contains(#"base_url = "https://chatgpt.com/backend-api/codex""#))
        XCTAssertFalse(tomlText.contains("experimental_bearer_token"))
        XCTAssertTrue(tomlText.contains("[profiles.personal]\nsupports_websockets = true"))

        let clearing = CodexSyncService(webSocketSupportDirective: { _, _ in .remove })
        try clearing.synchronize(config: self.oauthConfig())
        let cleared = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        let clearedRoot = String(cleared.prefix { $0 != "[" })
        XCTAssertTrue(clearedRoot.contains(#"model_provider = "openai""#))
        XCTAssertFalse(clearedRoot.contains("supports_websockets"))
        XCTAssertTrue(cleared.contains(#"[model_providers."codexbar.openai-oauth"]"#))
        XCTAssertTrue(cleared.contains(#"base_url = "https://chatgpt.com/backend-api/codex""#))
        XCTAssertTrue(cleared.contains("[profiles.personal]\nsupports_websockets = true"))
    }

    func testProviderOnlySyncCanSwitchOAuthHTTPSModeWithoutChangingAuth() throws {
        var config = self.oauthConfig()
        let service = CodexSyncService()
        try service.synchronize(config: config)
        let originalAuth = try Data(contentsOf: CodexPaths.authURL)

        config.openAI.webSocketSupportOverride = .disabled
        try service.synchronizeProviderDefinitions(config: config)
        var text = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#"model_provider = "codexbar.openai-oauth""#))
        XCTAssertTrue(text.contains("supports_websockets = false"))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), originalAuth)

        config.openAI.webSocketSupportOverride = .automatic
        try service.synchronizeProviderDefinitions(config: config)
        text = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#"model_provider = "openai""#))
        XCTAssertTrue(text.contains(#"[model_providers."codexbar.openai-oauth"]"#))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), originalAuth)
    }

    func testAggregateOAuthKeepsBuiltInProviderAndLocalGateway() throws {
        var config = self.oauthConfig()
        config.openAI.accountUsageMode = .aggregateGateway
        config.openAI.webSocketSupportOverride = .disabled
        try CodexSyncService().synchronize(config: config)

        let text = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        let root = String(text.prefix { $0 != "[" })
        XCTAssertTrue(root.contains(#"model_provider = "openai""#))
        XCTAssertTrue(root.contains(#"openai_base_url = "http://127.0.0.1:1456/v1""#))
        XCTAssertTrue(text.contains(#"[model_providers."codexbar.openai-oauth"]"#))
        XCTAssertTrue(text.contains(#"base_url = "http://127.0.0.1:1456/v1""#))
    }

    func testOverrideMapsToExplicitDirectiveAndAutomaticUsesCodexDefault() throws {
        let coordinator = CodexWebSocketSupportCoordinator.live
        var config = self.oauthConfig()
        let route = try CodexRouteResolver.resolve(config: config)

        XCTAssertEqual(coordinator.directive(for: config, route: route), .remove)

        config.openAI.webSocketSupportOverride = .disabled
        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(false))

        config.openAI.webSocketSupportOverride = .enabled
        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(true))
    }

    func testWebSocketOverrideDecodesAndSaves() throws {
        let missing = try JSONDecoder().decode(CodexBarOpenAISettings.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.webSocketSupportOverride, .automatic)
        let decoded = try JSONDecoder().decode(
            CodexBarOpenAISettings.self,
            from: Data(#"{"webSocketSupportOverride":"enabled"}"#.utf8)
        )
        XCTAssertEqual(decoded.webSocketSupportOverride, .enabled)

        var config = CodexBarConfig()
        try SettingsSaveRequestApplier.apply(
            SettingsSaveRequests(
                openAIAccount: OpenAIAccountSettingsUpdate(
                    accountOrder: [],
                    accountUsageMode: .switchAccount,
                    accountOrderingMode: .quotaSort,
                    manualActivationBehavior: .updateConfigOnly,
                    remoteConnectionAccountID: nil,
                    hybridTargetSelection: nil,
                    webSocketSupportOverride: .disabled
                )
            ),
            to: &config
        )
        XCTAssertEqual(config.openAI.webSocketSupportOverride, .disabled)
    }

    private func oauthConfig() -> CodexBarConfig {
        let account = CodexBarProviderAccount(
            id: "acct_ws",
            kind: .oauthTokens,
            label: "ws@example.com",
            email: "ws@example.com",
            openAIAccountId: "acct_ws",
            accessToken: "access-ws",
            refreshToken: "refresh-ws",
            idToken: "id-ws"
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        return CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )
    }
}

@MainActor
final class CodexWebSocketSupportSettingsTests: XCTestCase {
    func testSettingsOverrideRoundTripsThroughCoordinator() throws {
        let account = TokenAccount(
            email: "ws@example.com",
            accountId: "acct_ws",
            accessToken: "access-ws",
            refreshToken: "refresh-ws",
            idToken: "id-ws"
        )
        let stored = CodexBarProviderAccount(
            id: account.accountId,
            kind: .oauthTokens,
            label: account.email,
            email: account.email,
            openAIAccountId: account.accountId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: stored.id,
            accounts: [stored]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: stored.id),
            providers: [provider]
        )
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [account], historicalModels: [])
        coordinator.update(\.webSocketSupportOverride, to: .disabled, field: .webSocketSupportOverride)
        let sink = WebSocketSettingsSink(config: config)
        _ = try coordinator.save(using: sink)
        XCTAssertEqual(sink.config.openAI.webSocketSupportOverride, .disabled)

        let reopened = SettingsWindowCoordinator(config: sink.config, accounts: [account], historicalModels: [])
        XCTAssertEqual(reopened.draft.webSocketSupportOverride, .disabled)
    }
}

@MainActor
private final class WebSocketSettingsSink: SettingsSaveRequestApplying {
    var config: CodexBarConfig

    init(config: CodexBarConfig) {
        self.config = config
    }

    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        try SettingsSaveRequestApplier.apply(requests, to: &self.config)
    }
}
