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

    func testRouteResolverSwitchModeUsesFixedOAuthIdentityAndRequestTarget() throws {
        let activeAccount = CodexBarProviderAccount(
            id: "acct_active",
            kind: .oauthTokens,
            label: "active@example.com",
            email: "active@example.com",
            openAIAccountId: "acct_active",
            accessToken: "access-active",
            refreshToken: "refresh-active",
            idToken: "id-active"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: activeAccount.id,
            accounts: [activeAccount]
        )
        let compatibleAccount = CodexBarProviderAccount(
            id: "acct_relay",
            kind: .apiKey,
            label: "Relay",
            apiKey: "sk-relay"
        )
        let compatibleProvider = CodexBarProvider(
            id: "relay-provider",
            kind: .openAICompatible,
            label: "Relay",
            activeAccountId: compatibleAccount.id,
            accounts: [compatibleAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: activeAccount.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                remoteConnectionAccountID: activeAccount.id,
                hybridTargetSelection: CodexBarHybridTargetSelection(
                    providerId: compatibleProvider.id,
                    accountId: compatibleAccount.id
                )
            ),
            providers: [oauthProvider, compatibleProvider]
        )

        let route = try CodexRouteResolver.resolve(config: config)

        XCTAssertEqual(route.mode, .switchAccount)
        XCTAssertEqual(route.authAccount.id, activeAccount.id)
        XCTAssertEqual(route.targetAccount.id, compatibleAccount.id)
        XCTAssertEqual(route.targetProvider.id, compatibleProvider.id)
        XCTAssertTrue(route.requiresOpenAIAuth)
    }

    func testSynchronizeUsesRemoteConnectionAccountForCustomProvider() throws {
        let remoteAccount = CodexBarProviderAccount(
            id: "acct_remote",
            kind: .oauthTokens,
            label: "remote@example.com",
            email: "remote@example.com",
            openAIAccountId: "remote_openai_account",
            accessToken: "access-remote",
            refreshToken: "refresh-remote",
            idToken: "id-remote"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: remoteAccount.id,
            accounts: [remoteAccount]
        )
        let compatibleAccount = CodexBarProviderAccount(
            id: "acct_relay",
            kind: .apiKey,
            label: "Relay",
            apiKey: "sk-relay-secret"
        )
        let compatibleProvider = CodexBarProvider(
            id: "relay-provider",
            kind: .openAICompatible,
            label: "Relay",
            baseURL: "https://relay.example.com/v1/",
            activeAccountId: compatibleAccount.id,
            accounts: [compatibleAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: compatibleProvider.id, accountId: compatibleAccount.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                remoteConnectionAccountID: remoteAccount.id,
                hybridTargetSelection: CodexBarHybridTargetSelection(
                    providerId: compatibleProvider.id,
                    accountId: compatibleAccount.id
                )
            ),
            providers: [oauthProvider, compatibleProvider]
        )

        try CodexSyncService().synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertEqual(authObject["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(authObject["OPENAI_API_KEY"] is NSNull)
        XCTAssertEqual(tokens["access_token"] as? String, "access-remote")
        XCTAssertEqual(tokens["account_id"] as? String, "remote_openai_account")
        XCTAssertTrue(tomlText.contains(#"model_provider = "CodexbarRemote""#))
        XCTAssertTrue(tomlText.contains("[model_providers.CodexbarRemote]"))
        XCTAssertTrue(tomlText.contains(#"wire_api = "responses""#))
        XCTAssertTrue(tomlText.contains("requires_openai_auth = true"))
        XCTAssertTrue(tomlText.contains(#"base_url = "https://relay.example.com/v1""#))
        XCTAssertTrue(tomlText.contains(#"experimental_bearer_token = "sk-relay-secret""#))
        XCTAssertFalse(tomlText.contains("openai_base_url ="))
    }

    func testSynchronizeUsesRemoteOnlyRemoteConnectionAccountForCustomProvider() throws {
        let remoteAccount = CodexBarProviderAccount(
            id: "remote_only_local",
            kind: .oauthTokens,
            label: "remote@example.com",
            email: "remote@example.com",
            openAIAccountId: "remote_openai_account",
            accessToken: "access-remote-only",
            refreshToken: "refresh-remote-only",
            idToken: "id-remote-only",
            oauthClientID: "client-remote-only"
        )
        let compatibleAccount = CodexBarProviderAccount(
            id: "acct_relay",
            kind: .apiKey,
            label: "Relay",
            apiKey: "sk-relay-secret"
        )
        let compatibleProvider = CodexBarProvider(
            id: "relay-provider",
            kind: .openAICompatible,
            label: "Relay",
            baseURL: "https://relay.example.com/v1/",
            activeAccountId: compatibleAccount.id,
            accounts: [compatibleAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: compatibleProvider.id, accountId: compatibleAccount.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                remoteConnectionAccountID: remoteAccount.id,
                remoteConnectionAccounts: [remoteAccount],
                hybridTargetSelection: CodexBarHybridTargetSelection(
                    providerId: compatibleProvider.id,
                    accountId: compatibleAccount.id
                )
            ),
            providers: [compatibleProvider]
        )

        XCTAssertEqual(config.remoteConnectionAccount()?.id, "remote_only_local")

        try CodexSyncService().synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertEqual(authObject["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(authObject["OPENAI_API_KEY"] is NSNull)
        XCTAssertEqual(authObject["client_id"] as? String, "client-remote-only")
        XCTAssertEqual(tokens["access_token"] as? String, "access-remote-only")
        XCTAssertEqual(tokens["refresh_token"] as? String, "refresh-remote-only")
        XCTAssertEqual(tokens["id_token"] as? String, "id-remote-only")
        XCTAssertEqual(tokens["account_id"] as? String, "remote_openai_account")
        XCTAssertTrue(tomlText.contains(#"model_provider = "CodexbarRemote""#))
        XCTAssertTrue(tomlText.contains("requires_openai_auth = true"))
        XCTAssertTrue(tomlText.contains(#"base_url = "https://relay.example.com/v1""#))
    }

    func testSynchronizeUsesFixedOAuthIdentityAndOpenAIGatewayForOpenAITarget() throws {
        let loginAccount = CodexBarProviderAccount(
            id: "acct_login",
            kind: .oauthTokens,
            label: "login@example.com",
            email: "login@example.com",
            openAIAccountId: "remote_login_account",
            accessToken: "access-login",
            refreshToken: "refresh-login",
            idToken: "id-login"
        )
        let quotaAccount = CodexBarProviderAccount(
            id: "acct_quota",
            kind: .oauthTokens,
            label: "quota@example.com",
            email: "quota@example.com",
            openAIAccountId: "remote_quota_account",
            accessToken: "access-quota",
            refreshToken: "refresh-quota",
            idToken: "id-quota"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: quotaAccount.id,
            accounts: [loginAccount, quotaAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: quotaAccount.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                remoteConnectionAccountID: loginAccount.id
            ),
            providers: [oauthProvider]
        )

        try CodexSyncService().synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertEqual(authObject["auth_mode"] as? String, "chatgpt")
        XCTAssertEqual(tokens["access_token"] as? String, "access-login")
        XCTAssertEqual(tokens["account_id"] as? String, "remote_login_account")
        XCTAssertTrue(tomlText.contains(#"model_provider = "openai""#))
        XCTAssertTrue(tomlText.contains(#"openai_base_url = "http://localhost:1456/v1""#))
        XCTAssertFalse(tomlText.contains("[model_providers.CodexbarRemote]"))
        XCTAssertFalse(tomlText.contains("access-quota"))
    }

    func testSynchronizeRequiresRemoteConnectionAccountTokens() throws {
        let compatibleAccount = CodexBarProviderAccount(
            id: "acct_relay",
            kind: .apiKey,
            label: "Relay",
            apiKey: "sk-relay-secret"
        )
        let compatibleProvider = CodexBarProvider(
            id: "relay-provider",
            kind: .openAICompatible,
            label: "Relay",
            baseURL: "https://relay.example.com/v1/",
            activeAccountId: compatibleAccount.id,
            accounts: [compatibleAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: compatibleProvider.id, accountId: compatibleAccount.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                remoteConnectionAccountID: "missing_remote_account",
                hybridTargetSelection: CodexBarHybridTargetSelection(
                    providerId: compatibleProvider.id,
                    accountId: compatibleAccount.id
                )
            ),
            providers: [compatibleProvider]
        )

        XCTAssertThrowsError(try CodexSyncService().synchronize(config: config)) { error in
            guard case CodexSyncError.missingRemoteConnectionAccount = error else {
                XCTFail("Expected missingRemoteConnectionAccount, got \(error)")
                return
            }
        }
    }

    func testSynchronizeUsesRemoteConnectionAccountForOpenRouterProvider() throws {
        let remoteAccount = CodexBarProviderAccount(
            id: "acct_remote",
            kind: .oauthTokens,
            label: "remote@example.com",
            email: "remote@example.com",
            openAIAccountId: "remote_openai_account",
            accessToken: "access-remote",
            refreshToken: "refresh-remote",
            idToken: "id-remote"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: remoteAccount.id,
            accounts: [remoteAccount]
        )
        let openRouterAccount = CodexBarProviderAccount(
            id: "acct_openrouter",
            kind: .apiKey,
            label: "OpenRouter Primary",
            apiKey: "sk-or-v1-primary"
        )
        let openRouterProvider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: "anthropic/claude-3.7-sonnet",
            activeAccountId: openRouterAccount.id,
            accounts: [openRouterAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: openRouterProvider.id, accountId: openRouterAccount.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                remoteConnectionAccountID: remoteAccount.id,
                hybridTargetSelection: CodexBarHybridTargetSelection(
                    providerId: openRouterProvider.id,
                    accountId: openRouterAccount.id
                )
            ),
            providers: [oauthProvider, openRouterProvider]
        )

        try CodexSyncService().synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertEqual(authObject["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(authObject["OPENAI_API_KEY"] is NSNull)
        XCTAssertEqual(tokens["account_id"] as? String, "remote_openai_account")
        XCTAssertTrue(tomlText.contains(#"model_provider = "CodexbarRemote""#))
        XCTAssertTrue(tomlText.contains(#"model = "anthropic/claude-3.7-sonnet""#))
        XCTAssertTrue(tomlText.contains(#"base_url = "http://localhost:1457/v1""#))
        XCTAssertTrue(tomlText.contains(#"experimental_bearer_token = "codexbar-openrouter-gateway""#))
        XCTAssertFalse(tomlText.contains("openai_base_url ="))
    }

    func testRouteResolverFallsBackToActiveTargetWhenRequestTargetIsUnset() throws {
        let remoteAccount = CodexBarProviderAccount(
            id: "acct_remote",
            kind: .oauthTokens,
            label: "remote@example.com",
            email: "remote@example.com",
            openAIAccountId: "remote_openai_account",
            accessToken: "access-remote",
            refreshToken: "refresh-remote",
            idToken: "id-remote"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: remoteAccount.id,
            accounts: [remoteAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: remoteAccount.id),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                remoteConnectionAccountID: remoteAccount.id
            ),
            providers: [oauthProvider]
        )

        let route = try CodexRouteResolver.resolve(config: config)

        XCTAssertEqual(route.authAccount.id, remoteAccount.id)
        XCTAssertEqual(route.targetProvider.id, oauthProvider.id)
        XCTAssertEqual(route.targetAccount.id, remoteAccount.id)
        XCTAssertFalse(route.requiresOpenAIAuth)
    }

    private enum SyncFailure: Error, Equatable {
        case configWriteFailed
    }
}
