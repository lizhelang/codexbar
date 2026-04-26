import Foundation

private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try? container.decode(Value.self)
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyStringEnum<T>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T
    ) throws -> T where T: RawRepresentable, T.RawValue == String {
        guard let rawValue = try self.decodeIfPresent(String.self, forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.isEmpty == false,
              let value = T(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }
}

enum CodexBarProviderKind: String, Codable {
    case openAIOAuth = "openai_oauth"
    case openAICompatible = "openai_compatible"
    case openRouter = "openrouter"
}

enum CodexBarUsageDisplayMode: String, Codable, CaseIterable, Identifiable {
    case remaining
    case used

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .remaining:
            return L.remainingUsageDisplay
        case .used:
            return L.usedQuotaDisplay
        }
    }

    var badgeTitle: String {
        switch self {
        case .remaining:
            return L.remainingShort
        case .used:
            return L.usedShort
        }
    }
}

enum CodexBarAccountKind: String, Codable {
    case oauthTokens = "oauth_tokens"
    case apiKey = "api_key"
}

struct CodexBarGlobalSettings: Codable {
    var defaultModel: String
    var reviewModel: String
    var reasoningEffort: String

    init(defaultModel: String = "gpt-5.4", reviewModel: String = "gpt-5.4", reasoningEffort: String = "xhigh") {
        self.defaultModel = defaultModel
        self.reviewModel = reviewModel
        self.reasoningEffort = reasoningEffort
    }
}

struct CodexBarActiveSelection: Codable, Equatable {
    var providerId: String?
    var accountId: String?
}

struct CodexBarDesktopSettings: Codable, Equatable {
    var preferredCodexAppPath: String?

    enum CodingKeys: String, CodingKey {
        case preferredCodexAppPath
    }

    init(preferredCodexAppPath: String? = nil) {
        self.preferredCodexAppPath = Self.normalizedPreferredCodexAppPath(preferredCodexAppPath)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preferredCodexAppPath = Self.normalizedPreferredCodexAppPath(
            try container.decodeIfPresent(String.self, forKey: .preferredCodexAppPath)
        )
    }

    private static func normalizedPreferredCodexAppPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

struct CodexBarModelPricing: Codable, Equatable {
    var inputUSDPerToken: Double
    var cachedInputUSDPerToken: Double
    var outputUSDPerToken: Double

    enum CodingKeys: String, CodingKey {
        case inputUSDPerToken
        case cachedInputUSDPerToken
        case outputUSDPerToken
    }

    static let zero = CodexBarModelPricing(
        inputUSDPerToken: 0,
        cachedInputUSDPerToken: 0,
        outputUSDPerToken: 0
    )

    init(
        inputUSDPerToken: Double,
        cachedInputUSDPerToken: Double,
        outputUSDPerToken: Double
    ) {
        self.inputUSDPerToken = Self.sanitizedPrice(inputUSDPerToken)
        self.cachedInputUSDPerToken = Self.sanitizedPrice(cachedInputUSDPerToken)
        self.outputUSDPerToken = Self.sanitizedPrice(outputUSDPerToken)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputUSDPerToken: try container.decodeIfPresent(Double.self, forKey: .inputUSDPerToken) ?? 0,
            cachedInputUSDPerToken: try container.decodeIfPresent(Double.self, forKey: .cachedInputUSDPerToken) ?? 0,
            outputUSDPerToken: try container.decodeIfPresent(Double.self, forKey: .outputUSDPerToken) ?? 0
        )
    }

    private static func sanitizedPrice(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 0 }
        return value
    }
}

enum CodexBarOpenAIManualActivationBehavior: String, Codable, CaseIterable, Identifiable {
    case updateConfigOnly
    case launchNewInstance

    var id: String { self.rawValue }
}

enum CodexBarOpenAIAccountUsageMode: String, Codable, CaseIterable, Identifiable {
    case switchAccount = "switch"
    case aggregateGateway = "aggregate_gateway"

    var id: String { self.rawValue }

    var menuToggleTitle: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitchShort
        case .aggregateGateway:
            return L.accountUsageModeAggregateShort
        }
    }
}

enum CodexBarOpenAIAccountOrderingMode: String, Codable, CaseIterable, Identifiable {
    case quotaSort
    case manual

    var id: String { self.rawValue }
}

struct CodexBarOpenAISettings: Codable, Equatable {
    struct QuotaSortSettings: Codable, Equatable {
        static let plusRelativeWeightRange = 1.0...20.0
        static let proRelativeToPlusRange = 5.0...30.0
        static let teamRelativeToPlusRange = 1.0...3.0

        var plusRelativeWeight: Double
        var proRelativeToPlusMultiplier: Double
        var teamRelativeToPlusMultiplier: Double

        enum CodingKeys: String, CodingKey {
            case plusRelativeWeight
            case proRelativeToPlusMultiplier
            case teamRelativeToPlusMultiplier
        }

        nonisolated init(
            plusRelativeWeight: Double = 10,
            proRelativeToPlusMultiplier: Double = 10,
            teamRelativeToPlusMultiplier: Double = 1.5
        ) {
            self.plusRelativeWeight = Self.clamped(
                plusRelativeWeight,
                to: Self.plusRelativeWeightRange
            )
            self.proRelativeToPlusMultiplier = Self.clamped(
                proRelativeToPlusMultiplier,
                to: Self.proRelativeToPlusRange
            )
            self.teamRelativeToPlusMultiplier = Self.clamped(
                teamRelativeToPlusMultiplier,
                to: Self.teamRelativeToPlusRange
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                plusRelativeWeight: try container.decodeIfPresent(Double.self, forKey: .plusRelativeWeight) ?? 10,
                proRelativeToPlusMultiplier: try container.decodeIfPresent(Double.self, forKey: .proRelativeToPlusMultiplier) ?? 10,
                teamRelativeToPlusMultiplier: try container.decodeIfPresent(Double.self, forKey: .teamRelativeToPlusMultiplier) ?? 1.5
            )
        }

        nonisolated var proAbsoluteWeight: Double {
            self.plusRelativeWeight * self.proRelativeToPlusMultiplier
        }

        nonisolated var teamAbsoluteWeight: Double {
            self.plusRelativeWeight * self.teamRelativeToPlusMultiplier
        }

        nonisolated private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }
    }

    var accountOrder: [String]
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var switchModeSelection: CodexBarActiveSelection?
    var accountOrderingMode: CodexBarOpenAIAccountOrderingMode
    var manualActivationBehavior: CodexBarOpenAIManualActivationBehavior
    var usageDisplayMode: CodexBarUsageDisplayMode
    var quotaSort: QuotaSortSettings
    var interopProxiesJSON: String?

    enum CodingKeys: String, CodingKey {
        case accountOrder
        case accountUsageMode
        case switchModeSelection
        case accountOrderingMode
        case manualActivationBehavior
        case usageDisplayMode
        case quotaSort
        case interopProxiesJSON
    }

    init(
        accountOrder: [String] = [],
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount,
        switchModeSelection: CodexBarActiveSelection? = nil,
        accountOrderingMode: CodexBarOpenAIAccountOrderingMode = .quotaSort,
        manualActivationBehavior: CodexBarOpenAIManualActivationBehavior = .updateConfigOnly,
        usageDisplayMode: CodexBarUsageDisplayMode = .used,
        quotaSort: QuotaSortSettings = QuotaSortSettings(),
        interopProxiesJSON: String? = nil
    ) {
        self.accountOrder = accountOrder
        self.accountUsageMode = accountUsageMode
        self.switchModeSelection = switchModeSelection
        self.accountOrderingMode = accountOrderingMode
        self.manualActivationBehavior = manualActivationBehavior
        self.usageDisplayMode = usageDisplayMode
        self.quotaSort = quotaSort
        self.interopProxiesJSON = interopProxiesJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountOrder = try container.decodeIfPresent([String].self, forKey: .accountOrder) ?? []
        self.accountUsageMode = try container.decodeLossyStringEnum(
            CodexBarOpenAIAccountUsageMode.self,
            forKey: .accountUsageMode,
            default: .switchAccount
        )
        self.switchModeSelection = try container.decodeIfPresent(
            CodexBarActiveSelection.self,
            forKey: .switchModeSelection
        )
        self.accountOrderingMode = try container.decodeLossyStringEnum(
            CodexBarOpenAIAccountOrderingMode.self,
            forKey: .accountOrderingMode,
            default: .quotaSort
        )
        self.manualActivationBehavior = try container.decodeLossyStringEnum(
            CodexBarOpenAIManualActivationBehavior.self,
            forKey: .manualActivationBehavior,
            default: .updateConfigOnly
        )
        self.usageDisplayMode = try container.decodeLossyStringEnum(
            CodexBarUsageDisplayMode.self,
            forKey: .usageDisplayMode,
            default: .used
        )
        self.quotaSort = try container.decodeIfPresent(QuotaSortSettings.self, forKey: .quotaSort) ?? QuotaSortSettings()
        self.interopProxiesJSON = try container.decodeIfPresent(String.self, forKey: .interopProxiesJSON)
    }

    var preferredDisplayAccountOrder: [String] {
        self.accountOrderingMode == .manual ? self.accountOrder : []
    }
}

struct CodexBarProviderAccount: Codable, Identifiable, Equatable {
    var id: String
    var kind: CodexBarAccountKind
    var label: String

    var email: String?
    var openAIAccountId: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date?
    var oauthClientID: String?
    var tokenLastRefreshAt: Date?
    var lastRefresh: Date?

    var apiKey: String?
    var addedAt: Date?

    // Runtime quota snapshot for OAuth accounts.
    var planType: String?
    var primaryUsedPercent: Double?
    var secondaryUsedPercent: Double?
    var primaryResetAt: Date?
    var secondaryResetAt: Date?
    var primaryLimitWindowSeconds: Int?
    var secondaryLimitWindowSeconds: Int?
    var lastChecked: Date?
    var isSuspended: Bool?
    var tokenExpired: Bool?
    var organizationName: String?
    var interopProxyKey: String?
    var interopNotes: String?
    var interopConcurrency: Int?
    var interopPriority: Int?
    var interopRateMultiplier: Double?
    var interopAutoPauseOnExpired: Bool?
    var interopCredentialsJSON: String?
    var interopExtraJSON: String?

    init(
        id: String = UUID().uuidString,
        kind: CodexBarAccountKind,
        label: String,
        email: String? = nil,
        openAIAccountId: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        idToken: String? = nil,
        expiresAt: Date? = nil,
        oauthClientID: String? = nil,
        tokenLastRefreshAt: Date? = nil,
        lastRefresh: Date? = nil,
        apiKey: String? = nil,
        addedAt: Date? = nil,
        planType: String? = nil,
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        primaryLimitWindowSeconds: Int? = nil,
        secondaryLimitWindowSeconds: Int? = nil,
        lastChecked: Date? = nil,
        isSuspended: Bool? = nil,
        tokenExpired: Bool? = nil,
        organizationName: String? = nil,
        interopProxyKey: String? = nil,
        interopNotes: String? = nil,
        interopConcurrency: Int? = nil,
        interopPriority: Int? = nil,
        interopRateMultiplier: Double? = nil,
        interopAutoPauseOnExpired: Bool? = nil,
        interopCredentialsJSON: String? = nil,
        interopExtraJSON: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.email = email
        self.openAIAccountId = openAIAccountId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.oauthClientID = oauthClientID
        self.tokenLastRefreshAt = tokenLastRefreshAt
        self.lastRefresh = lastRefresh
        self.apiKey = apiKey
        self.addedAt = addedAt
        self.planType = planType
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.primaryLimitWindowSeconds = primaryLimitWindowSeconds
        self.secondaryLimitWindowSeconds = secondaryLimitWindowSeconds
        self.lastChecked = lastChecked
        self.isSuspended = isSuspended
        self.tokenExpired = tokenExpired
        self.organizationName = organizationName
        self.interopProxyKey = interopProxyKey
        self.interopNotes = interopNotes
        self.interopConcurrency = interopConcurrency
        self.interopPriority = interopPriority
        self.interopRateMultiplier = interopRateMultiplier
        self.interopAutoPauseOnExpired = interopAutoPauseOnExpired
        self.interopCredentialsJSON = interopCredentialsJSON
        self.interopExtraJSON = interopExtraJSON
    }

    var maskedAPIKey: String {
        guard let apiKey, apiKey.count > 8 else { return apiKey ?? "" }
        return String(apiKey.prefix(6)) + "..." + String(apiKey.suffix(4))
    }

    func asTokenAccount(isActive: Bool) -> TokenAccount? {
        self.rawTokenAccount(isActive: isActive)?.normalizedQuotaSnapshot()
    }

    func sanitizedQuotaSnapshot(now: Date = Date()) -> CodexBarProviderAccount {
        guard let normalized = self.rawTokenAccount(isActive: false)?.normalizedQuotaSnapshot(now: now) else {
            return self
        }

        var sanitized = self
        sanitized.planType = normalized.planType
        sanitized.primaryUsedPercent = normalized.primaryUsedPercent
        sanitized.secondaryUsedPercent = normalized.secondaryUsedPercent
        sanitized.primaryResetAt = normalized.primaryResetAt
        sanitized.secondaryResetAt = normalized.secondaryResetAt
        sanitized.primaryLimitWindowSeconds = normalized.primaryLimitWindowSeconds
        sanitized.secondaryLimitWindowSeconds = normalized.secondaryLimitWindowSeconds
        sanitized.lastChecked = normalized.lastChecked
        sanitized.isSuspended = normalized.isSuspended
        sanitized.tokenExpired = normalized.tokenExpired
        sanitized.organizationName = normalized.organizationName
        return sanitized
    }

    private func rawTokenAccount(isActive: Bool) -> TokenAccount? {
        guard self.kind == .oauthTokens,
              let accessToken = self.accessToken,
              let refreshToken = self.refreshToken,
              let idToken = self.idToken else { return nil }

        let localAccountID = self.id
        let remoteAccountID = self.openAIAccountId ?? localAccountID

        return TokenAccount(
            email: self.email ?? self.label,
            accountId: localAccountID,
            openAIAccountId: remoteAccountID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: self.expiresAt,
            oauthClientID: self.oauthClientID,
            planType: self.planType ?? "free",
            primaryUsedPercent: self.primaryUsedPercent ?? 0,
            secondaryUsedPercent: self.secondaryUsedPercent ?? 0,
            primaryResetAt: self.primaryResetAt,
            secondaryResetAt: self.secondaryResetAt,
            primaryLimitWindowSeconds: self.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: self.secondaryLimitWindowSeconds,
            lastChecked: self.lastChecked,
            isActive: isActive,
            isSuspended: self.isSuspended ?? false,
            tokenExpired: self.tokenExpired ?? false,
            tokenLastRefreshAt: self.tokenLastRefreshAt ?? self.lastRefresh,
            organizationName: self.organizationName
        )
    }

    static func fromTokenAccount(_ account: TokenAccount, existingID: String? = nil) -> CodexBarProviderAccount {
        let normalizedAccount = account.normalizedQuotaSnapshot()
        return CodexBarProviderAccount(
            id: existingID ?? normalizedAccount.accountId,
            kind: .oauthTokens,
            label: normalizedAccount.email.isEmpty ? normalizedAccount.accountId : normalizedAccount.email,
            email: normalizedAccount.email,
            openAIAccountId: normalizedAccount.remoteAccountId,
            accessToken: normalizedAccount.accessToken,
            refreshToken: normalizedAccount.refreshToken,
            idToken: normalizedAccount.idToken,
            expiresAt: normalizedAccount.expiresAt,
            oauthClientID: normalizedAccount.oauthClientID,
            tokenLastRefreshAt: normalizedAccount.tokenLastRefreshAt,
            lastRefresh: normalizedAccount.tokenLastRefreshAt,
            addedAt: Date(),
            planType: normalizedAccount.planType,
            primaryUsedPercent: normalizedAccount.primaryUsedPercent,
            secondaryUsedPercent: normalizedAccount.secondaryUsedPercent,
            primaryResetAt: normalizedAccount.primaryResetAt,
            secondaryResetAt: normalizedAccount.secondaryResetAt,
            primaryLimitWindowSeconds: normalizedAccount.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: normalizedAccount.secondaryLimitWindowSeconds,
            lastChecked: normalizedAccount.lastChecked,
            isSuspended: normalizedAccount.isSuspended,
            tokenExpired: normalizedAccount.tokenExpired,
            organizationName: normalizedAccount.organizationName
        )
    }
}

struct CodexBarOpenRouterModel: Codable, Equatable, Identifiable {
    var id: String
    var name: String

    init(id: String, name: String? = nil) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = normalizedID
        self.name = normalizedName?.isEmpty == false ? normalizedName! : normalizedID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name)
        )
    }
}

struct CodexBarProvider: Codable, Identifiable, Equatable {
    var id: String
    var kind: CodexBarProviderKind
    var label: String
    var enabled: Bool
    var baseURL: String?
    var defaultModel: String?
    var selectedModelID: String?
    var pinnedModelIDs: [String]
    var cachedModelCatalog: [CodexBarOpenRouterModel]
    var modelCatalogFetchedAt: Date?
    var activeAccountId: String?
    var accounts: [CodexBarProviderAccount]

    init(
        id: String,
        kind: CodexBarProviderKind,
        label: String,
        enabled: Bool = true,
        baseURL: String? = nil,
        defaultModel: String? = nil,
        selectedModelID: String? = nil,
        pinnedModelIDs: [String] = [],
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        modelCatalogFetchedAt: Date? = nil,
        activeAccountId: String? = nil,
        accounts: [CodexBarProviderAccount] = []
    ) {
        let normalizedDefaultModel = Self.normalizedDefaultModel(defaultModel)
        let normalizedSelectedModelID = Self.normalizedOpenRouterModelID(selectedModelID) ?? normalizedDefaultModel
        let normalizedPinnedModelIDs = Self.normalizedOpenRouterModelIDs(pinnedModelIDs)
        let resolvedPinnedModelIDs = Self.resolvedPinnedModelIDs(
            normalizedPinnedModelIDs,
            selectedModelID: normalizedSelectedModelID
        )
        self.id = id
        self.kind = kind
        self.label = label
        self.enabled = enabled
        self.baseURL = baseURL
        self.defaultModel = kind == .openRouter ? nil : normalizedDefaultModel
        self.selectedModelID = normalizedSelectedModelID
        self.pinnedModelIDs = resolvedPinnedModelIDs
        self.cachedModelCatalog = cachedModelCatalog
        self.modelCatalogFetchedAt = modelCatalogFetchedAt
        self.activeAccountId = activeAccountId
        self.accounts = accounts
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case enabled
        case baseURL
        case defaultModel
        case selectedModelID
        case pinnedModelIDs
        case cachedModelCatalog
        case modelCatalogFetchedAt
        case activeAccountId
        case accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = try container.decode(CodexBarProviderKind.self, forKey: .kind)
        let decodedDefaultModel = Self.normalizedDefaultModel(
            try container.decodeIfPresent(String.self, forKey: .defaultModel)
        )
        let decodedSelectedModelID = Self.normalizedOpenRouterModelID(
            try container.decodeIfPresent(String.self, forKey: .selectedModelID)
        ) ?? decodedDefaultModel
        let decodedPinnedModelIDs = Self.resolvedPinnedModelIDs(
            Self.normalizedOpenRouterModelIDs(
                try container.decodeIfPresent([String].self, forKey: .pinnedModelIDs) ?? []
            ),
            selectedModelID: decodedSelectedModelID
        )
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = decodedKind
        self.label = try container.decode(String.self, forKey: .label)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.defaultModel = decodedKind == .openRouter ? nil : decodedDefaultModel
        self.selectedModelID = decodedSelectedModelID
        self.pinnedModelIDs = decodedPinnedModelIDs
        self.cachedModelCatalog = try container.decodeIfPresent([CodexBarOpenRouterModel].self, forKey: .cachedModelCatalog) ?? []
        self.modelCatalogFetchedAt = try container.decodeIfPresent(Date.self, forKey: .modelCatalogFetchedAt)
        self.activeAccountId = try container.decodeIfPresent(String.self, forKey: .activeAccountId)
        self.accounts = (try container.decodeIfPresent(
            [FailableDecodable<CodexBarProviderAccount>].self,
            forKey: .accounts
        ) ?? []).compactMap(\.value)
    }

    var activeAccount: CodexBarProviderAccount? {
        if let activeAccountId, let found = self.accounts.first(where: { $0.id == activeAccountId }) {
            return found
        }
        return self.accounts.first
    }

    var hostLabel: String {
        if self.kind == .openRouter {
            return "openrouter.ai"
        }
        guard let baseURL,
              let host = URL(string: baseURL)?.host,
              !host.isEmpty else { return self.label }
        return host
    }

    var usesAPIKeyAuth: Bool {
        self.kind == .openAICompatible || self.kind == .openRouter
    }

    var openRouterEffectiveModelID: String? {
        guard self.kind == .openRouter else { return nil }
        return Self.normalizedOpenRouterModelID(self.selectedModelID)
    }

    var openRouterServiceableSelection: (account: CodexBarProviderAccount, modelID: String)? {
        guard self.kind == .openRouter,
              let account = self.activeAccount,
              let apiKey = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              apiKey.isEmpty == false,
              let modelID = self.openRouterEffectiveModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              modelID.isEmpty == false else {
            return nil
        }
        return (account, modelID)
    }

    fileprivate static func normalizedDefaultModel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    static func normalizedOpenRouterModelID(_ value: String?) -> String? {
        self.normalizedDefaultModel(value)
    }

    static func normalizedOpenRouterModelIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            guard let normalized = self.normalizedOpenRouterModelID(value),
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    static func resolvedPinnedModelIDs(
        _ pinnedModelIDs: [String],
        selectedModelID: String?
    ) -> [String] {
        var normalized = self.normalizedOpenRouterModelIDs(pinnedModelIDs)
        if let selectedModelID = self.normalizedOpenRouterModelID(selectedModelID),
           normalized.contains(selectedModelID) == false {
            normalized.insert(selectedModelID, at: 0)
        }
        return normalized
    }
}

struct CodexBarConfig: Codable {
    var version: Int
    var global: CodexBarGlobalSettings
    var active: CodexBarActiveSelection
    var desktop: CodexBarDesktopSettings
    var modelPricing: [String: CodexBarModelPricing]
    var openAI: CodexBarOpenAISettings
    var providers: [CodexBarProvider]

    init(
        version: Int = 1,
        global: CodexBarGlobalSettings = CodexBarGlobalSettings(),
        active: CodexBarActiveSelection = CodexBarActiveSelection(),
        desktop: CodexBarDesktopSettings = CodexBarDesktopSettings(),
        modelPricing: [String: CodexBarModelPricing] = [:],
        openAI: CodexBarOpenAISettings = CodexBarOpenAISettings(),
        providers: [CodexBarProvider] = []
    ) {
        self.version = version
        self.global = global
        self.active = active
        self.desktop = desktop
        self.modelPricing = modelPricing
        self.openAI = openAI
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case version
        case global
        case active
        case desktop
        case modelPricing
        case openAI
        case providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.global = try container.decodeIfPresent(CodexBarGlobalSettings.self, forKey: .global) ?? CodexBarGlobalSettings()
        self.active = try container.decodeIfPresent(CodexBarActiveSelection.self, forKey: .active) ?? CodexBarActiveSelection()
        self.desktop = try container.decodeIfPresent(CodexBarDesktopSettings.self, forKey: .desktop) ?? CodexBarDesktopSettings()
        self.modelPricing = try container.decodeIfPresent([String: CodexBarModelPricing].self, forKey: .modelPricing) ?? [:]
        self.openAI = try container.decodeIfPresent(CodexBarOpenAISettings.self, forKey: .openAI) ?? CodexBarOpenAISettings()
        self.providers = (try container.decodeIfPresent(
            [FailableDecodable<CodexBarProvider>].self,
            forKey: .providers
        ) ?? []).compactMap(\.value)
    }

    func provider(id: String?) -> CodexBarProvider? {
        guard let id else { return nil }
        return self.providers.first(where: { $0.id == id })
    }

    func activeProvider() -> CodexBarProvider? {
        self.provider(id: self.active.providerId)
    }

    func activeAccount() -> CodexBarProviderAccount? {
        self.activeProvider()?.accounts.first(where: { $0.id == self.active.accountId }) ?? self.activeProvider()?.activeAccount
    }

    func oauthProvider() -> CodexBarProvider? {
        self.providers.first(where: { $0.kind == .openAIOAuth })
    }

    func openRouterProvider() -> CodexBarProvider? {
        self.providers.first(where: { $0.kind == .openRouter })
    }
}

extension CodexBarConfig {
    mutating func upsertOAuthAccount(_ account: TokenAccount, activate: Bool) -> (storedAccount: CodexBarProviderAccount, syncCodex: Bool) {
        var provider = self.ensureOAuthProvider()
        let existingStoredAccount = provider.accounts.first(where: { $0.id == account.accountId })
        let storedAccountID: String

        if let index = provider.accounts.firstIndex(where: { $0.id == account.accountId }) {
            let existing = provider.accounts[index]
            var updated = CodexBarProviderAccount.fromTokenAccount(account, existingID: existing.id)
            updated.addedAt = existing.addedAt ?? Date()
            updated.label = existing.label
            updated.expiresAt = updated.expiresAt ?? existing.expiresAt
            updated.oauthClientID = updated.oauthClientID ?? existing.oauthClientID
            updated.tokenLastRefreshAt = updated.tokenLastRefreshAt ?? existing.tokenLastRefreshAt ?? existing.lastRefresh
            updated.lastRefresh = updated.tokenLastRefreshAt ?? existing.lastRefresh
            updated.interopProxyKey = existing.interopProxyKey
            updated.interopNotes = existing.interopNotes
            updated.interopConcurrency = existing.interopConcurrency
            updated.interopPriority = existing.interopPriority
            updated.interopRateMultiplier = existing.interopRateMultiplier
            updated.interopAutoPauseOnExpired = existing.interopAutoPauseOnExpired
            updated.interopCredentialsJSON = existing.interopCredentialsJSON
            updated.interopExtraJSON = existing.interopExtraJSON
            provider.accounts[index] = updated
            storedAccountID = updated.id
        } else {
            let created = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
            provider.accounts.append(created)
            storedAccountID = created.id
            self.appendOpenAIAccountOrderIfNeeded(accountID: created.id)
        }

        if provider.activeAccountId == nil {
            provider.activeAccountId = storedAccountID
        }

        if activate {
            provider.activeAccountId = storedAccountID
            self.active.providerId = provider.id
            self.active.accountId = storedAccountID
        }

        self.upsertProvider(provider)
        _ = self.normalizeSharedOpenAITeamOrganizationNames()
        self.normalizeOpenAIAccountOrder()

        let storedAccount = self.oauthProvider()?.accounts.first(where: { $0.id == storedAccountID })
            ?? provider.accounts.first(where: { $0.id == storedAccountID })
            ?? CodexBarProviderAccount.fromTokenAccount(account, existingID: storedAccountID)

        let credentialsChanged = self.oauthCredentialsChanged(
            existing: existingStoredAccount,
            updated: storedAccount
        )
        let syncCodex = activate || (
            self.active.providerId == provider.id &&
            self.active.accountId == storedAccount.id &&
            credentialsChanged
        )
        return (storedAccount, syncCodex)
    }

    mutating func activateOAuthAccount(accountID: String) throws -> CodexBarProviderAccount {
        guard var provider = self.oauthProvider() else {
            throw TokenStoreError.providerNotFound
        }
        guard let stored = self.oauthStoredAccount(in: provider, matching: accountID) else {
            throw TokenStoreError.accountNotFound
        }

        provider.activeAccountId = stored.id
        self.upsertProvider(provider)
        self.active.providerId = provider.id
        self.active.accountId = stored.id
        return stored
    }

    mutating func setOAuthPreferredAccount(accountID: String) throws {
        guard var provider = self.oauthProvider() else {
            throw TokenStoreError.providerNotFound
        }
        guard let stored = self.oauthStoredAccount(in: provider, matching: accountID) else {
            throw TokenStoreError.accountNotFound
        }

        provider.activeAccountId = stored.id
        self.upsertProvider(provider)
    }

    func oauthTokenAccounts() -> [TokenAccount] {
        guard let provider = self.oauthProvider() else { return [] }
        let isOAuthActive = self.active.providerId == provider.id

        return provider.accounts.compactMap { stored in
            stored.asTokenAccount(isActive: isOAuthActive && self.active.accountId == stored.id)
        }.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.email < rhs.email
        }
    }

    mutating func setOpenAIAccountOrder(_ accountOrder: [String]) {
        self.openAI.accountOrder = Self.uniqueAccountIDs(from: accountOrder)
        self.normalizeOpenAIAccountOrder()
    }

    mutating func upsertOpenRouterProvider(
        accountLabel: String,
        apiKey: String,
        activate: Bool
    ) throws -> CodexBarProviderAccount {
        let request = PortableCoreOpenRouterProviderAccountCreationRequest(
            accountLabel: accountLabel,
            apiKey: apiKey
        )
        let result =
            (try? RustPortableCoreAdapter.shared.planOpenRouterProviderAccountCreation(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreOpenRouterProviderAccountCreationResult.failClosed(
                request: request
            )
        guard result.valid,
              let normalizedLabel = result.accountLabel,
              let normalizedAPIKey = result.apiKey else {
            throw TokenStoreError.invalidInput
        }

        var provider = self.ensureOpenRouterProvider()
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: normalizedLabel,
            apiKey: normalizedAPIKey,
            addedAt: Date()
        )

        provider.accounts.append(account)
        provider.activeAccountId = account.id
        self.upsertProvider(provider)

        if activate {
            self.active.providerId = provider.id
            self.active.accountId = account.id
        } else if self.active.providerId == provider.id, self.active.accountId == nil {
            self.active.accountId = account.id
        }

        return account
    }

    mutating func activateOpenRouterAccount(accountID: String) throws -> CodexBarProviderAccount {
        guard var provider = self.openRouterProvider() else {
            throw TokenStoreError.providerNotFound
        }
        guard let stored = provider.accounts.first(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        provider.activeAccountId = stored.id
        self.upsertProvider(provider)
        self.active.providerId = provider.id
        self.active.accountId = stored.id
        return stored
    }

    mutating func setOpenRouterDefaultModel(_ value: String?) throws {
        try self.setOpenRouterSelectedModel(value)
    }

    mutating func setOpenRouterSelectedModel(_ value: String?) throws {
        guard var provider = self.openRouterProvider() else {
            throw TokenStoreError.providerNotFound
        }
        let request = PortableCoreOpenRouterModelSelectionPlanRequest(
            currentSelectedModelID: provider.selectedModelID,
            currentPinnedModelIDs: provider.pinnedModelIDs,
            currentCachedModelCatalog: provider.cachedModelCatalog.map(PortableCoreOpenRouterModelInput.legacy(from:)),
            currentFetchedAt: provider.modelCatalogFetchedAt?.timeIntervalSince1970,
            nextSelectedModelID: value,
            nextPinnedModelIDs: nil,
            nextCachedModelCatalog: nil,
            nextFetchedAt: nil
        )
        let plan =
            (try? RustPortableCoreAdapter.shared.planOpenRouterModelSelection(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreOpenRouterModelSelectionPlanResult.failClosed(
                request: request
            )
        provider.selectedModelID = plan.selectedModelID
        provider.pinnedModelIDs = plan.pinnedModelIDs
        self.upsertProvider(provider)
    }

    mutating func setOpenRouterModelSelection(
        selectedModelID: String?,
        pinnedModelIDs: [String],
        cachedModelCatalog: [CodexBarOpenRouterModel]? = nil,
        fetchedAt: Date? = nil
    ) throws {
        guard var provider = self.openRouterProvider() else {
            throw TokenStoreError.providerNotFound
        }

        let request = PortableCoreOpenRouterModelSelectionPlanRequest(
            currentSelectedModelID: provider.selectedModelID,
            currentPinnedModelIDs: provider.pinnedModelIDs,
            currentCachedModelCatalog: provider.cachedModelCatalog.map(PortableCoreOpenRouterModelInput.legacy(from:)),
            currentFetchedAt: provider.modelCatalogFetchedAt?.timeIntervalSince1970,
            nextSelectedModelID: selectedModelID,
            nextPinnedModelIDs: pinnedModelIDs,
            nextCachedModelCatalog: cachedModelCatalog?.map(PortableCoreOpenRouterModelInput.legacy(from:)),
            nextFetchedAt: fetchedAt?.timeIntervalSince1970
        )
        let plan =
            (try? RustPortableCoreAdapter.shared.planOpenRouterModelSelection(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreOpenRouterModelSelectionPlanResult.failClosed(
                request: request
            )
        provider.selectedModelID = plan.selectedModelID
        provider.pinnedModelIDs = plan.pinnedModelIDs
        provider.cachedModelCatalog = plan.cachedModelCatalog.map { $0.openRouterModel() }
        provider.modelCatalogFetchedAt = plan.fetchedAt.map(Date.init(timeIntervalSince1970:))
        self.upsertProvider(provider)
    }

    mutating func updateOpenRouterModelCatalog(
        _ models: [CodexBarOpenRouterModel],
        fetchedAt: Date
    ) throws {
        guard var provider = self.openRouterProvider() else {
            throw TokenStoreError.providerNotFound
        }
        let request = PortableCoreOpenRouterModelSelectionPlanRequest(
            currentSelectedModelID: provider.selectedModelID,
            currentPinnedModelIDs: provider.pinnedModelIDs,
            currentCachedModelCatalog: provider.cachedModelCatalog.map(PortableCoreOpenRouterModelInput.legacy(from:)),
            currentFetchedAt: provider.modelCatalogFetchedAt?.timeIntervalSince1970,
            nextSelectedModelID: provider.selectedModelID,
            nextPinnedModelIDs: nil,
            nextCachedModelCatalog: models.map(PortableCoreOpenRouterModelInput.legacy(from:)),
            nextFetchedAt: fetchedAt.timeIntervalSince1970
        )
        let plan =
            (try? RustPortableCoreAdapter.shared.planOpenRouterModelSelection(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreOpenRouterModelSelectionPlanResult.failClosed(
                request: request
            )
        provider.selectedModelID = plan.selectedModelID
        provider.pinnedModelIDs = plan.pinnedModelIDs
        provider.cachedModelCatalog = plan.cachedModelCatalog.map { $0.openRouterModel() }
        provider.modelCatalogFetchedAt = plan.fetchedAt.map(Date.init(timeIntervalSince1970:))
        self.upsertProvider(provider)
    }

    mutating func setOpenAIManualActivationBehavior(_ behavior: CodexBarOpenAIManualActivationBehavior) {
        self.openAI.manualActivationBehavior = behavior
    }

    mutating func setOpenAIAccountUsageMode(_ mode: CodexBarOpenAIAccountUsageMode) {
        self.openAI.accountUsageMode = mode
    }

    mutating func captureSwitchModeSelection() {
        guard let providerId = self.active.providerId,
              let accountId = self.active.accountId else {
            self.openAI.switchModeSelection = nil
            return
        }

        self.openAI.switchModeSelection = CodexBarActiveSelection(
            providerId: providerId,
            accountId: accountId
        )
    }

    mutating func restoreSwitchModeSelectionIfAvailable() {
        guard let selection = self.openAI.switchModeSelection,
              let provider = self.provider(id: selection.providerId),
              provider.accounts.contains(where: { $0.id == selection.accountId }) else {
            return
        }

        self.active = selection
    }

    mutating func setOpenAIAccountOrderingMode(_ mode: CodexBarOpenAIAccountOrderingMode) {
        self.openAI.accountOrderingMode = mode
    }

    mutating func removeOpenAIAccountOrder(accountID: String) {
        self.openAI.accountOrder.removeAll { $0 == accountID }
    }

    mutating func normalizeOpenAIAccountOrder() {
        let availableAccountIDs = self.oauthProvider()?.accounts.map(\.id) ?? []
        let availableAccountIDSet = Set(availableAccountIDs)

        var normalized: [String] = []
        var seen: Set<String> = []

        for accountID in self.openAI.accountOrder where availableAccountIDSet.contains(accountID) {
            guard seen.insert(accountID).inserted else { continue }
            normalized.append(accountID)
        }

        for accountID in availableAccountIDs where seen.insert(accountID).inserted {
            normalized.append(accountID)
        }

        self.openAI.accountOrder = normalized
    }

    @discardableResult
    mutating func normalizeSharedOpenAITeamOrganizationNames() -> Bool {
        guard let providerIndex = self.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return false
        }

        var provider = self.providers[providerIndex]
        let groupedIndices = Dictionary(
            grouping: provider.accounts.indices.compactMap { index -> (String, Int)? in
                let account = provider.accounts[index]
                guard Self.isSharedOpenAITeamAccount(account),
                      let sharedAccountID = Self.normalizedSharedOpenAIAccountID(for: account) else {
                    return nil
                }
                return (sharedAccountID, index)
            },
            by: \.0
        )

        var changed = false
        for indices in groupedIndices.values.map({ $0.map(\.1) }) {
            let sharedNames = Set(
                indices.compactMap { index in
                    Self.normalizedSharedOrganizationName(provider.accounts[index].organizationName)
                }
            )
            guard sharedNames.count == 1,
                  let sharedName = sharedNames.first else {
                continue
            }

            for index in indices {
                let account = provider.accounts[index]
                let normalizedName = Self.normalizedSharedOrganizationName(account.organizationName)

                if normalizedName == sharedName {
                    if account.organizationName != sharedName {
                        provider.accounts[index].organizationName = sharedName
                        changed = true
                    }
                    continue
                }

                guard normalizedName == nil else { continue }
                provider.accounts[index].organizationName = sharedName
                changed = true
            }
        }

        guard changed else { return false }
        self.providers[providerIndex] = provider
        return true
    }

    mutating func remapOAuthAccountReferences(using accountIDMapping: [String: String]) {
        guard accountIDMapping.isEmpty == false else { return }

        if let providerIndex = self.providers.firstIndex(where: { $0.kind == .openAIOAuth }) {
            var provider = self.providers[providerIndex]
            provider.accounts = provider.accounts.map { stored in
                var updated = stored
                if let remappedID = accountIDMapping[stored.id] {
                    updated.id = remappedID
                }
                return updated
            }
            if let activeAccountId = provider.activeAccountId,
               let remappedID = accountIDMapping[activeAccountId] {
                provider.activeAccountId = remappedID
            }
            self.providers[providerIndex] = provider

            if self.active.providerId == provider.id,
               let activeAccountId = self.active.accountId,
               let remappedID = accountIDMapping[activeAccountId] {
                self.active.accountId = remappedID
            }
        }

        self.openAI.accountOrder = Self.uniqueAccountIDs(
            from: self.openAI.accountOrder.map { accountIDMapping[$0] ?? $0 }
        )
        self.normalizeOpenAIAccountOrder()
    }

    private mutating func ensureOAuthProvider() -> CodexBarProvider {
        if let provider = self.oauthProvider() {
            return provider
        }
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            baseURL: nil
        )
        self.providers.append(provider)
        return provider
    }

    private mutating func ensureOpenRouterProvider() -> CodexBarProvider {
        if let provider = self.openRouterProvider() {
            return provider
        }
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true
        )
        self.providers.append(provider)
        return provider
    }

    private mutating func upsertProvider(_ provider: CodexBarProvider) {
        if let index = self.providers.firstIndex(where: { $0.id == provider.id }) {
            self.providers[index] = provider
        } else {
            self.providers.append(provider)
        }
    }

    private mutating func appendOpenAIAccountOrderIfNeeded(accountID: String) {
        guard self.openAI.accountOrder.contains(accountID) == false else { return }
        self.openAI.accountOrder.append(accountID)
    }

    private func oauthStoredAccount(in provider: CodexBarProvider, matching accountID: String) -> CodexBarProviderAccount? {
        if let stored = provider.accounts.first(where: { $0.id == accountID }) {
            return stored
        }

        let remoteMatches = provider.accounts.filter { $0.openAIAccountId == accountID }
        if remoteMatches.count == 1 {
            return remoteMatches[0]
        }
        return nil
    }

    private func oauthCredentialsChanged(
        existing: CodexBarProviderAccount?,
        updated: CodexBarProviderAccount
    ) -> Bool {
        guard let existing else { return true }
        return existing.accessToken != updated.accessToken ||
            existing.refreshToken != updated.refreshToken ||
            existing.idToken != updated.idToken ||
            existing.expiresAt != updated.expiresAt ||
            existing.oauthClientID != updated.oauthClientID ||
            existing.tokenLastRefreshAt != updated.tokenLastRefreshAt ||
            existing.openAIAccountId != updated.openAIAccountId
    }

    private static func uniqueAccountIDs(from accountIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return accountIDs.filter { seen.insert($0).inserted }
    }

    private static func uniqueOpenRouterModelCatalog(
        _ models: [CodexBarOpenRouterModel]
    ) -> [CodexBarOpenRouterModel] {
        var seen: Set<String> = []
        return models.compactMap { model in
            guard let normalizedID = CodexBarProvider.normalizedOpenRouterModelID(model.id),
                  seen.insert(normalizedID).inserted else {
                return nil
            }
            return CodexBarOpenRouterModel(id: normalizedID, name: model.name)
        }
    }

    private static func isSharedOpenAITeamAccount(_ account: CodexBarProviderAccount) -> Bool {
        guard account.kind == .oauthTokens else { return false }
        return self.normalizedPlanType(account.planType) == "team"
    }

    private static func normalizedPlanType(_ planType: String?) -> String {
        planType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedSharedOpenAIAccountID(
        for account: CodexBarProviderAccount
    ) -> String? {
        let accountID = (account.openAIAccountId ?? account.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return accountID.isEmpty ? nil : accountID
    }

    private static func normalizedSharedOrganizationName(_ organizationName: String?) -> String? {
        guard let organizationName = organizationName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              organizationName.isEmpty == false else {
            return nil
        }
        return organizationName
    }
}
