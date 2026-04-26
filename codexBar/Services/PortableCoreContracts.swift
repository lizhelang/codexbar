import Foundation

enum PortableCoreOperation: String {
    case canonicalizeConfigAndAccounts
    case computeRouteRuntimeSnapshot
    case renderCodecBundle
    case planRefresh
    case applyRefreshOutcome
    case mergeUsageSuccess
    case parseWhamUsage
    case parseWhamUsageText
    case parseWhamOrganizationName
    case markUsageForbidden
    case markUsageTokenExpired
    case normalizeOpenRouterProviders
    case makeOpenRouterCompatPersistence
    case reconcileOAuthAuthSnapshot
    case normalizeSharedTeamOrganizationNames
    case normalizeReservedProviderIds
    case refreshOAuthAccountMetadata
    case parseLegacyCodexToml
    case parseProviderSecretsEnv
    case mergeInteropProxiesJSON
    case applyOAuthInteropContext
    case renderOAuthInteropExportAccounts
    case parseOAuthInteropBundle
    case parseOAuthAccountImport
    case parseLegacyOAuthCSV
    case parseAuthJsonSnapshot
    case resolveLegacyMigrationActiveSelection
    case planLegacyImportedProvider
    case normalizeOAuthAccountIdentities
    case sanitizeOAuthQuotaSnapshots
    case assembleOAuthProvider
    case describeFullRustCutoverContract
    case planStorePaths
    case planUsagePolling
    case resolveUsageModeTransition
    case decideSettingsSaveSync
    case decideOAuthAccountSync
    case resolveProviderRemovalTransition
    case resolveCustomProviderId
    case planCompatibleProviderCreation
    case planCompatibleProviderAccountCreation
    case planOpenRouterProviderAccountCreation
    case planOpenRouterModelSelection
    case summarizeLocalCost
    case resolveLocalCostPricing
    case resolveLocalCostCachePolicy
    case mergeHistoricalModels
    case collectHistoricalModels
    case attributeLiveSessions
    case attributeRunningThreads
    case parseSessionTranscript
    case resolveRecentOpenRouterModel
    case projectSessionUsageLedger
    case resolveGatewayTransportPolicy
    case classifyGatewayTransportFailure
    case resolveGatewayStatusPolicy
    case resolveGatewayStickyRecoveryPolicy
    case interpretGatewayProtocolSignal
    case decideGatewayProtocolPreview
    case parseGatewayRequest
    case planGatewayCandidates
    case resolveGatewayStickyKey
    case renderGatewayResponseHead
    case renderGatewayWebSocketHandshake
    case renderGatewayWebSocketFrame
    case renderGatewayWebSocketClosePayload
    case parseGatewayWebSocketFrame
    case validateGatewayWebSocketReady
    case bindGatewayStickyState
    case clearGatewayStickyState
    case applyGatewayRuntimeBlock
    case normalizeGatewayState
    case normalizeOpenAIResponsesRequest
    case normalizeOpenRouterRequest
    case resolveOpenRouterGatewayAccountState
    case parseOpenRouterModelCatalog
    case planGatewayLifecycle
    case planAggregateGatewayLeaseTransition
    case planAggregateGatewayLeaseRefresh
    case decideGatewayPostCompletionBinding
    case buildOAuthAuthorizationUrl
    case interpretOAuthCallback
    case parseOAuthTokenResponse
    case buildOAuthAccountFromTokens
    case refreshOAuthAccountFromTokens
    case inspectOAuthTokenMetadata
    case resolveUpdateAvailability
    case selectInstallableGitHubReleaseFromJSON
    case selectUpdateArtifact
    case evaluateUpdateBlockers
    case parseUpdateSignatureInspection
    case parseUpdateGatekeeperInspection
}

struct PortableCoreFFIRequest: Codable {
    let operation: String
    let payload: Data

    init<Payload: Encodable>(operation: PortableCoreOperation, payload: Payload) throws {
        self.operation = operation.rawValue
        self.payload = try JSONEncoder.portableCore.encode(payload)
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case payload
    }

    func encodedJSONString() throws -> String {
        let jsonObject: [String: Any] = [
            "operation": self.operation,
            "payload": try JSONSerialization.jsonObject(with: self.payload),
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

struct PortableCoreFFIError: Codable, Equatable {
    let code: String
    let message: String
}

struct PortableCoreFFIResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let error: PortableCoreFFIError?
}

struct PortableCoreRawConfigInput: Codable, Equatable {
    var version: Int?
    var global: GlobalSettingsInput
    var active: ActiveSelection
    var desktopPreferredCodexAppPath: String?
    var modelPricing: [String: ModelPricing]
    var openai: OpenAISettingsInput
    var providers: [ProviderInput]

    static func legacy(from config: CodexBarConfig) -> PortableCoreRawConfigInput {
        PortableCoreRawConfigInput(
            version: config.version,
            global: .init(
                defaultModel: config.global.defaultModel,
                reviewModel: config.global.reviewModel,
                reasoningEffort: config.global.reasoningEffort
            ),
            active: .init(
                providerId: config.active.providerId,
                accountId: config.active.accountId
            ),
            desktopPreferredCodexAppPath: config.desktop.preferredCodexAppPath,
            modelPricing: config.modelPricing.mapValues { pricing in
                ModelPricing(
                    inputUSDPerToken: pricing.inputUSDPerToken,
                    cachedInputUSDPerToken: pricing.cachedInputUSDPerToken,
                    outputUSDPerToken: pricing.outputUSDPerToken
                )
            },
            openai: .legacy(from: config.openAI),
            providers: config.providers.map(ProviderInput.legacy(from:))
        )
    }

    struct GlobalSettingsInput: Codable, Equatable {
        var defaultModel: String?
        var reviewModel: String?
        var reasoningEffort: String?
    }

    struct OpenAISettingsInput: Codable, Equatable {
        var accountOrder: [String]
        var accountUsageMode: String?
        var switchModeSelection: ActiveSelection?
        var accountOrderingMode: String?
        var manualActivationBehavior: String?
        var usageDisplayMode: String?
        var quotaSort: QuotaSortInput
        var interopProxiesJSON: String?
        var extensions: [String: JSONValue]

        static func legacy(from settings: CodexBarOpenAISettings) -> OpenAISettingsInput {
            OpenAISettingsInput(
                accountOrder: settings.accountOrder,
                accountUsageMode: settings.accountUsageMode.rawValue,
                switchModeSelection: settings.switchModeSelection.map {
                    ActiveSelection(providerId: $0.providerId, accountId: $0.accountId)
                },
                accountOrderingMode: settings.accountOrderingMode.rawValue,
                manualActivationBehavior: settings.manualActivationBehavior.rawValue,
                usageDisplayMode: settings.usageDisplayMode.rawValue,
                quotaSort: .init(
                    plusRelativeWeight: settings.quotaSort.plusRelativeWeight,
                    proRelativeToPlusMultiplier: settings.quotaSort.proRelativeToPlusMultiplier,
                    teamRelativeToPlusMultiplier: settings.quotaSort.teamRelativeToPlusMultiplier
                ),
                interopProxiesJSON: settings.interopProxiesJSON,
                extensions: [:]
            )
        }
    }

    struct QuotaSortInput: Codable, Equatable {
        var plusRelativeWeight: Double
        var proRelativeToPlusMultiplier: Double
        var teamRelativeToPlusMultiplier: Double
    }

    struct ProviderInput: Codable, Equatable {
        var id: String?
        var kind: String?
        var label: String?
        var enabled: Bool
        var baseURL: String?
        var defaultModel: String?
        var selectedModelID: String?
        var pinnedModelIDs: [String]
        var activeAccountID: String?
        var accounts: [ProviderAccountInput]

        static func legacy(from provider: CodexBarProvider) -> ProviderInput {
            let preserveModelSelection = provider.kind == .openRouter
            return ProviderInput(
                id: provider.id,
                kind: provider.kind.rawValue,
                label: provider.label,
                enabled: provider.enabled,
                baseURL: provider.baseURL,
                defaultModel: provider.defaultModel,
                selectedModelID: preserveModelSelection ? provider.selectedModelID : nil,
                pinnedModelIDs: preserveModelSelection ? provider.pinnedModelIDs : [],
                activeAccountID: provider.activeAccountId,
                accounts: provider.accounts.map(ProviderAccountInput.legacy(from:))
            )
        }
    }

    struct ProviderAccountInput: Codable, Equatable {
        var id: String?
        var kind: String?
        var label: String?
        var email: String?
        var openaiAccountID: String?
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Double?
        var oauthClientID: String?
        var tokenLastRefreshAt: Double?
        var apiKey: String?
        var planType: String?
        var primaryUsedPercent: Double?
        var secondaryUsedPercent: Double?
        var primaryResetAt: Double?
        var secondaryResetAt: Double?
        var primaryLimitWindowSeconds: Int?
        var secondaryLimitWindowSeconds: Int?
        var lastChecked: Double?
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

        static func legacy(from account: CodexBarProviderAccount) -> ProviderAccountInput {
            ProviderAccountInput(
                id: account.id,
                kind: account.kind.rawValue,
                label: account.label,
                email: account.email,
                openaiAccountID: account.openAIAccountId,
                accessToken: account.accessToken,
                refreshToken: account.refreshToken,
                idToken: account.idToken,
                expiresAt: account.expiresAt?.timeIntervalSince1970,
                oauthClientID: account.oauthClientID,
                tokenLastRefreshAt: account.tokenLastRefreshAt?.timeIntervalSince1970,
                apiKey: account.apiKey,
                planType: account.planType,
                primaryUsedPercent: account.primaryUsedPercent,
                secondaryUsedPercent: account.secondaryUsedPercent,
                primaryResetAt: account.primaryResetAt?.timeIntervalSince1970,
                secondaryResetAt: account.secondaryResetAt?.timeIntervalSince1970,
                primaryLimitWindowSeconds: account.primaryLimitWindowSeconds,
                secondaryLimitWindowSeconds: account.secondaryLimitWindowSeconds,
                lastChecked: account.lastChecked?.timeIntervalSince1970,
                isSuspended: account.isSuspended,
                tokenExpired: account.tokenExpired,
                organizationName: account.organizationName,
                interopProxyKey: account.interopProxyKey,
                interopNotes: account.interopNotes,
                interopConcurrency: account.interopConcurrency,
                interopPriority: account.interopPriority,
                interopRateMultiplier: account.interopRateMultiplier,
                interopAutoPauseOnExpired: account.interopAutoPauseOnExpired,
                interopCredentialsJSON: account.interopCredentialsJSON,
                interopExtraJSON: account.interopExtraJSON
            )
        }
    }
}

struct PortableCoreCanonicalizationResult: Codable, Equatable {
    var config: PortableCoreCanonicalConfigSnapshot
    var accounts: [PortableCoreCanonicalAccountSnapshot]
}

struct PortableCoreCanonicalConfigSnapshot: Codable, Equatable {
    var version: Int
    var global: GlobalSettings
    var active: ActiveSelection
    var modelPricing: [String: ModelPricing]
    var openai: OpenAISettings
    var providers: [Provider]

    static func legacy(from config: CodexBarConfig) -> PortableCoreCanonicalConfigSnapshot {
        PortableCoreCanonicalConfigSnapshot(
            version: max(1, config.version),
            global: .init(
                defaultModel: config.global.defaultModel,
                reviewModel: config.global.reviewModel,
                reasoningEffort: config.global.reasoningEffort
            ),
            active: .init(
                providerId: config.active.providerId?.nilIfBlank,
                accountId: config.active.accountId?.nilIfBlank
            ),
            modelPricing: config.modelPricing.mapValues { pricing in
                ModelPricing(
                    inputUSDPerToken: max(0, pricing.inputUSDPerToken),
                    cachedInputUSDPerToken: max(0, pricing.cachedInputUSDPerToken),
                    outputUSDPerToken: max(0, pricing.outputUSDPerToken)
                )
            },
            openai: .legacy(from: config.openAI),
            providers: config.providers.map(Provider.legacy(from:))
        )
    }

    struct GlobalSettings: Codable, Equatable {
        var defaultModel: String
        var reviewModel: String
        var reasoningEffort: String
    }

    struct OpenAISettings: Codable, Equatable {
        var accountOrder: [String]
        var accountUsageMode: String
        var switchModeSelection: ActiveSelection?
        var accountOrderingMode: String
        var manualActivationBehavior: String
        var usageDisplayMode: String
        var quotaSort: QuotaSort
        var interopProxiesJSON: String?
        var extensions: [String: JSONValue]

        static func legacy(from settings: CodexBarOpenAISettings) -> OpenAISettings {
            OpenAISettings(
                accountOrder: settings.accountOrder,
                accountUsageMode: settings.accountUsageMode.rawValue,
                switchModeSelection: settings.switchModeSelection.map {
                    ActiveSelection(providerId: $0.providerId, accountId: $0.accountId)
                },
                accountOrderingMode: settings.accountOrderingMode.rawValue,
                manualActivationBehavior: settings.manualActivationBehavior.rawValue,
                usageDisplayMode: settings.usageDisplayMode.rawValue,
                quotaSort: .init(
                    plusRelativeWeight: settings.quotaSort.plusRelativeWeight,
                    proRelativeToPlusMultiplier: settings.quotaSort.proRelativeToPlusMultiplier,
                    teamRelativeToPlusMultiplier: settings.quotaSort.teamRelativeToPlusMultiplier,
                    proAbsoluteWeight: settings.quotaSort.proAbsoluteWeight,
                    teamAbsoluteWeight: settings.quotaSort.teamAbsoluteWeight
                ),
                interopProxiesJSON: settings.interopProxiesJSON?.nilIfBlank,
                extensions: [:]
            )
        }
    }

    struct QuotaSort: Codable, Equatable {
        var plusRelativeWeight: Double
        var proRelativeToPlusMultiplier: Double
        var teamRelativeToPlusMultiplier: Double
        var proAbsoluteWeight: Double
        var teamAbsoluteWeight: Double
    }

    struct Provider: Codable, Equatable {
        var id: String
        var kind: String
        var label: String
        var enabled: Bool
        var baseURL: String?
        var defaultModel: String?
        var selectedModelID: String?
        var pinnedModelIDs: [String]
        var activeAccountID: String?
        var accounts: [ProviderAccount]

        static func legacy(from provider: CodexBarProvider) -> Provider {
            let preserveModelSelection = provider.kind == .openRouter
            return Provider(
                id: provider.id,
                kind: provider.kind.rawValue,
                label: provider.label,
                enabled: provider.enabled,
                baseURL: provider.baseURL?.nilIfBlank,
                defaultModel: provider.defaultModel?.nilIfBlank,
                selectedModelID: preserveModelSelection ? provider.selectedModelID?.nilIfBlank : nil,
                pinnedModelIDs: preserveModelSelection ? provider.pinnedModelIDs : [],
                activeAccountID: provider.activeAccountId?.nilIfBlank,
                accounts: provider.accounts.map(ProviderAccount.legacy(from:))
            )
        }
    }

    struct ProviderAccount: Codable, Equatable {
        var id: String
        var kind: String
        var label: String
        var email: String?
        var openaiAccountID: String?
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Double?
        var oauthClientID: String?
        var tokenLastRefreshAt: Double?
        var apiKey: String?
        var planType: String?
        var primaryUsedPercent: Double?
        var secondaryUsedPercent: Double?
        var primaryResetAt: Double?
        var secondaryResetAt: Double?
        var primaryLimitWindowSeconds: Int?
        var secondaryLimitWindowSeconds: Int?
        var lastChecked: Double?
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

        static func legacy(from account: CodexBarProviderAccount) -> ProviderAccount {
            ProviderAccount(
                id: account.id,
                kind: account.kind.rawValue,
                label: account.label,
                email: account.email?.nilIfBlank,
                openaiAccountID: account.openAIAccountId?.nilIfBlank,
                accessToken: account.accessToken?.nilIfBlank,
                refreshToken: account.refreshToken?.nilIfBlank,
                idToken: account.idToken?.nilIfBlank,
                expiresAt: account.expiresAt?.timeIntervalSince1970,
                oauthClientID: account.oauthClientID?.nilIfBlank,
                tokenLastRefreshAt: account.tokenLastRefreshAt?.timeIntervalSince1970,
                apiKey: account.apiKey?.nilIfBlank,
                planType: account.planType?.nilIfBlank,
                primaryUsedPercent: account.primaryUsedPercent,
                secondaryUsedPercent: account.secondaryUsedPercent,
                primaryResetAt: account.primaryResetAt?.timeIntervalSince1970,
                secondaryResetAt: account.secondaryResetAt?.timeIntervalSince1970,
                primaryLimitWindowSeconds: account.primaryLimitWindowSeconds,
                secondaryLimitWindowSeconds: account.secondaryLimitWindowSeconds,
                lastChecked: account.lastChecked?.timeIntervalSince1970,
                isSuspended: account.isSuspended,
                tokenExpired: account.tokenExpired,
                organizationName: account.organizationName?.nilIfBlank,
                interopProxyKey: account.interopProxyKey?.nilIfBlank,
                interopNotes: account.interopNotes?.nilIfBlank,
                interopConcurrency: account.interopConcurrency,
                interopPriority: account.interopPriority,
                interopRateMultiplier: account.interopRateMultiplier,
                interopAutoPauseOnExpired: account.interopAutoPauseOnExpired,
                interopCredentialsJSON: account.interopCredentialsJSON?.nilIfBlank,
                interopExtraJSON: account.interopExtraJSON?.nilIfBlank
            )
        }
    }
}

struct PortableCoreCanonicalAccountSnapshot: Codable, Equatable {
    var localAccountID: String
    var remoteAccountID: String
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Double?
    var oauthClientID: String?
    var planType: String
    var primaryUsedPercent: Double
    var secondaryUsedPercent: Double
    var primaryResetAt: Double?
    var secondaryResetAt: Double?
    var primaryLimitWindowSeconds: Int?
    var secondaryLimitWindowSeconds: Int?
    var lastChecked: Double?
    var isActive: Bool
    var isSuspended: Bool
    var tokenExpired: Bool
    var tokenLastRefreshAt: Double?
    var organizationName: String?
    var quotaExhausted: Bool
    var isAvailableForNextUseRouting: Bool
    var isDegradedForNextUseRouting: Bool

    static func legacy(from config: CodexBarConfig) -> [PortableCoreCanonicalAccountSnapshot] {
        config.providers.flatMap { provider in
            provider.accounts.compactMap { account in
                let isActive = provider.activeAccountId == account.id
                return account.asTokenAccount(isActive: isActive).map(Self.legacy(from:))
            }
        }
    }

    static func legacy(from account: TokenAccount) -> PortableCoreCanonicalAccountSnapshot {
        PortableCoreCanonicalAccountSnapshot(
            localAccountID: account.accountId,
            remoteAccountID: account.remoteAccountId,
            email: account.email,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            expiresAt: account.expiresAt?.timeIntervalSince1970,
            oauthClientID: account.oauthClientID?.nilIfBlank,
            planType: account.planType,
            primaryUsedPercent: max(0, account.primaryUsedPercent),
            secondaryUsedPercent: max(0, account.secondaryUsedPercent),
            primaryResetAt: account.primaryResetAt?.timeIntervalSince1970,
            secondaryResetAt: account.secondaryResetAt?.timeIntervalSince1970,
            primaryLimitWindowSeconds: account.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: account.secondaryLimitWindowSeconds,
            lastChecked: account.lastChecked?.timeIntervalSince1970,
            isActive: account.isActive,
            isSuspended: account.isSuspended,
            tokenExpired: account.tokenExpired,
            tokenLastRefreshAt: account.tokenLastRefreshAt?.timeIntervalSince1970,
            organizationName: account.organizationName?.nilIfBlank,
            quotaExhausted: account.quotaExhausted,
            isAvailableForNextUseRouting: account.isAvailableForNextUseRouting,
            isDegradedForNextUseRouting: account.isDegradedForNextUseRouting
        )
    }
}

struct PortableCoreRouteRuntimeInput: Codable, Equatable {
    var configuredMode: String
    var effectiveMode: String
    var aggregateRoutedAccountID: String?
    var stickyBindings: [StickyBinding]
    var routeJournal: [RouteJournalEntry]
    var leaseState: LeaseState
    var runningThreadAttribution: RunningThreadAttributionSummaryInput
    var liveSessionAttribution: LiveSessionAttributionSummaryInput
    var runtimeBlockState: RuntimeBlockState
    var now: Double

    struct StickyBinding: Codable, Equatable {
        var threadID: String
        var accountID: String
        var updatedAt: Double
    }

    struct RouteJournalEntry: Codable, Equatable {
        var threadID: String
        var accountID: String
        var timestamp: Double
    }

    struct LeaseState: Codable, Equatable {
        var leasedProcessIDs: [Int]
        var hasActiveLease: Bool
    }

    struct RunningThreadAttributionSummaryInput: Codable, Equatable {
        var activeThreadIDs: [String]
        var recentActivityWindowSeconds: Double
        var summaryIsUnavailable: Bool
        var inUseAccountIDs: [String]
    }

    struct LiveSessionAttributionSummaryInput: Codable, Equatable {
        var summaryIsUnavailable: Bool
        var activeSessionIDs: [String]
        var attributedAccountIDs: [String]
    }

    struct RuntimeBlockState: Codable, Equatable {
        var blockedAccountIDs: [String]
        var retryAt: Double?
        var resetAt: Double?
    }
}

struct PortableCoreRouteRuntimeSnapshotDTO: Codable, Equatable {
    var configuredMode: String
    var effectiveMode: String
    var aggregateRuntimeActive: Bool
    var latestRoutedAccountID: String?
    var latestRoutedAccountIsSummary: Bool
    var stickyAffectsFutureRouting: Bool
    var leaseActive: Bool
    var staleStickyEligible: Bool
    var staleStickyThreadID: String?
    var latestRouteAt: Double?
    var runtimeBlockSummary: RuntimeBlockSummary
    var runningThreadSummary: RunningThreadSummary
    var liveSessionSummary: LiveSessionSummary

    struct RuntimeBlockSummary: Codable, Equatable {
        var hasBlocker: Bool
        var blockedAccountIDs: [String]
        var retryAt: Double?
        var resetAt: Double?
    }

    struct RunningThreadSummary: Codable, Equatable {
        var summaryIsUnavailable: Bool
        var activeThreadIDs: [String]
        var inUseAccountIDs: [String]
    }

    struct LiveSessionSummary: Codable, Equatable {
        var summaryIsUnavailable: Bool
        var activeSessionIDs: [String]
        var attributedAccountIDs: [String]
    }

    func runtimeRouteSnapshot() -> OpenAIRuntimeRouteSnapshot {
        OpenAIRuntimeRouteSnapshot(
            configuredMode: CodexBarOpenAIAccountUsageMode(rawValue: self.configuredMode) ?? .switchAccount,
            effectiveMode: CodexBarOpenAIAccountUsageMode(rawValue: self.effectiveMode) ?? .switchAccount,
            aggregateRuntimeActive: self.aggregateRuntimeActive,
            latestRoutedAccountID: self.latestRoutedAccountID?.nilIfBlank,
            latestRoutedAccountIsSummary: self.latestRoutedAccountIsSummary,
            stickyAffectsFutureRouting: self.stickyAffectsFutureRouting,
            leaseActive: self.leaseActive,
            staleStickyEligible: self.staleStickyEligible,
            staleStickyThreadID: self.staleStickyThreadID?.nilIfBlank,
            latestRouteAt: self.latestRouteAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    static func failClosed(from input: PortableCoreRouteRuntimeInput) -> PortableCoreRouteRuntimeSnapshotDTO {
        PortableCoreRouteRuntimeSnapshotDTO(
            configuredMode: input.configuredMode,
            effectiveMode: input.effectiveMode,
            aggregateRuntimeActive: false,
            latestRoutedAccountID: input.aggregateRoutedAccountID?.nilIfBlank,
            latestRoutedAccountIsSummary: input.aggregateRoutedAccountID?.nilIfBlank != nil,
            stickyAffectsFutureRouting: false,
            leaseActive: input.leaseState.hasActiveLease || input.leaseState.leasedProcessIDs.isEmpty == false,
            staleStickyEligible: false,
            staleStickyThreadID: nil,
            latestRouteAt: nil,
            runtimeBlockSummary: .init(
                hasBlocker: input.runtimeBlockState.blockedAccountIDs.isEmpty == false
                    || input.runtimeBlockState.retryAt != nil
                    || input.runtimeBlockState.resetAt != nil,
                blockedAccountIDs: input.runtimeBlockState.blockedAccountIDs,
                retryAt: input.runtimeBlockState.retryAt,
                resetAt: input.runtimeBlockState.resetAt
            ),
            runningThreadSummary: .init(
                summaryIsUnavailable: input.runningThreadAttribution.summaryIsUnavailable,
                activeThreadIDs: input.runningThreadAttribution.activeThreadIDs,
                inUseAccountIDs: input.runningThreadAttribution.inUseAccountIDs
            ),
            liveSessionSummary: .init(
                summaryIsUnavailable: input.liveSessionAttribution.summaryIsUnavailable,
                activeSessionIDs: input.liveSessionAttribution.activeSessionIDs,
                attributedAccountIDs: input.liveSessionAttribution.attributedAccountIDs
            )
        )
    }

    static func legacy(
        from snapshot: OpenAIRuntimeRouteSnapshot,
        leaseState: PortableCoreRouteRuntimeInput.LeaseState,
        runtimeBlockState: PortableCoreRouteRuntimeInput.RuntimeBlockState,
        runningThreadAttribution: OpenAIRunningThreadAttribution,
        liveSessionAttribution: OpenAILiveSessionAttribution
    ) -> PortableCoreRouteRuntimeSnapshotDTO {
        let liveSummary = liveSessionAttribution.liveSummary()
        return PortableCoreRouteRuntimeSnapshotDTO(
            configuredMode: snapshot.configuredMode.rawValue,
            effectiveMode: snapshot.effectiveMode.rawValue,
            aggregateRuntimeActive: snapshot.aggregateRuntimeActive,
            latestRoutedAccountID: snapshot.latestRoutedAccountID?.nilIfBlank,
            latestRoutedAccountIsSummary: snapshot.latestRoutedAccountIsSummary,
            stickyAffectsFutureRouting: snapshot.stickyAffectsFutureRouting,
            leaseActive: leaseState.hasActiveLease || leaseState.leasedProcessIDs.isEmpty == false,
            staleStickyEligible: snapshot.staleStickyEligible &&
                leaseState.hasActiveLease == false &&
                leaseState.leasedProcessIDs.isEmpty,
            staleStickyThreadID: (
                snapshot.staleStickyEligible &&
                leaseState.hasActiveLease == false &&
                leaseState.leasedProcessIDs.isEmpty
            ) ? snapshot.staleStickyThreadID?.nilIfBlank : nil,
            latestRouteAt: snapshot.latestRouteAt?.timeIntervalSince1970,
            runtimeBlockSummary: .init(
                hasBlocker: runtimeBlockState.blockedAccountIDs.isEmpty == false
                    || runtimeBlockState.retryAt != nil
                    || runtimeBlockState.resetAt != nil,
                blockedAccountIDs: runtimeBlockState.blockedAccountIDs,
                retryAt: runtimeBlockState.retryAt,
                resetAt: runtimeBlockState.resetAt
            ),
            runningThreadSummary: .init(
                summaryIsUnavailable: runningThreadAttribution.summary.isUnavailable,
                activeThreadIDs: runningThreadAttribution.activeThreadIDs.sorted(),
                inUseAccountIDs: runningThreadAttribution.summary.runningThreadCounts.keys.sorted()
            ),
            liveSessionSummary: .init(
                summaryIsUnavailable: false,
                activeSessionIDs: liveSessionAttribution.sessions.map(\.sessionID).sorted(),
                attributedAccountIDs: liveSummary.inUseSessionCounts.keys.sorted()
            )
        )
    }
}

struct PortableCoreRenderCodecRequest: Codable, Equatable {
    var config: PortableCoreCanonicalConfigSnapshot
    var activeProviderID: String
    var activeAccountID: String
    var existingTOMLText: String
}

struct PortableCoreCodecMessage: Codable, Equatable {
    var code: String
    var message: String
}

struct PortableCoreRenderCodecOutput: Codable, Equatable {
    var authJSON: String
    var configTOML: String
    var codecWarnings: [PortableCoreCodecMessage]
    var migrationNotes: [PortableCoreCodecMessage]
}

struct PortableCoreRefreshRetryState: Codable, Equatable {
    var attempts: Int
    var retryAfter: Double
}

struct PortableCoreRefreshPlanRequest: Codable, Equatable {
    var account: PortableCoreCanonicalAccountSnapshot
    var force: Bool
    var now: Double
    var refreshWindowSeconds: Double
    var existingRetryState: PortableCoreRefreshRetryState?
    var inFlight: Bool
}

struct PortableCoreRefreshPlanResult: Codable, Equatable {
    var shouldRefresh: Bool
    var skipReason: String?
}

struct PortableCoreRefreshOutcomeRequest: Codable, Equatable {
    var account: PortableCoreCanonicalAccountSnapshot
    var now: Double
    var maxRetryCount: Int
    var existingRetryState: PortableCoreRefreshRetryState?
    var outcome: String
    var refreshedAccount: PortableCoreCanonicalAccountSnapshot?
}

struct PortableCoreRefreshOutcomeResult: Codable, Equatable {
    var account: PortableCoreCanonicalAccountSnapshot
    var nextRetryState: PortableCoreRefreshRetryState?
    var disposition: String
}

struct PortableCoreUsageMergeSuccessRequest: Codable, Equatable {
    var account: PortableCoreCanonicalAccountSnapshot
    var planType: String
    var primaryUsedPercent: Double
    var secondaryUsedPercent: Double
    var primaryResetAt: Double?
    var secondaryResetAt: Double?
    var primaryLimitWindowSeconds: Int?
    var secondaryLimitWindowSeconds: Int?
    var organizationName: String?
    var checkedAt: Double
}

struct PortableCoreUsageMergeResult: Codable, Equatable {
    var account: PortableCoreCanonicalAccountSnapshot
    var disposition: String
}

enum PortableCoreLegacyRefreshKernel {
    static func plan(_ request: PortableCoreRefreshPlanRequest) -> PortableCoreRefreshPlanResult {
        if request.inFlight {
            return .init(shouldRefresh: false, skipReason: "inFlight")
        }
        if let retry = request.existingRetryState, retry.retryAfter > request.now {
            return .init(shouldRefresh: false, skipReason: "retryBackoff")
        }
        if request.account.isSuspended {
            return .init(shouldRefresh: false, skipReason: "suspended")
        }
        if request.force {
            return .init(shouldRefresh: true, skipReason: nil)
        }
        if request.account.tokenExpired {
            return .init(shouldRefresh: false, skipReason: "tokenExpired")
        }
        let shouldRefresh: Bool
        if let expiresAt = request.account.expiresAt {
            shouldRefresh = (expiresAt - request.now) <= request.refreshWindowSeconds
        } else {
            shouldRefresh = request.account.tokenLastRefreshAt == nil
        }
        return .init(
            shouldRefresh: shouldRefresh,
            skipReason: shouldRefresh ? nil : "notDue"
        )
    }

    static func applyOutcome(_ request: PortableCoreRefreshOutcomeRequest) -> PortableCoreRefreshOutcomeResult {
        switch request.outcome {
        case "refreshed":
            return .init(
                account: request.refreshedAccount ?? request.account,
                nextRetryState: nil,
                disposition: "refreshed"
            )
        case "terminal_failure":
            var account = request.account
            account.tokenExpired = true
            return .init(account: account, nextRetryState: nil, disposition: "terminalFailure")
        case "transient_failure":
            return .init(
                account: request.account,
                nextRetryState: nextRetryState(
                    existing: request.existingRetryState,
                    now: request.now,
                    maxRetryCount: request.maxRetryCount
                ),
                disposition: "transientFailure"
            )
        default:
            return .init(
                account: request.account,
                nextRetryState: request.existingRetryState,
                disposition: "skipped"
            )
        }
    }

    private static func nextRetryState(
        existing: PortableCoreRefreshRetryState?,
        now: Double,
        maxRetryCount: Int
    ) -> PortableCoreRefreshRetryState {
        let attempts = min((existing?.attempts ?? 0) + 1, max(1, maxRetryCount))
        let backoffMinutes = pow(2.0, Double(max(0, attempts - 1)))
        return PortableCoreRefreshRetryState(
            attempts: attempts,
            retryAfter: now + backoffMinutes * 60
        )
    }
}

enum PortableCoreLegacyUsageKernel {
    static func mergeSuccess(_ request: PortableCoreUsageMergeSuccessRequest) -> PortableCoreUsageMergeResult {
        var account = request.account
        account.planType = request.planType
        account.primaryUsedPercent = max(0, request.primaryUsedPercent)
        account.secondaryUsedPercent = max(0, request.secondaryUsedPercent)
        account.primaryResetAt = request.primaryResetAt
        account.secondaryResetAt = request.secondaryResetAt
        account.primaryLimitWindowSeconds = request.primaryLimitWindowSeconds
        account.secondaryLimitWindowSeconds = request.secondaryLimitWindowSeconds
        account.lastChecked = request.checkedAt
        account.tokenExpired = false
        if let organizationName = request.organizationName?.nilIfBlank {
            account.organizationName = organizationName
        }
        account.quotaExhausted = account.primaryUsedPercent >= 100 || account.secondaryUsedPercent >= 100
        account.isAvailableForNextUseRouting = account.isSuspended == false && account.tokenExpired == false && account.quotaExhausted == false
        account.isDegradedForNextUseRouting = account.isAvailableForNextUseRouting
            && (account.primaryUsedPercent >= 80 || account.secondaryUsedPercent >= 80)
        return PortableCoreUsageMergeResult(account: account, disposition: "updated")
    }

    static func markForbidden(_ account: PortableCoreCanonicalAccountSnapshot) -> PortableCoreUsageMergeResult {
        var updated = account
        updated.isSuspended = true
        updated.isAvailableForNextUseRouting = false
        updated.isDegradedForNextUseRouting = false
        return PortableCoreUsageMergeResult(account: updated, disposition: "forbidden")
    }

    static func markTokenExpired(_ account: PortableCoreCanonicalAccountSnapshot) -> PortableCoreUsageMergeResult {
        var updated = account
        updated.tokenExpired = true
        updated.isAvailableForNextUseRouting = false
        updated.isDegradedForNextUseRouting = false
        return PortableCoreUsageMergeResult(account: updated, disposition: "tokenExpired")
    }
}

struct ActiveSelection: Codable, Equatable {
    var providerId: String?
    var accountId: String?
}

struct ModelPricing: Codable, Equatable {
    var inputUSDPerToken: Double
    var cachedInputUSDPerToken: Double
    var outputUSDPerToken: Double
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    init(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(any: $0) })
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.anyValue }
        case .array(let value):
            return value.map { $0.anyValue }
        case .null:
            return NSNull()
        }
    }
}

extension JSONEncoder {
    static let portableCore: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .custom { codingPath in
            guard let last = codingPath.last else { return PortableCoreCodingKey(stringValue: "")! }
            return PortableCoreCodingKey(
                stringValue: PortableCoreCodingKey.encode(last.stringValue)
            )!
        }
        return encoder
    }()
}

extension JSONDecoder {
    static let portableCore: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            guard let last = codingPath.last else { return PortableCoreCodingKey(stringValue: "")! }
            return PortableCoreCodingKey(
                stringValue: PortableCoreCodingKey.decode(last.stringValue)
            )!
        }
        return decoder
    }()
}

private struct PortableCoreCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }

    static func encode(_ key: String) -> String {
        switch key {
        case "existingTOMLText": return "existingTomlText"
        case "baseURL": return "baseUrl"
        case "selectedModelID": return "selectedModelId"
        case "pinnedModelIDs": return "pinnedModelIds"
        case "currentSelectedModelID": return "currentSelectedModelId"
        case "nextSelectedModelID": return "nextSelectedModelId"
        case "currentPinnedModelIDs": return "currentPinnedModelIds"
        case "nextPinnedModelIDs": return "nextPinnedModelIds"
        case "activeAccountID": return "activeAccountId"
        case "openaiAccountID": return "openaiAccountId"
        case "oauthClientID": return "oauthClientId"
        case "localAccountID": return "localAccountId"
        case "remoteAccountID": return "remoteAccountId"
        case "recentOpenRouterModelID": return "recentOpenrouterModelId"
        case "removeProviderIDs": return "removeProviderIds"
        case "switchProviderID": return "switchProviderId"
        case "switchAccountID": return "switchAccountId"
        case "blockedAccountIDs": return "blockedAccountIds"
        case "activeThreadIDs": return "activeThreadIds"
        case "inUseAccountIDs": return "inUseAccountIds"
        case "activeSessionIDs": return "activeSessionIds"
        case "attributedAccountIDs": return "attributedAccountIds"
        case "activeProviderID": return "activeProviderId"
        case "accountID": return "accountId"
        case "threadID": return "threadId"
        case "sessionID": return "sessionId"
        case "windowID": return "windowId"
        case "latestRoutedAccountID": return "latestRoutedAccountId"
        case "staleStickyThreadID": return "staleStickyThreadId"
        case "authJSON": return "authJson"
        case "configTOML": return "configToml"
        case "existingJSON": return "existingJson"
        case "incomingJSON": return "incomingJson"
        case "mergedJSON": return "mergedJson"
        case "proxiesJSON": return "proxiesJson"
        case "interopProxiesJSON": return "interopProxiesJson"
        case "interopCredentialsJSON": return "interopCredentialsJson"
        case "interopExtraJSON": return "interopExtraJson"
        case "openAIBaseURL": return "openaiBaseUrl"
        case "inputUSDPerToken": return "inputUsdPerToken"
        case "cachedInputUSDPerToken": return "cachedInputUsdPerToken"
        case "outputUSDPerToken": return "outputUsdPerToken"
        default: return key
        }
    }

    static func decode(_ key: String) -> String {
        switch key {
        case "existingTomlText": return "existingTOMLText"
        case "baseUrl": return "baseURL"
        case "selectedModelId": return "selectedModelID"
        case "pinnedModelIds": return "pinnedModelIDs"
        case "currentSelectedModelId": return "currentSelectedModelID"
        case "nextSelectedModelId": return "nextSelectedModelID"
        case "currentPinnedModelIds": return "currentPinnedModelIDs"
        case "nextPinnedModelIds": return "nextPinnedModelIDs"
        case "activeAccountId": return "activeAccountID"
        case "openaiAccountId": return "openaiAccountID"
        case "oauthClientId": return "oauthClientID"
        case "localAccountId": return "localAccountID"
        case "remoteAccountId": return "remoteAccountID"
        case "recentOpenrouterModelId": return "recentOpenRouterModelID"
        case "removeProviderIds": return "removeProviderIDs"
        case "switchProviderId": return "switchProviderID"
        case "switchAccountId": return "switchAccountID"
        case "blockedAccountIds": return "blockedAccountIDs"
        case "activeThreadIds": return "activeThreadIDs"
        case "inUseAccountIds": return "inUseAccountIDs"
        case "activeSessionIds": return "activeSessionIDs"
        case "attributedAccountIds": return "attributedAccountIDs"
        case "activeProviderId": return "activeProviderID"
        case "threadId": return "threadID"
        case "sessionId": return "sessionID"
        case "windowId": return "windowID"
        case "latestRoutedAccountId": return "latestRoutedAccountID"
        case "staleStickyThreadId": return "staleStickyThreadID"
        case "authJson": return "authJSON"
        case "configToml": return "configTOML"
        case "existingJson": return "existingJSON"
        case "incomingJson": return "incomingJSON"
        case "mergedJson": return "mergedJSON"
        case "proxiesJson": return "proxiesJSON"
        case "interopProxiesJson": return "interopProxiesJSON"
        case "interopCredentialsJson": return "interopCredentialsJSON"
        case "interopExtraJson": return "interopExtraJSON"
        case "openaiBaseUrl": return "openAIBaseURL"
        case "inputUsdPerToken": return "inputUSDPerToken"
        case "cachedInputUsdPerToken": return "cachedInputUSDPerToken"
        case "outputUsdPerToken": return "outputUSDPerToken"
        default: return key
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
