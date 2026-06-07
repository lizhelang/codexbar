import Foundation

enum SettingsSaveRequestApplier {
    static func apply(
        _ requests: SettingsSaveRequests,
        to config: inout CodexBarConfig
    ) throws {
        self.apply(requests.openAIAccount, to: &config)
        self.apply(requests.openAIUsage, to: &config)
        self.apply(requests.modelPricing, to: &config)
        try self.apply(requests.desktop, to: &config)
    }

    static func apply(_ request: OpenAIAccountSettingsUpdate?, to config: inout CodexBarConfig) {
        guard let request else { return }
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
        config.normalizeRemoteConnectionAccounts()
    }

    static func apply(_ request: OpenAIUsageSettingsUpdate?, to config: inout CodexBarConfig) {
        guard let request else { return }
        config.openAI.usageDisplayMode = request.usageDisplayMode
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
}
