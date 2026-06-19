import Combine
import Foundation

protocol SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws
}

extension TokenStore: SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        try self.saveSettings(requests)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case accounts
    case records
    case usage
    case updates

    var id: String { self.rawValue }
}

struct SettingsWindowDraft: Equatable {
    var accountOrder: [String]
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var accountOrderingMode: CodexBarOpenAIAccountOrderingMode
    var manualActivationBehavior: CodexBarOpenAIManualActivationBehavior
    var remoteConnectionAccountID: String?
    var remoteConnectionAccounts: [SettingsOpenAIAccountOrderItem]
    var hybridTargetSelection: CodexBarHybridTargetSelection?
    var hybridTargetOptions: [SettingsHybridTargetOption]
    var usageDisplayMode: CodexBarUsageDisplayMode
    var plusRelativeWeight: Double
    var proRelativeToPlusMultiplier: Double
    var teamRelativeToPlusMultiplier: Double
    var modelPricing: [String: CodexBarModelPricing]
    var preferredCodexAppPath: String?

    init(config: CodexBarConfig, accounts: [TokenAccount], historicalModels: [String]) {
        let normalizedHistoricalModels = Self.settingsHistoricalModels(
            config: config,
            historicalModels: historicalModels
        )
        self.accountOrder = Self.normalizedAccountOrder(
            config.openAI.accountOrder,
            availableAccountIDs: accounts.map(\.accountId)
        )
        self.accountUsageMode = config.openAI.accountUsageMode
        self.accountOrderingMode = config.openAI.accountOrderingMode
        self.manualActivationBehavior = config.openAI.manualActivationBehavior
        self.remoteConnectionAccountID = Self.normalizedRemoteConnectionAccountID(
            config.openAI.remoteConnectionAccountID
        )
        self.remoteConnectionAccounts = Self.remoteConnectionAccountItems(config: config)
        self.hybridTargetSelection = Self.normalizedHybridTargetSelection(config.openAI.hybridTargetSelection)
        self.hybridTargetOptions = Self.hybridTargetOptions(config: config)
        self.usageDisplayMode = config.openAI.usageDisplayMode
        self.plusRelativeWeight = config.openAI.quotaSort.plusRelativeWeight
        self.proRelativeToPlusMultiplier = config.openAI.quotaSort.proRelativeToPlusMultiplier
        self.teamRelativeToPlusMultiplier = config.openAI.quotaSort.teamRelativeToPlusMultiplier
        self.modelPricing = Self.effectiveModelPricing(
            config: config,
            historicalModels: normalizedHistoricalModels
        )
        self.preferredCodexAppPath = config.desktop.preferredCodexAppPath
    }

    static func mergedAccountOrder(
        preferredAccountOrder: [String],
        fallbackAccountOrder: [String],
        availableAccountIDs: [String]
    ) -> [String] {
        self.normalizedAccountOrder(
            preferredAccountOrder + fallbackAccountOrder,
            availableAccountIDs: availableAccountIDs
        )
    }

    private static func normalizedAccountOrder(_ accountOrder: [String], availableAccountIDs: [String]) -> [String] {
        let availableSet = Set(availableAccountIDs)
        var normalized: [String] = []
        var seen: Set<String> = []

        for accountID in accountOrder where availableSet.contains(accountID) {
            guard seen.insert(accountID).inserted else { continue }
            normalized.append(accountID)
        }

        for accountID in availableAccountIDs where seen.insert(accountID).inserted {
            normalized.append(accountID)
        }

        return normalized
    }

    static func normalizedRemoteConnectionAccountID(_ accountID: String?) -> String? {
        guard let trimmed = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    static func remoteConnectionAccountItems(config: CodexBarConfig) -> [SettingsOpenAIAccountOrderItem] {
        config.remoteConnectionTokenAccounts().map { account in
            SettingsOpenAIAccountOrderItem(
                id: account.accountId,
                title: Self.accountTitle(forRemoteConnectionAccount: account),
                detail: Self.accountDetail(forRemoteConnectionAccount: account)
            )
        }
    }

    static func normalizedHybridTargetSelection(
        _ selection: CodexBarHybridTargetSelection?
    ) -> CodexBarHybridTargetSelection? {
        guard let selection, selection.isEmpty == false else { return nil }
        return selection
    }

    static func hybridTargetOptions(config: CodexBarConfig) -> [SettingsHybridTargetOption] {
        var options: [SettingsHybridTargetOption] = []
        if let provider = config.oauthProvider(), provider.accounts.isEmpty == false {
            options.append(
                SettingsHybridTargetOption(
                    selection: CodexBarHybridTargetSelection(providerId: provider.id),
                    title: L.requestTargetOpenAIPool,
                    detail: L.requestTargetOpenAIPoolDetail
                )
            )
        }
        for provider in config.providers where provider.kind == .openAICompatible || provider.kind == .openRouter {
            for account in provider.accounts {
                options.append(
                    SettingsHybridTargetOption(
                        selection: CodexBarHybridTargetSelection(
                            providerId: provider.id,
                            accountId: account.id
                        ),
                        title: "\(provider.label) · \(account.label)",
                        detail: provider.kind == .openRouter
                            ? (provider.openRouterEffectiveModelID ?? L.requestTargetMissingModel)
                            : (provider.baseURL ?? provider.hostLabel)
                    )
                )
            }
        }
        return options
    }

    private static func accountTitle(forRemoteConnectionAccount account: TokenAccount) -> String {
        SettingsOpenAIAccountTitlePresentation.title(for: account, preference: .email)
    }

    private static func accountDetail(forRemoteConnectionAccount account: TokenAccount) -> String {
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false {
            return organizationName
        }
        return account.accountId
    }

    static func normalizedHistoricalModels(_ historicalModels: [String]) -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []

        for model in historicalModels {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  seen.insert(trimmed).inserted else {
                continue
            }
            normalized.append(trimmed)
        }

        return normalized.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func mergedHistoricalModels(
        preferredHistoricalModels: [String],
        fallbackHistoricalModels: [String]
    ) -> [String] {
        self.normalizedHistoricalModels(
            preferredHistoricalModels + fallbackHistoricalModels
        )
    }

    static func effectiveModelPricing(
        config: CodexBarConfig,
        historicalModels: [String]
    ) -> [String: CodexBarModelPricing] {
        Dictionary(uniqueKeysWithValues: historicalModels.map { model in
            (
                model,
                LocalCostPricing.effectivePricing(
                    for: model,
                    customPricingByModel: config.modelPricing
                )
            )
        })
    }

    static func settingsHistoricalModels(
        config: CodexBarConfig,
        historicalModels: [String]
    ) -> [String] {
        self.mergedHistoricalModels(
            preferredHistoricalModels: historicalModels,
            fallbackHistoricalModels: Array(config.modelPricing.keys)
        )
    }
}

private enum SettingsOpenAIAccountTitlePreference {
    case organization
    case email
}

private enum SettingsOpenAIAccountTitlePresentation {
    static func title(
        for account: TokenAccount,
        preference: SettingsOpenAIAccountTitlePreference
    ) -> String {
        "\(self.baseTitle(for: account, preference: preference)) · \(self.planDisplayName(for: account))"
    }

    private static func baseTitle(
        for account: TokenAccount,
        preference: SettingsOpenAIAccountTitlePreference
    ) -> String {
        switch preference {
        case .organization:
            return self.baseTitlePreferOrganization(for: account)
        case .email:
            return self.baseTitlePreferEmail(for: account)
        }
    }

    private static func baseTitlePreferOrganization(for account: TokenAccount) -> String {
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false {
            return organizationName
        }
        if account.email.isEmpty == false {
            return account.email
        }
        return account.accountId
    }

    private static func baseTitlePreferEmail(for account: TokenAccount) -> String {
        if account.email.isEmpty == false {
            return account.email
        }
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false {
            return organizationName
        }
        return account.accountId
    }

    private static func planDisplayName(for account: TokenAccount) -> String {
        let normalized = account.planType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? "free" : normalized
    }
}

struct SettingsOpenAIAccountOrderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

struct SettingsHybridTargetOption: Identifiable, Equatable {
    let selection: CodexBarHybridTargetSelection
    let title: String
    let detail: String

    var id: String {
        [
            self.selection.providerId ?? "",
            self.selection.accountId ?? "",
            self.selection.modelId ?? "",
        ].joined(separator: "::")
    }
}

enum SettingsDirtyField: Hashable {
    case accountOrder
    case accountUsageMode
    case accountOrderingMode
    case manualActivationBehavior
    case remoteConnectionAccountID
    case hybridTargetSelection
    case usageDisplayMode
    case plusRelativeWeight
    case proRelativeToPlusMultiplier
    case teamRelativeToPlusMultiplier
    case modelPricing
    case preferredCodexAppPath
}

@MainActor
final class SettingsWindowCoordinator: ObservableObject {
    @Published var selectedPage: SettingsPage
    @Published var draft: SettingsWindowDraft
    @Published var validationMessage: String?
    @Published private(set) var historicalModels: [String]

    private var accounts: [TokenAccount]
    private var baseline: SettingsWindowDraft
    private var dirtyFields: Set<SettingsDirtyField> = []

    init(
        config: CodexBarConfig,
        accounts: [TokenAccount],
        historicalModels: [String],
        selectedPage: SettingsPage = .accounts
    ) {
        let normalizedHistoricalModels = SettingsWindowDraft.settingsHistoricalModels(
            config: config,
            historicalModels: historicalModels
        )
        let draft = SettingsWindowDraft(
            config: config,
            accounts: accounts,
            historicalModels: normalizedHistoricalModels
        )
        self.selectedPage = selectedPage
        self.draft = draft
        self.historicalModels = normalizedHistoricalModels
        self.accounts = accounts
        self.baseline = draft
        self.validationMessage = nil
    }

    var hasChanges: Bool {
        self.makeSaveRequests().isEmpty == false
    }

    var orderedAccounts: [SettingsOpenAIAccountOrderItem] {
        let accountByID = Dictionary(uniqueKeysWithValues: self.accounts.map { ($0.accountId, $0) })
        return self.draft.accountOrder.compactMap { accountID in
            guard let account = accountByID[accountID] else { return nil }
            return SettingsOpenAIAccountOrderItem(
                id: accountID,
                title: Self.accountTitle(for: account),
                detail: Self.accountDetail(for: account)
            )
        }
    }

    var remoteConnectionAccounts: [SettingsOpenAIAccountOrderItem] {
        let mainIDs = Set(self.orderedAccounts.map(\.id))
        return self.draft.remoteConnectionAccounts.filter { mainIDs.contains($0.id) == false }
    }

    var remoteConnectionSelectableAccounts: [SettingsOpenAIAccountOrderItem] {
        let accountByID = Dictionary(uniqueKeysWithValues: self.accounts.map { ($0.accountId, $0) })
        return self.draft.accountOrder.compactMap { accountID in
            guard let account = accountByID[accountID] else { return nil }
            return SettingsOpenAIAccountOrderItem(
                id: accountID,
                title: Self.accountTitleForRemoteConnectionPicker(for: account),
                detail: Self.accountDetailForRemoteConnectionPicker(for: account)
            )
        }
    }

    var showsManualAccountOrderSection: Bool {
        self.draft.accountOrderingMode == .manual
    }

    var showsManualActivationBehaviorSection: Bool {
        false
    }

    var showsCodexAppPathSection: Bool {
        false
    }

    var showsHybridTargetSection: Bool {
        true
    }

    func moveAccount(accountID: String, offset: Int) {
        guard let currentIndex = self.draft.accountOrder.firstIndex(of: accountID) else { return }
        let targetIndex = currentIndex + offset
        guard self.draft.accountOrder.indices.contains(targetIndex) else { return }
        self.draft.accountOrder.swapAt(currentIndex, targetIndex)
        self.dirtyFields.insert(.accountOrder)
    }

    func setAccountOrder(_ accountOrder: [String]) {
        self.draft.accountOrder = accountOrder
        self.dirtyFields.insert(.accountOrder)
    }

    func update<Value>(
        _ keyPath: WritableKeyPath<SettingsWindowDraft, Value>,
        to value: Value,
        field: SettingsDirtyField
    ) {
        self.draft[keyPath: keyPath] = value
        self.dirtyFields.insert(field)
    }

    func updateModelPricing(for model: String, pricing: CodexBarModelPricing) {
        self.draft.modelPricing[model] = pricing
        self.dirtyFields.insert(.modelPricing)
    }

    func saveAndClose(
        using sink: SettingsSaveRequestApplying,
        onClose: () -> Void
    ) {
        do {
            _ = try self.save(using: sink)
            onClose()
        } catch {
            self.validationMessage = error.localizedDescription
        }
    }

    func save(using sink: SettingsSaveRequestApplying) throws -> SettingsSaveRequests {
        let requests = self.makeSaveRequests()
        guard requests.isEmpty == false else { return requests }
        try sink.applySettingsSaveRequests(requests)
        self.baseline = self.draft
        self.dirtyFields.removeAll()
        self.validationMessage = nil
        return requests
    }

    func cancelAndClose(onClose: () -> Void) {
        self.cancel()
        onClose()
    }

    func cancel() {
        self.draft = self.baseline
        self.dirtyFields.removeAll()
        self.validationMessage = nil
    }

    func reconcileExternalState(
        config: CodexBarConfig,
        accounts: [TokenAccount],
        historicalModels: [String]
    ) {
        let normalizedHistoricalModels = SettingsWindowDraft.settingsHistoricalModels(
            config: config,
            historicalModels: historicalModels
        )
        let externalDraft = SettingsWindowDraft(
            config: config,
            accounts: accounts,
            historicalModels: normalizedHistoricalModels
        )
        self.accounts = accounts

        if self.dirtyFields.contains(.accountOrder) == false {
            self.draft.accountOrder = externalDraft.accountOrder
        } else {
            self.draft.accountOrder = SettingsWindowDraft.mergedAccountOrder(
                preferredAccountOrder: self.draft.accountOrder,
                fallbackAccountOrder: externalDraft.accountOrder,
                availableAccountIDs: accounts.map(\.accountId)
            )
        }
        self.baseline.accountOrder = externalDraft.accountOrder
        self.draft.remoteConnectionAccounts = externalDraft.remoteConnectionAccounts
        self.baseline.remoteConnectionAccounts = externalDraft.remoteConnectionAccounts
        self.draft.hybridTargetOptions = externalDraft.hybridTargetOptions
        self.baseline.hybridTargetOptions = externalDraft.hybridTargetOptions

        self.reconcile(\.accountUsageMode, externalValue: externalDraft.accountUsageMode, field: .accountUsageMode)
        self.reconcile(\.accountOrderingMode, externalValue: externalDraft.accountOrderingMode, field: .accountOrderingMode)
        self.reconcile(\.manualActivationBehavior, externalValue: externalDraft.manualActivationBehavior, field: .manualActivationBehavior)
        self.reconcile(\.remoteConnectionAccountID, externalValue: externalDraft.remoteConnectionAccountID, field: .remoteConnectionAccountID)
        self.reconcile(\.hybridTargetSelection, externalValue: externalDraft.hybridTargetSelection, field: .hybridTargetSelection)
        self.reconcile(\.usageDisplayMode, externalValue: externalDraft.usageDisplayMode, field: .usageDisplayMode)
        self.reconcile(\.plusRelativeWeight, externalValue: externalDraft.plusRelativeWeight, field: .plusRelativeWeight)
        self.reconcile(\.proRelativeToPlusMultiplier, externalValue: externalDraft.proRelativeToPlusMultiplier, field: .proRelativeToPlusMultiplier)
        self.reconcile(\.teamRelativeToPlusMultiplier, externalValue: externalDraft.teamRelativeToPlusMultiplier, field: .teamRelativeToPlusMultiplier)
        self.reconcileModelPricing(
            externalValue: externalDraft.modelPricing,
            externalHistoricalModels: normalizedHistoricalModels
        )
        self.reconcile(\.preferredCodexAppPath, externalValue: externalDraft.preferredCodexAppPath, field: .preferredCodexAppPath)
    }

    func makeSaveRequests() -> SettingsSaveRequests {
        var requests = SettingsSaveRequests()

        if self.draft.accountOrder != self.baseline.accountOrder ||
            self.draft.accountUsageMode != self.baseline.accountUsageMode ||
            self.draft.accountOrderingMode != self.baseline.accountOrderingMode ||
            self.draft.manualActivationBehavior != self.baseline.manualActivationBehavior ||
            self.draft.remoteConnectionAccountID != self.baseline.remoteConnectionAccountID ||
            self.draft.hybridTargetSelection != self.baseline.hybridTargetSelection {
            requests.openAIAccount = OpenAIAccountSettingsUpdate(
                accountOrder: self.draft.accountOrder,
                accountUsageMode: self.draft.accountUsageMode,
                accountOrderingMode: self.draft.accountOrderingMode,
                manualActivationBehavior: .updateConfigOnly,
                remoteConnectionAccountID: self.draft.remoteConnectionAccountID,
                hybridTargetSelection: self.draft.hybridTargetSelection
            )
        }

        if self.draft.usageDisplayMode != self.baseline.usageDisplayMode ||
            self.draft.plusRelativeWeight != self.baseline.plusRelativeWeight ||
            self.draft.proRelativeToPlusMultiplier != self.baseline.proRelativeToPlusMultiplier ||
            self.draft.teamRelativeToPlusMultiplier != self.baseline.teamRelativeToPlusMultiplier {
            requests.openAIUsage = OpenAIUsageSettingsUpdate(
                usageDisplayMode: self.draft.usageDisplayMode,
                plusRelativeWeight: self.draft.plusRelativeWeight,
                proRelativeToPlusMultiplier: self.draft.proRelativeToPlusMultiplier,
                teamRelativeToPlusMultiplier: self.draft.teamRelativeToPlusMultiplier
            )
        }

        let modelPricingUpdate = self.makeModelPricingUpdate()
        if modelPricingUpdate.upserts.isEmpty == false || modelPricingUpdate.removals.isEmpty == false {
            requests.modelPricing = modelPricingUpdate
        }

        if self.draft.preferredCodexAppPath != self.baseline.preferredCodexAppPath {
            requests.desktop = DesktopSettingsUpdate(
                preferredCodexAppPath: self.draft.preferredCodexAppPath
            )
        }

        return requests
    }

    private static func accountTitle(for account: TokenAccount) -> String {
        SettingsOpenAIAccountTitlePresentation.title(for: account, preference: .organization)
    }

    private static func accountDetail(for account: TokenAccount) -> String {
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false,
           account.email.isEmpty == false {
            return account.email
        }
        return account.accountId
    }

    private static func accountTitleForRemoteConnectionPicker(for account: TokenAccount) -> String {
        SettingsOpenAIAccountTitlePresentation.title(for: account, preference: .email)
    }

    private static func accountDetailForRemoteConnectionPicker(for account: TokenAccount) -> String {
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false {
            return organizationName
        }
        return account.accountId
    }

    private func reconcile<Value: Equatable>(
        _ keyPath: WritableKeyPath<SettingsWindowDraft, Value>,
        externalValue: Value,
        field: SettingsDirtyField
    ) {
        if self.dirtyFields.contains(field) == false {
            self.draft[keyPath: keyPath] = externalValue
        }
        self.baseline[keyPath: keyPath] = externalValue
    }

    private func reconcileModelPricing(
        externalValue: [String: CodexBarModelPricing],
        externalHistoricalModels: [String]
    ) {
        if self.dirtyFields.contains(.modelPricing) == false {
            self.historicalModels = externalHistoricalModels
            self.draft.modelPricing = externalValue
        } else {
            let mergedHistoricalModels = SettingsWindowDraft.mergedHistoricalModels(
                preferredHistoricalModels: self.historicalModels,
                fallbackHistoricalModels: externalHistoricalModels
            )
            var mergedPricing = Dictionary(
                uniqueKeysWithValues: mergedHistoricalModels.map { model in
                    (model, externalValue[model] ?? self.draft.modelPricing[model] ?? .zero)
                }
            )

            for model in mergedHistoricalModels where self.historicalModels.contains(model) {
                if let editedPricing = self.draft.modelPricing[model] {
                    mergedPricing[model] = editedPricing
                }
            }

            self.historicalModels = mergedHistoricalModels
            self.draft.modelPricing = mergedPricing
        }

        self.baseline.modelPricing = Dictionary(
            uniqueKeysWithValues: self.historicalModels.map { model in
                (model, externalValue[model] ?? .zero)
            }
        )
    }

    private func makeModelPricingUpdate() -> ModelPricingSettingsUpdate {
        var upserts: [String: CodexBarModelPricing] = [:]
        var removals: [String] = []

        for model in self.historicalModels {
            let draftPricing = self.draft.modelPricing[model] ?? .zero
            let baselinePricing = self.baseline.modelPricing[model] ?? .zero
            guard draftPricing != baselinePricing else { continue }

            let defaultPricing = LocalCostPricing.defaultPricing(for: model) ?? .zero
            if draftPricing == defaultPricing {
                removals.append(model)
            } else {
                upserts[model] = draftPricing
            }
        }

        return ModelPricingSettingsUpdate(
            upserts: upserts,
            removals: removals
        )
    }
}
