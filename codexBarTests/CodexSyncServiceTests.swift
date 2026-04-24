import Foundation
import XCTest

final class CodexSyncServiceTests: CodexBarTestCase {
    func testSynchronizeRestoresPreviousFilesWhenConfigWriteFails() throws {
        try CodexPaths.ensureDirectories()

        let originalAuth = Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"old"}}"#.utf8)
        let originalToml = Data("model = \"gpt-5.4-mini\"\n".utf8)
        try CodexPaths.writeSecureFile(originalAuth, to: CodexPaths.authURL)
        try CodexPaths.writeSecureFile(originalToml, to: CodexPaths.configTomlURL)

        let account = CodexBarProviderAccount(
            id: "acct_new",
            kind: .oauthTokens,
            label: "new@example.com",
            email: "new@example.com",
            openAIAccountId: "acct_new",
            accessToken: "access-new",
            refreshToken: "refresh-new",
            idToken: "id-new"
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )

        var configWriteAttempts = 0
        let service = CodexSyncService(
            writeSecureFile: { data, url in
                if url == CodexPaths.configTomlURL {
                    configWriteAttempts += 1
                    if configWriteAttempts == 1 {
                        throw SyncFailure.configWriteFailed
                    }
                }
                try CodexPaths.writeSecureFile(data, to: url)
            }
        )

        XCTAssertThrowsError(try service.synchronize(config: config)) { error in
            XCTAssertEqual(error as? SyncFailure, .configWriteFailed)
        }

        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), originalAuth)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.configTomlURL), originalToml)
    }

    func testSynchronizePreservesChatGPTAuthAndServiceTierWhenAggregateModeIsEnabled() throws {
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(
            Data(
                """
                service_tier = "fast"
                preferred_auth_method = "chatgpt"
                model = "gpt-5.4-mini"
                """.utf8
            ),
            to: CodexPaths.configTomlURL
        )

        let account = CodexBarProviderAccount(
            id: "acct_pool",
            kind: .oauthTokens,
            label: "pool@example.com",
            email: "pool@example.com",
            openAIAccountId: "acct_pool",
            accessToken: "access-pool",
            refreshToken: "refresh-pool",
            idToken: "id-pool"
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: .aggregateGateway),
            providers: [provider]
        )

        try CodexSyncService().synchronize(config: config)

        let authText = try String(contentsOf: CodexPaths.authURL, encoding: .utf8)
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertTrue(authText.contains(#""auth_mode" : "chatgpt""#))
        XCTAssertTrue(authText.contains("access-pool"))
        XCTAssertFalse(authText.contains("codexbar-local-gateway"))
        XCTAssertTrue(tomlText.contains(#"openai_base_url = "http://localhost:1456/v1""#))
        XCTAssertTrue(tomlText.contains(#"service_tier = "fast""#))
        XCTAssertFalse(tomlText.contains("preferred_auth_method"))
    }

    func testSynchronizeWritesOnlyFakeKeyForAggregateLocalAPIKeyMode() throws {
        try CodexPaths.ensureDirectories()

        let account = CodexBarProviderAccount(
            id: "acct_local_api_key",
            kind: .oauthTokens,
            label: "local-api-key@example.com",
            email: "local-api-key@example.com",
            openAIAccountId: "acct_local_api_key",
            accessToken: "access-local-api-key",
            refreshToken: "refresh-local-api-key",
            idToken: "id-local-api-key"
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .aggregateGateway,
                gatewayCredentialMode: .localAPIKey
            ),
            providers: [provider]
        )

        try CodexSyncService().synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        let credentialData = try Data(contentsOf: CodexPaths.openAIGatewayCredentialURL)
        let credential = try JSONDecoder.iso8601.decode(OpenAIGatewayCredentialSnapshot.self, from: credentialData)

        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, credential.openAIAPIKey)
        XCTAssertNil(authObject["auth_mode"])
        XCTAssertNil(authObject["tokens"])
        XCTAssertFalse(String(data: try Data(contentsOf: CodexPaths.authURL), encoding: .utf8)?.contains("access-local-api-key") == true)
        XCTAssertTrue(tomlText.contains(#"openai_base_url = "http://localhost:1456/v1""#))
    }

    func testSynchronizeReusesStableFakeKeyAndRestoresPassthroughTokensWhenSwitchingBack() throws {
        try CodexPaths.ensureDirectories()

        let account = CodexBarProviderAccount(
            id: "acct_local_api_key_switch_back",
            kind: .oauthTokens,
            label: "switch-back@example.com",
            email: "switch-back@example.com",
            openAIAccountId: "acct_local_api_key_switch_back",
            accessToken: "access-switch-back",
            refreshToken: "refresh-switch-back",
            idToken: "id-switch-back"
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        var config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .aggregateGateway,
                gatewayCredentialMode: .localAPIKey
            ),
            providers: [provider]
        )
        let service = CodexSyncService()

        try service.synchronize(config: config)
        let firstCredential = try JSONDecoder.iso8601.decode(
            OpenAIGatewayCredentialSnapshot.self,
            from: Data(contentsOf: CodexPaths.openAIGatewayCredentialURL)
        )

        try service.synchronize(config: config)
        let secondCredential = try JSONDecoder.iso8601.decode(
            OpenAIGatewayCredentialSnapshot.self,
            from: Data(contentsOf: CodexPaths.openAIGatewayCredentialURL)
        )

        XCTAssertEqual(firstCredential.openAIAPIKey, secondCredential.openAIAPIKey)

        config.openAI.gatewayCredentialMode = .oauthPassthrough
        try service.synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])

        XCTAssertEqual(authObject["auth_mode"] as? String, "chatgpt")
        XCTAssertEqual(tokens["access_token"] as? String, "access-switch-back")
        XCTAssertEqual(tokens["refresh_token"] as? String, "refresh-switch-back")
        XCTAssertEqual(tokens["id_token"] as? String, "id-switch-back")
        XCTAssertTrue(authObject["OPENAI_API_KEY"] is NSNull)
    }

    func testSynchronizeWritesOAuthLifecycleMetadataToAuthJSON() throws {
        let tokenLastRefreshAt = Date(timeIntervalSince1970: 1_790_000_000)
        let account = CodexBarProviderAccount(
            id: "acct_sync_metadata",
            kind: .oauthTokens,
            label: "sync@example.com",
            email: "sync@example.com",
            openAIAccountId: "acct_sync_metadata",
            accessToken: "access-sync",
            refreshToken: "refresh-sync",
            idToken: "id-sync",
            expiresAt: Date(timeIntervalSince1970: 1_790_003_600),
            oauthClientID: "app_sync_client",
            tokenLastRefreshAt: tokenLastRefreshAt,
            lastRefresh: tokenLastRefreshAt
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )

        try CodexSyncService().synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        let formatter = ISO8601DateFormatter()

        XCTAssertEqual(authObject["client_id"] as? String, "app_sync_client")
        XCTAssertEqual(authObject["last_refresh"] as? String, formatter.string(from: tokenLastRefreshAt))
        XCTAssertEqual(tokens["access_token"] as? String, "access-sync")
        XCTAssertEqual(tokens["refresh_token"] as? String, "refresh-sync")
        XCTAssertEqual(tokens["account_id"] as? String, "acct_sync_metadata")
    }

    func testSynchronizeWritesOpenRouterGatewayConfigAndProviderModel() throws {
        let account = CodexBarProviderAccount(
            id: "acct_openrouter",
            kind: .apiKey,
            label: "OpenRouter Primary",
            apiKey: "sk-or-v1-primary"
        )
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: "anthropic/claude-3.7-sonnet",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexBarConfig(
            global: CodexBarGlobalSettings(
                defaultModel: "gpt-5.4",
                reviewModel: "gpt-5.4",
                reasoningEffort: "high"
            ),
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )

        try CodexSyncService().synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, OpenRouterGatewayConfiguration.apiKey)
        XCTAssertTrue(tomlText.contains(#"openai_base_url = "http://localhost:1457/v1""#))
        XCTAssertTrue(tomlText.contains(#"model = "anthropic/claude-3.7-sonnet""#))
        XCTAssertTrue(tomlText.contains(#"review_model = "anthropic/claude-3.7-sonnet""#))
    }

    private enum SyncFailure: Error, Equatable {
        case configWriteFailed
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
