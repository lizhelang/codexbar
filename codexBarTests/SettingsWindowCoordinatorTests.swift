import XCTest

@MainActor
final class SettingsWindowCoordinatorTests: XCTestCase {
    func testSwitchingPagesKeepsDraftAcrossEdits() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: accounts,
            historicalModels: ["gpt-5.4", "google/gemini-2.5-pro"]
        )

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 12, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 14, field: .proRelativeToPlusMultiplier)
        coordinator.updateModelPricing(
            for: "google/gemini-2.5-pro",
            pricing: CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: "/Applications/Codex.app", field: .preferredCodexAppPath)
        coordinator.selectedPage = .updates

        XCTAssertEqual(coordinator.draft.accountOrderingMode, .manual)
        XCTAssertEqual(coordinator.draft.manualActivationBehavior, .launchNewInstance)
        coordinator.selectedPage = .usage
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
        XCTAssertEqual(coordinator.draft.plusRelativeWeight, 12)
        XCTAssertEqual(coordinator.draft.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(
            coordinator.draft.modelPricing["google/gemini-2.5-pro"],
            CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        XCTAssertEqual(coordinator.draft.preferredCodexAppPath, "/Applications/Codex.app")
    }

    func testConfiguredModelPricingStillAppearsWhenHistoricalModelsAreNotReady() {
        var config = self.makeConfig()
        config.modelPricing = [
            "google/gemini-2.5-pro": CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            ),
        ]

        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [],
            historicalModels: []
        )

        XCTAssertEqual(coordinator.historicalModels, ["google/gemini-2.5-pro"])
        XCTAssertEqual(
            coordinator.draft.modelPricing["google/gemini-2.5-pro"],
            CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
    }

    func testManualAccountOrderSectionVisibilityFollowsOrderingMode() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(accountOrderingMode: .quotaSort),
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertFalse(coordinator.showsManualAccountOrderSection)

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        XCTAssertTrue(coordinator.showsManualAccountOrderSection)

        coordinator.update(\.accountOrderingMode, to: .quotaSort, field: .accountOrderingMode)
        XCTAssertFalse(coordinator.showsManualAccountOrderSection)
    }

    func testCodexAppPathSectionVisibilityFollowsManualActivationBehavior() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertFalse(coordinator.showsCodexAppPathSection)

        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        XCTAssertTrue(coordinator.showsCodexAppPathSection)

        coordinator.update(\.manualActivationBehavior, to: .updateConfigOnly, field: .manualActivationBehavior)
        XCTAssertFalse(coordinator.showsCodexAppPathSection)
    }

    func testSaveEmitsChangedDomainRequestsAndReopenReflectsSavedValues() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4", "google/gemini-2.5-pro"]
        )

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        coordinator.setAccountOrder(["acct_beta", "acct_alpha"])
        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 12, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 14, field: .proRelativeToPlusMultiplier)
        coordinator.update(\.teamRelativeToPlusMultiplier, to: 2.2, field: .teamRelativeToPlusMultiplier)
        coordinator.updateModelPricing(
            for: "google/gemini-2.5-pro",
            pricing: CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: "/Applications/Codex.app", field: .preferredCodexAppPath)

        let requests = try coordinator.save(using: sink)

        XCTAssertEqual(sink.appliedRequests.count, 1)
        XCTAssertEqual(
            requests.openAIAccount,
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_beta", "acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual,
                manualActivationBehavior: .launchNewInstance
            )
        )
        XCTAssertEqual(
            requests.openAIUsage,
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining,
                plusRelativeWeight: 12,
                proRelativeToPlusMultiplier: 14,
                teamRelativeToPlusMultiplier: 2.2
            )
        )
        XCTAssertEqual(
            requests.desktop,
            DesktopSettingsUpdate(preferredCodexAppPath: "/Applications/Codex.app")
        )
        XCTAssertEqual(
            requests.modelPricing,
            ModelPricingSettingsUpdate(
                upserts: [
                    "google/gemini-2.5-pro": CodexBarModelPricing(
                        inputUSDPerToken: 0.9e-6,
                        cachedInputUSDPerToken: 0.4e-6,
                        outputUSDPerToken: 1.8e-6
                    ),
                ],
                removals: []
            )
        )

        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4", "google/gemini-2.5-pro"]
        )
        XCTAssertEqual(reopened.draft.accountOrder, ["acct_beta", "acct_alpha"])
        XCTAssertEqual(reopened.draft.accountOrderingMode, .manual)
        XCTAssertEqual(reopened.draft.manualActivationBehavior, .launchNewInstance)
        XCTAssertEqual(reopened.draft.usageDisplayMode, .remaining)
        XCTAssertEqual(reopened.draft.plusRelativeWeight, 12)
        XCTAssertEqual(reopened.draft.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(reopened.draft.teamRelativeToPlusMultiplier, 2.2)
        XCTAssertEqual(reopened.draft.preferredCodexAppPath, "/Applications/Codex.app")
        XCTAssertEqual(
            reopened.draft.modelPricing["google/gemini-2.5-pro"],
            CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
    }

    func testCancelRollsBackAcrossPagesAndDoesNotTriggerRequests() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let baseConfig = self.makeConfig()
        let sink = TestSettingsSaveSink(config: baseConfig)
        let coordinator = SettingsWindowCoordinator(
            config: baseConfig,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 14, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 15, field: .proRelativeToPlusMultiplier)
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: "/Applications/Codex.app", field: .preferredCodexAppPath)

        coordinator.cancel()

        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertEqual(
            coordinator.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.4"]
            )
        )

        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )
        XCTAssertEqual(
            reopened.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.4"]
            )
        )
    }

    func testSaveAndCloseClosesWindowAfterSuccessfulSave() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.saveAndClose(using: sink) {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(sink.appliedRequests.count, 1)
    }

    func testCancelAndCloseDoesNotSaveButClosesWindow() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.cancelAndClose {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .used)
    }

    func testSaveAndCloseKeepsWindowOpenWhenSaveFails() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )
        let sink = FailingSettingsSaveSink()
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.saveAndClose(using: sink) {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(coordinator.validationMessage, "save failed")
    }

    func testReconcileExternalStateRefreshesUntouchedFieldsAndPreservesEditedFields() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)

        var externalConfig = self.makeConfig()
        externalConfig.openAI.accountOrderingMode = .manual
        externalConfig.openAI.usageDisplayMode = .remaining
        externalConfig.openAI.manualActivationBehavior = .updateConfigOnly

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(coordinator.draft.accountOrderingMode, .manual)
        XCTAssertEqual(coordinator.draft.manualActivationBehavior, .launchNewInstance)
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
    }

    func testReconcileExternalStateKeepsExplicitlyEditedFieldEvenIfValueMatchesOriginalBaseline() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        coordinator.update(\.manualActivationBehavior, to: .updateConfigOnly, field: .manualActivationBehavior)

        var externalConfig = self.makeConfig()
        externalConfig.openAI.manualActivationBehavior = .launchNewInstance

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(coordinator.draft.manualActivationBehavior, .updateConfigOnly)
        XCTAssertEqual(
            coordinator.makeSaveRequests().openAIAccount,
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha", "acct_beta"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort,
                manualActivationBehavior: .updateConfigOnly
            )
        )
    }

    func testReconcileExternalStateMergesNewAccountsIntoEditedOrder() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )
        coordinator.setAccountOrder(["acct_beta", "acct_alpha"])

        var externalConfig = self.makeConfig()
        externalConfig.setOpenAIAccountOrder(["acct_alpha", "acct_beta", "acct_gamma"])
        let updatedAccounts = initialAccounts + [
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: updatedAccounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(coordinator.draft.accountOrder, ["acct_beta", "acct_alpha", "acct_gamma"])
        XCTAssertEqual(coordinator.orderedAccounts.map(\.id), ["acct_beta", "acct_alpha", "acct_gamma"])
    }

    func testReconcileExternalStateDropsRemovedAccountsFromEditedOrder() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(accountOrder: ["acct_alpha", "acct_beta", "acct_gamma"]),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )
        coordinator.setAccountOrder(["acct_gamma", "acct_beta", "acct_alpha"])

        let updatedAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]
        let externalConfig = self.makeConfig(accountOrder: ["acct_alpha", "acct_gamma"])

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: updatedAccounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(coordinator.draft.accountOrder, ["acct_gamma", "acct_alpha"])
        XCTAssertEqual(coordinator.orderedAccounts.map(\.id), ["acct_gamma", "acct_alpha"])
    }

    func testRecordsPageNavigationDoesNotDirtySettings() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let baseConfig = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(
            config: baseConfig,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectedPage = .records

        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertEqual(coordinator.makeSaveRequests(), SettingsSaveRequests())
        XCTAssertEqual(
            coordinator.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.4"]
            )
        )
    }

    func testSavingFromRecordsPageDoesNotEmitAdditionalSettingsRequests() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectedPage = .records

        let requests = try coordinator.save(using: sink)

        XCTAssertEqual(requests, SettingsSaveRequests())
        XCTAssertTrue(sink.appliedRequests.isEmpty)
    }

    private func makeConfig(
        accountOrder: [String] = ["acct_alpha", "acct_beta"],
        accountOrderingMode: CodexBarOpenAIAccountOrderingMode = .quotaSort,
        modelPricing: [String: CodexBarModelPricing] = [:]
    ) -> CodexBarConfig {
        let alpha = CodexBarProviderAccount(
            id: "acct_alpha",
            kind: .oauthTokens,
            label: "alpha@example.com",
            email: "alpha@example.com",
            openAIAccountId: "acct_alpha",
            accessToken: "access-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha"
        )
        let beta = CodexBarProviderAccount(
            id: "acct_beta",
            kind: .oauthTokens,
            label: "beta@example.com",
            email: "beta@example.com",
            openAIAccountId: "acct_beta",
            accessToken: "access-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta"
        )
        let gamma = CodexBarProviderAccount(
            id: "acct_gamma",
            kind: .oauthTokens,
            label: "gamma@example.com",
            email: "gamma@example.com",
            openAIAccountId: "acct_gamma",
            accessToken: "access-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma"
        )

        return CodexBarConfig(
            active: CodexBarActiveSelection(
                providerId: "openai-oauth",
                accountId: "acct_alpha"
            ),
            modelPricing: modelPricing,
            openAI: CodexBarOpenAISettings(
                accountOrder: accountOrder,
                accountOrderingMode: accountOrderingMode,
                manualActivationBehavior: .updateConfigOnly
            ),
            providers: [
                CodexBarProvider(
                    id: "openai-oauth",
                    kind: .openAIOAuth,
                    label: "OpenAI",
                    activeAccountId: "acct_alpha",
                    accounts: [alpha, beta, gamma]
                )
            ]
        )
    }

    private func makeAccount(email: String, accountId: String) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            accessToken: "access-\(accountId)",
            refreshToken: "refresh-\(accountId)",
            idToken: "id-\(accountId)"
        )
    }
}

@MainActor
private final class TestSettingsSaveSink: SettingsSaveRequestApplying {
    private(set) var config: CodexBarConfig
    private(set) var appliedRequests: [SettingsSaveRequests] = []

    init(config: CodexBarConfig) {
        self.config = config
    }

    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        self.appliedRequests.append(requests)
        try SettingsSaveRequestApplier.apply(requests, to: &self.config)
    }
}

private struct FailingSettingsSaveSink: SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        throw TestSaveError.failed
    }

    private enum TestSaveError: LocalizedError {
        case failed

        var errorDescription: String? { "save failed" }
    }
}
