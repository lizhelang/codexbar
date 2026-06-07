import Foundation

struct ResolvedCodexRoute: Equatable {
    let mode: CodexBarOpenAIAccountUsageMode
    let authProvider: CodexBarProvider
    let authAccount: CodexBarProviderAccount
    let targetProvider: CodexBarProvider
    let targetAccount: CodexBarProviderAccount
    let effectiveModel: String
    let requiresOpenAIAuth: Bool
}

enum CodexRouteResolver {
    static func resolve(config: CodexBarConfig) throws -> ResolvedCodexRoute {
        switch config.openAI.accountUsageMode {
        case .switchAccount:
            return try self.resolveSwitchRoute(config: config)
        case .aggregateGateway:
            return try self.resolveAggregateRoute(config: config)
        }
    }

    private static func resolveSwitchRoute(config: CodexBarConfig) throws -> ResolvedCodexRoute {
        let target = try self.resolveRequestTarget(config: config)
        return try self.makeRoute(
            config: config,
            mode: .switchAccount,
            targetProvider: target.provider,
            targetAccount: target.account
        )
    }

    private static func resolveAggregateRoute(config: CodexBarConfig) throws -> ResolvedCodexRoute {
        if let target = try self.resolveConfiguredRequestTarget(config: config) {
            return try self.makeRoute(
                config: config,
                mode: .aggregateGateway,
                targetProvider: target.provider,
                targetAccount: target.account
            )
        }

        guard let provider = config.oauthProvider() else {
            throw CodexSyncError.missingActiveProvider
        }
        guard let account = provider.accounts.first(where: { $0.id == config.active.accountId }) ?? provider.activeAccount else {
            throw CodexSyncError.missingActiveAccount
        }
        return try self.makeRoute(
            config: config,
            mode: .aggregateGateway,
            targetProvider: provider,
            targetAccount: account,
            effectiveModel: config.global.defaultModel
        )
    }

    private static func resolveRequestTarget(config: CodexBarConfig) throws -> (provider: CodexBarProvider, account: CodexBarProviderAccount) {
        if let target = try self.resolveConfiguredRequestTarget(config: config) {
            return target
        }
        guard let provider = config.activeProvider() else {
            throw CodexSyncError.missingActiveProvider
        }
        guard let account = config.activeAccount() else {
            throw CodexSyncError.missingActiveAccount
        }
        return (provider, account)
    }

    private static func resolveConfiguredRequestTarget(
        config: CodexBarConfig
    ) throws -> (provider: CodexBarProvider, account: CodexBarProviderAccount)? {
        guard let selection = config.openAI.hybridTargetSelection else { return nil }
        guard let provider = config.provider(id: selection.providerId),
              provider.kind != .openAIOAuth else {
            throw CodexSyncError.missingRequestTarget
        }
        guard let accountID = selection.accountId,
              let account = provider.accounts.first(where: { $0.id == accountID }) else {
            throw CodexSyncError.missingRequestTarget
        }
        return (provider, account)
    }

    private static func makeRoute(
        config: CodexBarConfig,
        mode: CodexBarOpenAIAccountUsageMode,
        targetProvider: CodexBarProvider,
        targetAccount: CodexBarProviderAccount,
        effectiveModel: String? = nil
    ) throws -> ResolvedCodexRoute {
        let configuredRemoteAccount = config.remoteConnectionAccount()
        if config.openAI.remoteConnectionAccountID != nil && configuredRemoteAccount == nil {
            throw CodexSyncError.missingRemoteConnectionAccount
        }
        let authAccount = configuredRemoteAccount ?? targetAccount
        let authProvider = authAccount.kind == .oauthTokens
            ? (config.oauthProvider() ?? targetProvider)
            : targetProvider
        let usesFixedOAuthIdentity = configuredRemoteAccount != nil && targetProvider.kind != .openAIOAuth
        return ResolvedCodexRoute(
            mode: mode,
            authProvider: authProvider,
            authAccount: authAccount,
            targetProvider: targetProvider,
            targetAccount: targetAccount,
            effectiveModel: try (effectiveModel ?? self.effectiveModel(config: config, provider: targetProvider)),
            requiresOpenAIAuth: usesFixedOAuthIdentity
        )
    }

    private static func effectiveModel(
        config: CodexBarConfig,
        provider: CodexBarProvider,
        preferredModelID: String? = nil
    ) throws -> String {
        switch provider.kind {
        case .openRouter:
            guard let model = CodexBarProvider.normalizedOpenRouterModelID(preferredModelID) ??
                provider.openRouterEffectiveModelID else {
                throw CodexSyncError.missingOpenRouterModel
            }
            return model
        case .openAIOAuth, .openAICompatible:
            return provider.defaultModel ?? config.global.defaultModel
        }
    }
}
