import Foundation

enum CodexBarProviderKind: String, Codable {
    case openAIOAuth = "openai_oauth"
    case openAICompatible = "openai_compatible"
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

struct CodexBarActiveSelection: Codable {
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

enum CodexBarOpenAIManualActivationBehavior: String, Codable, CaseIterable, Identifiable {
    case updateConfigOnly
    case launchNewInstance

    var id: String { self.rawValue }
}

enum CodexBarOpenAIAccountOrderingMode: String, Codable, CaseIterable, Identifiable {
    case quotaSort
    case manual

    var id: String { self.rawValue }
}

struct CodexBarOpenAISettings: Codable, Equatable {
    struct QuotaSortSettings: Codable, Equatable {
        static let plusRelativeWeightRange = 1.0...20.0
        static let teamRelativeToPlusRange = 1.0...3.0

        var plusRelativeWeight: Double
        var teamRelativeToPlusMultiplier: Double

        enum CodingKeys: String, CodingKey {
            case plusRelativeWeight
            case teamRelativeToPlusMultiplier
        }

        nonisolated init(
            plusRelativeWeight: Double = 10,
            teamRelativeToPlusMultiplier: Double = 1.5
        ) {
            self.plusRelativeWeight = Self.clamped(
                plusRelativeWeight,
                to: Self.plusRelativeWeightRange
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
                teamRelativeToPlusMultiplier: try container.decodeIfPresent(Double.self, forKey: .teamRelativeToPlusMultiplier) ?? 1.5
            )
        }

        nonisolated var teamAbsoluteWeight: Double {
            self.plusRelativeWeight * self.teamRelativeToPlusMultiplier
        }

        nonisolated private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }
    }

    var accountOrder: [String]
    var accountOrderingMode: CodexBarOpenAIAccountOrderingMode
    var manualActivationBehavior: CodexBarOpenAIManualActivationBehavior
    var usageDisplayMode: CodexBarUsageDisplayMode
    var quotaSort: QuotaSortSettings

    enum CodingKeys: String, CodingKey {
        case accountOrder
        case accountOrderingMode
        case manualActivationBehavior
        case usageDisplayMode
        case quotaSort
    }

    init(
        accountOrder: [String] = [],
        accountOrderingMode: CodexBarOpenAIAccountOrderingMode = .quotaSort,
        manualActivationBehavior: CodexBarOpenAIManualActivationBehavior = .updateConfigOnly,
        usageDisplayMode: CodexBarUsageDisplayMode = .used,
        quotaSort: QuotaSortSettings = QuotaSortSettings()
    ) {
        self.accountOrder = accountOrder
        self.accountOrderingMode = accountOrderingMode
        self.manualActivationBehavior = manualActivationBehavior
        self.usageDisplayMode = usageDisplayMode
        self.quotaSort = quotaSort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountOrder = try container.decodeIfPresent([String].self, forKey: .accountOrder) ?? []
        self.accountOrderingMode = try container.decodeIfPresent(
            CodexBarOpenAIAccountOrderingMode.self,
            forKey: .accountOrderingMode
        ) ?? .quotaSort
        self.manualActivationBehavior = try container.decodeIfPresent(
            CodexBarOpenAIManualActivationBehavior.self,
            forKey: .manualActivationBehavior
        ) ?? .updateConfigOnly
        self.usageDisplayMode = try container.decodeIfPresent(CodexBarUsageDisplayMode.self, forKey: .usageDisplayMode) ?? .used
        self.quotaSort = try container.decodeIfPresent(QuotaSortSettings.self, forKey: .quotaSort) ?? QuotaSortSettings()
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

    init(
        id: String = UUID().uuidString,
        kind: CodexBarAccountKind,
        label: String,
        email: String? = nil,
        openAIAccountId: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        idToken: String? = nil,
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
        organizationName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.email = email
        self.openAIAccountId = openAIAccountId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
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
    }

    var maskedAPIKey: String {
        guard let apiKey, apiKey.count > 8 else { return apiKey ?? "" }
        return String(apiKey.prefix(6)) + "..." + String(apiKey.suffix(4))
    }

    func asTokenAccount(isActive: Bool) -> TokenAccount? {
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
            expiresAt: nil,
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
            organizationName: self.organizationName
        )
    }

    static func fromTokenAccount(_ account: TokenAccount, existingID: String? = nil) -> CodexBarProviderAccount {
        CodexBarProviderAccount(
            id: existingID ?? account.accountId,
            kind: .oauthTokens,
            label: account.email.isEmpty ? account.accountId : account.email,
            email: account.email,
            openAIAccountId: account.remoteAccountId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            lastRefresh: Date(),
            addedAt: Date(),
            planType: account.planType,
            primaryUsedPercent: account.primaryUsedPercent,
            secondaryUsedPercent: account.secondaryUsedPercent,
            primaryResetAt: account.primaryResetAt,
            secondaryResetAt: account.secondaryResetAt,
            primaryLimitWindowSeconds: account.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: account.secondaryLimitWindowSeconds,
            lastChecked: account.lastChecked,
            isSuspended: account.isSuspended,
            tokenExpired: account.tokenExpired,
            organizationName: account.organizationName
        )
    }
}

struct CodexBarProvider: Codable, Identifiable, Equatable {
    var id: String
    var kind: CodexBarProviderKind
    var label: String
    var enabled: Bool
    var baseURL: String?
    var activeAccountId: String?
    var accounts: [CodexBarProviderAccount]

    init(
        id: String,
        kind: CodexBarProviderKind,
        label: String,
        enabled: Bool = true,
        baseURL: String? = nil,
        activeAccountId: String? = nil,
        accounts: [CodexBarProviderAccount] = []
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.enabled = enabled
        self.baseURL = baseURL
        self.activeAccountId = activeAccountId
        self.accounts = accounts
    }

    var activeAccount: CodexBarProviderAccount? {
        if let activeAccountId, let found = self.accounts.first(where: { $0.id == activeAccountId }) {
            return found
        }
        return self.accounts.first
    }

    var hostLabel: String {
        guard let baseURL,
              let host = URL(string: baseURL)?.host,
              !host.isEmpty else { return self.label }
        return host
    }
}

struct CodexBarConfig: Codable {
    var version: Int
    var global: CodexBarGlobalSettings
    var active: CodexBarActiveSelection
    var desktop: CodexBarDesktopSettings
    var openAI: CodexBarOpenAISettings
    var providers: [CodexBarProvider]

    init(
        version: Int = 1,
        global: CodexBarGlobalSettings = CodexBarGlobalSettings(),
        active: CodexBarActiveSelection = CodexBarActiveSelection(),
        desktop: CodexBarDesktopSettings = CodexBarDesktopSettings(),
        openAI: CodexBarOpenAISettings = CodexBarOpenAISettings(),
        providers: [CodexBarProvider] = []
    ) {
        self.version = version
        self.global = global
        self.active = active
        self.desktop = desktop
        self.openAI = openAI
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case version
        case global
        case active
        case desktop
        case openAI
        case providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.global = try container.decodeIfPresent(CodexBarGlobalSettings.self, forKey: .global) ?? CodexBarGlobalSettings()
        self.active = try container.decodeIfPresent(CodexBarActiveSelection.self, forKey: .active) ?? CodexBarActiveSelection()
        self.desktop = try container.decodeIfPresent(CodexBarDesktopSettings.self, forKey: .desktop) ?? CodexBarDesktopSettings()
        self.openAI = try container.decodeIfPresent(CodexBarOpenAISettings.self, forKey: .openAI) ?? CodexBarOpenAISettings()
        self.providers = try container.decodeIfPresent([CodexBarProvider].self, forKey: .providers) ?? []
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
}

extension CodexBarConfig {
    mutating func upsertOAuthAccount(_ account: TokenAccount, activate: Bool) -> (storedAccount: CodexBarProviderAccount, syncCodex: Bool) {
        var provider = self.ensureOAuthProvider()
        let storedAccount: CodexBarProviderAccount

        if let index = provider.accounts.firstIndex(where: { $0.id == account.accountId }) {
            let existing = provider.accounts[index]
            var updated = CodexBarProviderAccount.fromTokenAccount(account, existingID: existing.id)
            updated.addedAt = existing.addedAt ?? Date()
            updated.label = existing.label
            provider.accounts[index] = updated
            storedAccount = updated
        } else {
            let created = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
            provider.accounts.append(created)
            storedAccount = created
            self.appendOpenAIAccountOrderIfNeeded(accountID: created.id)
        }

        if provider.activeAccountId == nil {
            provider.activeAccountId = storedAccount.id
        }

        if activate {
            provider.activeAccountId = storedAccount.id
            self.active.providerId = provider.id
            self.active.accountId = storedAccount.id
        }

        self.upsertProvider(provider)
        self.normalizeOpenAIAccountOrder()

        let syncCodex = activate || (
            self.active.providerId == provider.id &&
            self.active.accountId == storedAccount.id
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

    mutating func setOpenAIManualActivationBehavior(_ behavior: CodexBarOpenAIManualActivationBehavior) {
        self.openAI.manualActivationBehavior = behavior
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

    private static func uniqueAccountIDs(from accountIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return accountIDs.filter { seen.insert($0).inserted }
    }
}
