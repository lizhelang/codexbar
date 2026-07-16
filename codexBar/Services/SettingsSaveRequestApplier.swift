import Foundation

enum SettingsSaveRequestApplier {
    static func apply(
        _ requests: SettingsSaveRequests,
        to config: inout CodexBarConfig
    ) throws {
        self.apply(requests.global, to: &config)
        try self.apply(requests.openAIAccount, to: &config)
        self.apply(requests.openAIUsage, to: &config)
        self.apply(requests.modelPricing, to: &config)
        try self.apply(requests.desktop, to: &config)
    }

    static func apply(_ request: GlobalSettingsUpdate?, to config: inout CodexBarConfig) {
        guard let request else { return }
        let defaultModel = self.normalizedModel(request.defaultModel) ?? config.global.defaultModel
        let reviewModel = self.normalizedModel(request.reviewModel) ?? defaultModel
        let requestedReasoningEffort = self.normalizedReasoningEffort(request.reasoningEffort) ?? config.global.reasoningEffort
        let resolvedRoute = try? CodexRouteResolver.resolve(config: config)
        let reasoningModel = resolvedRoute?.targetProvider.kind == .openAIOAuth
            ? defaultModel
            : (resolvedRoute?.effectiveModel ?? defaultModel)
        let reasoningEffort = CodexBarGlobalSettings.compatibleReasoningEffort(
            requestedReasoningEffort,
            for: reasoningModel
        )
        let serviceTier = self.normalizedServiceTier(request.serviceTier) ?? config.global.serviceTier
        let modelContextWindows = request.modelContextWindows
            .map(CodexBarGlobalSettings.normalizedModelContextWindows(_:)) ?? config.global.modelContextWindows
        config.global = CodexBarGlobalSettings(
            defaultModel: defaultModel,
            reviewModel: reviewModel,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            modelContextWindows: modelContextWindows
        )
    }

    static func apply(_ request: OpenAIAccountSettingsUpdate?, to config: inout CodexBarConfig) throws {
        guard let request else { return }
        let aggregateGatewayProxyURL = try self.validatedAggregateGatewayProxyURL(
            from: request.aggregateGatewayProxyURL
        )
        let previousMode = config.openAI.accountUsageMode
        config.setOpenAIAccountOrder(request.accountOrder)
        if previousMode == .switchAccount, request.accountUsageMode != .switchAccount {
            config.captureSwitchModeSelection()
        }
        config.setOpenAIAccountUsageMode(request.accountUsageMode)
        if request.accountUsageMode == .aggregateGateway,
           let provider = config.oauthProvider() {
            config.active.providerId = provider.id
            config.active.accountId = provider.activeAccountId
        } else if request.accountUsageMode == .switchAccount {
            config.restoreSwitchModeSelectionIfAvailable()
        }
        config.setOpenAIAccountOrderingMode(request.accountOrderingMode)
        config.setOpenAIManualActivationBehavior(request.manualActivationBehavior)
        config.setRemoteConnectionAccountID(request.remoteConnectionAccountID)
        config.setHybridTargetSelection(request.hybridTargetSelection)
        config.openAI.aggregateGatewayProxyURL = aggregateGatewayProxyURL
        config.normalizeRemoteConnectionAccounts()
    }

    static func apply(_ request: OpenAIUsageSettingsUpdate?, to config: inout CodexBarConfig) {
        guard let request else { return }
        config.openAI.usageDisplayMode = request.usageDisplayMode
        config.openAI.showsMenuBarUsageText = request.showsMenuBarUsageText
        config.openAI.quotaSort = CodexBarOpenAISettings.QuotaSortSettings(
            plusRelativeWeight: request.plusRelativeWeight,
            proRelativeToPlusMultiplier: request.proRelativeToPlusMultiplier,
            teamRelativeToPlusMultiplier: request.teamRelativeToPlusMultiplier
        )
    }

    static func apply(_ request: ModelPricingSettingsUpdate?, to config: inout CodexBarConfig) {
        guard let request else { return }

        for model in request.removals {
            config.modelPricing.removeValue(forKey: model)
        }

        for (model, pricing) in request.upserts {
            config.modelPricing[model] = pricing
        }
    }

    static func apply(_ request: DesktopSettingsUpdate?, to config: inout CodexBarConfig) throws {
        guard let request else { return }
        config.desktop.preferredCodexAppPath = try self.validatedPreferredCodexAppPath(
            from: request.preferredCodexAppPath
        )
    }

    static func validatedPreferredCodexAppPath(from preferredCodexAppPath: String?) throws -> String? {
        let trimmedPreferredPath = preferredCodexAppPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedPreferredPath.isEmpty {
            return nil
        }

        guard let validatedPath = CodexDesktopLaunchProbeService
            .validatedPreferredCodexAppURL(from: trimmedPreferredPath)?
            .path else {
            throw TokenStoreError.invalidCodexAppPath
        }

        return validatedPath
    }

    static func validatedAggregateGatewayProxyURL(from proxyURL: String?) throws -> String? {
        let trimmed = proxyURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else { return nil }
        guard OpenAIAccountGatewayConfiguredProxy(address: trimmed) != nil else {
            throw TokenStoreError.invalidInput
        }
        return trimmed
    }

    private static func normalizedModel(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedReasoningEffort(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedServiceTier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        switch trimmed {
        case "standard", "flex":
            return "flex"
        case "fast":
            return "fast"
        default:
            return nil
        }
    }
}
