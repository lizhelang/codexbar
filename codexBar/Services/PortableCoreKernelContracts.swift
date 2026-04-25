import Foundation

private struct PortableCoreDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct PortableCoreFullRustCutoverContract: Codable, Equatable {
    var schemaVersion: String
    var controlPlane: ControlPlane
    var crateGraph: [CrateNode]
    var hostCapabilityContract: HostCapabilityContract
    var capabilityAcl: [SubsystemACL]
    var ownershipMatrix: [OwnershipMatrixEntry]
    var branchWorktreeLaw: BranchWorktreeLaw

    struct ControlPlane: Codable, Equatable {
        var schemaVersion: String
        var singleControlPlaneLaw: String
        var commandExamples: [String]
        var queryExamples: [String]
        var eventExamples: [String]
        var streamExamples: [String]
        var routeRuntimeBoundaryLaw: String
    }

    struct CrateNode: Codable, Equatable {
        var crateName: String
        var ownsSubsystems: [String]
        var dependsOn: [String]
    }

    struct HostCapabilityContract: Codable, Equatable {
        var schemaVersion: String
        var requestFields: [String]
        var responseFields: [String]
        var eventFields: [String]
        var capabilities: [HostCapabilityRule]
    }

    struct HostCapabilityRule: Codable, Equatable {
        var capability: String
        var requestResponseShape: String
        var swiftAllowed: String
        var swiftForbidden: String
    }

    struct SubsystemACL: Codable, Equatable {
        var subsystem: String
        var capabilities: [String]
    }

    struct OwnershipMatrixEntry: Codable, Equatable {
        var subsystem: String
        var currentSwiftOwner: String
        var targetRustOwner: String
        var hostCapabilities: [String]
        var dualRunGate: String
        var primaryCutoverGate: String
        var swiftDeleteCondition: String
        var swiftOwnerState: String
        var temporaryWrapperReason: String?
        var deleteConditionMet: Bool
    }

    struct BranchWorktreeLaw: Codable, Equatable {
        var integrationWorktree: String
        var integrationBranch: String
        var siblingWorktree: String
        var siblingBranchExpected: String
        var hotFiles: [String]
        var rules: [String]
    }
}

struct PortableCoreStorePathPlanRequest: Codable, Equatable {
    var homeRoot: String?
    var codexRoot: String?
    var codexbarRoot: String?
    var stateSqliteDefaultVersion: Int
    var logsSqliteDefaultVersion: Int
}

struct PortableCoreStorePathPlan: Codable, Equatable {
    var homeRoot: String
    var codexRoot: String
    var codexbarRoot: String
    var authPath: String
    var tokenPoolPath: String
    var configTomlPath: String
    var providerSecretsPath: String
    var stateSqlitePath: String
    var logsSqlitePath: String
    var oauthFlowsDirectoryPath: String
    var barConfigPath: String
    var costCachePath: String
    var costSessionCachePath: String
    var costEventLedgerPath: String
    var switchJournalPath: String
    var openaiGatewayStatePath: String
    var openaiGatewayRouteJournalPath: String
    var openrouterGatewayStatePath: String
    var pathPolicySummary: String
}

struct PortableCoreUsagePollingAccount: Codable, Equatable {
    var accountId: String
    var isSuspended: Bool
    var tokenExpired: Bool
    var lastCheckedAt: Double?

    static func legacy(from account: TokenAccount) -> PortableCoreUsagePollingAccount {
        PortableCoreUsagePollingAccount(
            accountId: account.accountId,
            isSuspended: account.isSuspended,
            tokenExpired: account.tokenExpired,
            lastCheckedAt: account.lastChecked?.timeIntervalSince1970
        )
    }
}

struct PortableCoreUsagePollingPlanRequest: Codable, Equatable {
    var activeProviderKind: String?
    var activeAccount: PortableCoreUsagePollingAccount?
    var now: Double
    var maxAgeSeconds: Double
    var force: Bool
}

struct PortableCoreUsagePollingPlanResult: Codable, Equatable {
    var shouldRefresh: Bool
    var accountId: String?
    var skipReason: String?
}

struct PortableCoreUsageModeTransitionProviderInput: Codable, Equatable {
    var providerId: String
    var activeAccountId: String?
    var accountIds: [String]

    static func legacy(from provider: CodexBarProvider) -> Self {
        Self(
            providerId: provider.id,
            activeAccountId: provider.activeAccountId,
            accountIds: provider.accounts.map(\.id)
        )
    }
}

struct PortableCoreUsageModeTransitionRequest: Codable, Equatable {
    var currentMode: String
    var targetMode: String
    var activeProviderId: String?
    var activeAccountId: String?
    var switchModeSelectionProviderId: String?
    var switchModeSelectionAccountId: String?
    var oauthProviderId: String?
    var oauthActiveAccountId: String?
    var providers: [PortableCoreUsageModeTransitionProviderInput]
}

struct PortableCoreUsageModeTransitionResult: Codable, Equatable {
    var nextMode: String
    var nextActiveProviderId: String?
    var nextActiveAccountId: String?
    var nextSwitchModeSelectionProviderId: String?
    var nextSwitchModeSelectionAccountId: String?
    var shouldSyncCodex: Bool
    var rustOwner: String
}

struct PortableCoreTokenUsage: Codable, Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int

    static func legacy(from usage: SessionLogStore.Usage) -> PortableCoreTokenUsage {
        PortableCoreTokenUsage(
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            outputTokens: usage.outputTokens
        )
    }

    func sessionUsage() -> SessionLogStore.Usage {
        SessionLogStore.Usage(
            inputTokens: self.inputTokens,
            cachedInputTokens: self.cachedInputTokens,
            outputTokens: self.outputTokens
        )
    }
}

struct PortableCoreModelPricing: Codable, Equatable {
    var inputUsdPerToken: Double
    var cachedInputUsdPerToken: Double
    var outputUsdPerToken: Double

    static func legacy(from pricing: CodexBarModelPricing) -> PortableCoreModelPricing {
        PortableCoreModelPricing(
            inputUsdPerToken: pricing.inputUSDPerToken,
            cachedInputUsdPerToken: pricing.cachedInputUSDPerToken,
            outputUsdPerToken: pricing.outputUSDPerToken
        )
    }

    func modelPricing() -> CodexBarModelPricing {
        CodexBarModelPricing(
            inputUSDPerToken: self.inputUsdPerToken,
            cachedInputUSDPerToken: self.cachedInputUsdPerToken,
            outputUSDPerToken: self.outputUsdPerToken
        )
    }
}

struct PortableCoreLocalCostEvent: Codable, Equatable {
    var model: String
    var timestamp: Double
    var usage: PortableCoreTokenUsage
    var sessionUsage: PortableCoreTokenUsage?
}

struct PortableCoreLocalCostSummaryRequest: Codable, Equatable {
    var now: Double
    var pricingOverrides: [String: PortableCoreModelPricing]
    var events: [PortableCoreLocalCostEvent]
}

struct PortableCoreLocalCostDailyEntry: Codable, Equatable {
    var id: String
    var timestamp: Double
    var costUsd: Double
    var totalTokens: Int
}

struct PortableCoreLocalCostSummarySnapshot: Codable, Equatable {
    var todayCostUsd: Double
    var todayTokens: Int
    var last30DaysCostUsd: Double
    var last30DaysTokens: Int
    var lifetimeCostUsd: Double
    var lifetimeTokens: Int
    var dailyEntries: [PortableCoreLocalCostDailyEntry]
    var updatedAt: Double

    func localCostSummary() -> LocalCostSummary {
        LocalCostSummary(
            todayCostUSD: self.todayCostUsd,
            todayTokens: self.todayTokens,
            last30DaysCostUSD: self.last30DaysCostUsd,
            last30DaysTokens: self.last30DaysTokens,
            lifetimeCostUSD: self.lifetimeCostUsd,
            lifetimeTokens: self.lifetimeTokens,
            dailyEntries: self.dailyEntries.map {
                DailyCostEntry(
                    id: $0.id,
                    date: Date(timeIntervalSince1970: $0.timestamp),
                    costUSD: $0.costUsd,
                    totalTokens: $0.totalTokens
                )
            },
            updatedAt: Date(timeIntervalSince1970: self.updatedAt)
        )
    }
}

struct PortableCoreSessionRecordInput: Codable, Equatable {
    var sessionID: String
    var startedAt: Double
    var lastActivityAt: Double
    var isArchived: Bool
    var model: String
    var usage: PortableCoreTokenUsage
}

struct PortableCoreUsageEventInput: Codable, Equatable {
    var timestamp: Double
    var usage: PortableCoreTokenUsage
}

struct PortableCoreCachedSessionRecordInput: Codable, Equatable {
    var record: PortableCoreSessionRecordInput?
    var usageEvents: [PortableCoreUsageEventInput]
}

struct PortableCorePersistedLedgerEvent: Codable, Equatable {
    var timestamp: Double
    var usage: PortableCoreTokenUsage
    var costUsd: Double
}

struct PortableCorePersistedLedgerSession: Codable, Equatable {
    var model: String
    var events: [PortableCorePersistedLedgerEvent]
}

struct PortableCorePersistedUsageLedger: Codable, Equatable {
    var version: Int
    var didSeedFromSessionCache: Bool
    var sessions: [String: PortableCorePersistedLedgerSession]
}

struct PortableCoreHistoricalSessionRecord: Codable, Equatable {
    var sessionID: String
    var modelId: String
    var startedAt: Double
    var lastActivityAt: Double
    var isArchived: Bool
    var totalTokens: Int
}

struct PortableCoreSessionUsageLedgerProjectionRequest: Codable, Equatable {
    var currentSessions: [PortableCoreCachedSessionRecordInput]
    var persistedLedger: PortableCorePersistedUsageLedger
    var seedSessions: [PortableCoreCachedSessionRecordInput]
}

struct PortableCoreSessionUsageLedgerProjectionResult: Codable, Equatable {
    var ledger: PortableCorePersistedUsageLedger
    var historicalSessions: [PortableCoreHistoricalSessionRecord]
}

struct PortableCoreParsedSessionRecord: Codable, Equatable {
    var sessionID: String
    var startedAt: Double
    var lastActivityAt: Double
    var isArchived: Bool
    var model: String
    var usage: PortableCoreTokenUsage
    var taskLifecycleState: String?

    func sessionRecord() -> SessionLogStore.SessionRecord {
        SessionLogStore.SessionRecord(
            id: self.sessionID,
            startedAt: Date(timeIntervalSince1970: self.startedAt),
            lastActivityAt: Date(timeIntervalSince1970: self.lastActivityAt),
            isArchived: self.isArchived,
            model: self.model,
            usage: self.usage.sessionUsage(),
            taskLifecycleState: self.taskLifecycleState.flatMap(SessionLogStore.TaskLifecycleState.init(rawValue:))
        )
    }
}

struct PortableCoreParsedSessionLifecycleRecord: Codable, Equatable {
    var sessionID: String
    var startedAt: Double
    var lastActivityAt: Double
    var isArchived: Bool
    var taskLifecycleState: String?

    func sessionLifecycleRecord() -> SessionLogStore.SessionLifecycleRecord {
        SessionLogStore.SessionLifecycleRecord(
            id: self.sessionID,
            startedAt: Date(timeIntervalSince1970: self.startedAt),
            lastActivityAt: Date(timeIntervalSince1970: self.lastActivityAt),
            isArchived: self.isArchived,
            taskLifecycleState: self.taskLifecycleState.flatMap(SessionLogStore.TaskLifecycleState.init(rawValue:))
        )
    }
}

struct PortableCoreSessionTranscriptParseRequest: Codable, Equatable {
    var text: String
    var fallbackSessionId: String
    var lastActivityAt: Double
    var isArchived: Bool
}

struct PortableCoreSessionTranscriptParseResult: Codable, Equatable {
    var sessionRecord: PortableCoreParsedSessionRecord?
    var lifecycleRecord: PortableCoreParsedSessionLifecycleRecord?
    var usageEvents: [PortableCoreUsageEventInput]
}

extension PortableCoreUsageEventInput {
    func usageEvent() -> SessionLogStore.UsageEvent {
        SessionLogStore.UsageEvent(
            timestamp: Date(timeIntervalSince1970: self.timestamp),
            usage: self.usage.sessionUsage()
        )
    }
}

struct PortableCoreActivationRecord: Codable, Equatable {
    var timestamp: Double
    var providerId: String?
    var accountId: String?

    static func legacy(from record: SwitchJournalStore.ActivationRecord) -> PortableCoreActivationRecord {
        PortableCoreActivationRecord(
            timestamp: record.timestamp.timeIntervalSince1970,
            providerId: record.providerID,
            accountId: record.accountID
        )
    }
}

struct PortableCoreLiveSessionInput: Codable, Equatable {
    var sessionID: String
    var startedAt: Double
    var lastActivityAt: Double

    static func legacy(from record: SessionLogStore.SessionRecord) -> PortableCoreLiveSessionInput {
        PortableCoreLiveSessionInput(
            sessionID: record.id,
            startedAt: record.startedAt.timeIntervalSince1970,
            lastActivityAt: record.lastActivityAt.timeIntervalSince1970
        )
    }
}

struct PortableCoreLiveSessionAttributionRequest: Codable, Equatable {
    var now: Double
    var recentActivityWindowSeconds: Double
    var sessions: [PortableCoreLiveSessionInput]
    var activations: [PortableCoreActivationRecord]
}

struct PortableCoreLiveSessionAttributionItem: Codable, Equatable {
    var sessionID: String
    var startedAt: Double
    var lastActivityAt: Double
    var accountId: String?
}

struct PortableCoreLiveSessionAttributionSummary: Codable, Equatable {
    var inUseSessionCounts: [String: Int]
    var unknownSessionCount: Int
}

struct PortableCoreLiveSessionAttributionResult: Codable, Equatable {
    var recentActivityWindowSeconds: Double
    var sessions: [PortableCoreLiveSessionAttributionItem]
    var summary: PortableCoreLiveSessionAttributionSummary

    func liveSessionAttribution() -> OpenAILiveSessionAttribution {
        OpenAILiveSessionAttribution(
            sessions: self.sessions.map {
                .init(
                    sessionID: $0.sessionID,
                    startedAt: Date(timeIntervalSince1970: $0.startedAt),
                    lastActivityAt: Date(timeIntervalSince1970: $0.lastActivityAt),
                    accountID: $0.accountId
                )
            },
            inUseSessionCounts: self.summary.inUseSessionCounts,
            unknownSessionCount: self.summary.unknownSessionCount,
            recentActivityWindow: self.recentActivityWindowSeconds
        )
    }
}

struct PortableCoreRuntimeThreadInput: Codable, Equatable {
    var threadID: String
    var source: String
    var cwd: String
    var title: String
    var lastRuntimeAt: Double

    static func legacy(from thread: CodexThreadRuntimeStore.RuntimeThread) -> PortableCoreRuntimeThreadInput {
        PortableCoreRuntimeThreadInput(
            threadID: thread.threadID,
            source: thread.source,
            cwd: thread.cwd,
            title: thread.title,
            lastRuntimeAt: thread.lastRuntimeAt.timeIntervalSince1970
        )
    }
}

struct PortableCoreSessionLifecycleInput: Codable, Equatable {
    var sessionID: String
    var lastActivityAt: Double
    var taskLifecycleState: String

    static func legacy(from record: SessionLogStore.SessionLifecycleRecord) -> PortableCoreSessionLifecycleInput {
        PortableCoreSessionLifecycleInput(
            sessionID: record.id,
            lastActivityAt: record.lastActivityAt.timeIntervalSince1970,
            taskLifecycleState: record.taskLifecycleState?.rawValue ?? ""
        )
    }
}

struct PortableCoreAggregateRouteRecordInput: Codable, Equatable {
    var timestamp: Double
    var threadID: String
    var accountId: String

    static func legacy(from record: OpenAIAggregateRouteRecord) -> PortableCoreAggregateRouteRecordInput {
        PortableCoreAggregateRouteRecordInput(
            timestamp: record.timestamp.timeIntervalSince1970,
            threadID: record.threadID,
            accountId: record.accountID
        )
    }
}

struct PortableCoreRunningThreadAttributionRequest: Codable, Equatable {
    var recentActivityWindowSeconds: Double
    var unavailableReason: String?
    var threads: [PortableCoreRuntimeThreadInput]
    var completedSessions: [PortableCoreSessionLifecycleInput]
    var aggregateRoutes: [PortableCoreAggregateRouteRecordInput]
    var activations: [PortableCoreActivationRecord]
}

struct PortableCoreRunningThreadAttributionItem: Codable, Equatable {
    var threadID: String
    var source: String
    var cwd: String
    var title: String
    var lastRuntimeAt: Double
    var accountId: String?
}

struct PortableCoreRunningThreadSummary: Codable, Equatable {
    var summaryIsUnavailable: Bool
    var runningThreadCounts: [String: Int]
    var unknownThreadCount: Int
}

struct PortableCoreRunningThreadAttributionResult: Codable, Equatable {
    var recentActivityWindowSeconds: Double
    var diagnosticMessage: String?
    var unavailableReason: String?
    var threads: [PortableCoreRunningThreadAttributionItem]
    var summary: PortableCoreRunningThreadSummary

    func runningThreadAttribution() -> OpenAIRunningThreadAttribution {
        let availability: OpenAIRunningThreadAttribution.Summary.Availability =
            self.summary.summaryIsUnavailable ? .unavailable : .available
        return OpenAIRunningThreadAttribution(
            threads: self.threads.map {
                .init(
                    threadID: $0.threadID,
                    source: $0.source,
                    cwd: $0.cwd,
                    title: $0.title,
                    lastRuntimeAt: Date(timeIntervalSince1970: $0.lastRuntimeAt),
                    accountID: $0.accountId
                )
            },
            summary: .init(
                availability: availability,
                runningThreadCounts: self.summary.runningThreadCounts,
                unknownThreadCount: self.summary.unknownThreadCount
            ),
            recentActivityWindow: self.recentActivityWindowSeconds,
            diagnosticMessage: self.diagnosticMessage,
            unavailableReason: nil
        )
    }
}

struct PortableCoreGatewayProxyEndpoint: Codable, Equatable {
    var kind: String
    var host: String
    var port: Int

    func systemProxyEndpoint() -> OpenAIAccountGatewaySystemProxyEndpoint {
        OpenAIAccountGatewaySystemProxyEndpoint(kind: self.kind, host: self.host, port: self.port)
    }

    static func legacy(from endpoint: OpenAIAccountGatewaySystemProxyEndpoint) -> PortableCoreGatewayProxyEndpoint {
        PortableCoreGatewayProxyEndpoint(kind: endpoint.kind, host: endpoint.host, port: endpoint.port)
    }
}

struct PortableCoreGatewayProxySnapshot: Codable, Equatable {
    var http: PortableCoreGatewayProxyEndpoint?
    var https: PortableCoreGatewayProxyEndpoint?
    var socks: PortableCoreGatewayProxyEndpoint?

    func systemProxySnapshot() -> OpenAIAccountGatewaySystemProxySnapshot? {
        guard self.http != nil || self.https != nil || self.socks != nil else { return nil }
        return OpenAIAccountGatewaySystemProxySnapshot(
            http: self.http?.systemProxyEndpoint(),
            https: self.https?.systemProxyEndpoint(),
            socks: self.socks?.systemProxyEndpoint()
        )
    }

    static func legacy(from snapshot: OpenAIAccountGatewaySystemProxySnapshot?) -> PortableCoreGatewayProxySnapshot? {
        guard let snapshot else { return nil }
        return PortableCoreGatewayProxySnapshot(
            http: snapshot.http.map(PortableCoreGatewayProxyEndpoint.legacy(from:)),
            https: snapshot.https.map(PortableCoreGatewayProxyEndpoint.legacy(from:)),
            socks: snapshot.socks.map(PortableCoreGatewayProxyEndpoint.legacy(from:))
        )
    }
}

struct PortableCoreGatewayTransportPolicyRequest: Codable, Equatable {
    var proxyResolutionMode: String
    var systemProxySnapshot: PortableCoreGatewayProxySnapshot?
}

struct PortableCoreGatewayTransportPolicyResult: Codable, Equatable {
    var proxyResolutionMode: String
    var systemProxySnapshot: PortableCoreGatewayProxySnapshot?
    var effectiveProxySnapshot: PortableCoreGatewayProxySnapshot?
    var loopbackProxySafeApplied: Bool

    func resolvedPolicy() -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        OpenAIAccountGatewayResolvedUpstreamTransportPolicy(
            proxyResolutionMode: self.proxyResolutionMode == "loopbackProxySafe" ? .loopbackProxySafe : .systemDefault,
            systemProxySnapshot: self.systemProxySnapshot?.systemProxySnapshot(),
            effectiveProxySnapshot: self.effectiveProxySnapshot?.systemProxySnapshot(),
            loopbackProxySafeApplied: self.loopbackProxySafeApplied
        )
    }
}

struct PortableCoreGatewayStatusPolicyRequest: Codable, Equatable {
    var statusCode: Int
    var now: Double
    var allowFallbackRuntimeBlock: Bool
    var suggestedRetryAt: Double?
    var account: PortableCoreGatewayAccountInput?
}

struct PortableCoreGatewayStatusPolicyResult: Codable, Equatable {
    var failureClass: String?
    var failoverDisposition: String
    var isAccountScopedStatus: Bool
    var shouldRetry: Bool
    var shouldRuntimeBlockAccount: Bool
    var runtimeBlockRetryAt: Double?
    var rustOwner: String
}

struct PortableCoreGatewayStickyRecoveryPolicyRequest: Codable, Equatable {
    var failureClass: String
    var stickyBindingMatchesFailedAccount: Bool
    var candidateIndex: Int
    var candidateCount: Int
    var usedStickyContextRecovery: Bool
}

struct PortableCoreGatewayStickyRecoveryPolicyResult: Codable, Equatable {
    var shouldAttemptStickyContextRecovery: Bool
    var rustOwner: String
}

struct PortableCoreGatewayProtocolSignalInterpretationRequest: Codable, Equatable {
    var payloadText: String
    var now: Double
}

struct PortableCoreGatewayProtocolSignalInterpretationResult: Codable, Equatable {
    var isRuntimeLimitSignal: Bool
    var message: String?
    var retryAt: Double?
    var retryAtHumanText: String?
    var rustOwner: String
}

struct PortableCoreGatewayProtocolPreviewDecisionRequest: Codable, Equatable {
    var payloadText: String?
    var now: Double
    var byteCount: Int
    var isEventStream: Bool
    var isFinal: Bool
}

struct PortableCoreGatewayProtocolPreviewDecisionResult: Codable, Equatable {
    var decision: String
    var message: String?
    var retryAt: Double?
    var retryAtHumanText: String?
    var rustOwner: String
}

struct PortableCoreGatewayCandidatePlanRequest: Codable, Equatable {
    var accountUsageMode: String
    var now: Double
    var quotaSortSettings: PortableCoreGatewayQuotaSortSettings
    var accounts: [PortableCoreGatewayAccountInput]
    var stickyKey: String?
    var stickyBindings: [PortableCoreGatewayStickyBindingInput]
    var runtimeBlockedAccounts: [PortableCoreGatewayRuntimeBlockedAccountInput]
}

struct PortableCoreGatewayQuotaSortSettings: Codable, Equatable {
    var plusRelativeWeight: Double
    var proRelativeToPlusMultiplier: Double
    var teamRelativeToPlusMultiplier: Double

    static func legacy(from settings: CodexBarOpenAISettings.QuotaSortSettings) -> Self {
        Self(
            plusRelativeWeight: settings.plusRelativeWeight,
            proRelativeToPlusMultiplier: settings.proRelativeToPlusMultiplier,
            teamRelativeToPlusMultiplier: settings.teamRelativeToPlusMultiplier
        )
    }
}

struct PortableCoreGatewayAccountInput: Codable, Equatable {
    var accountId: String
    var email: String
    var planType: String
    var primaryUsedPercent: Double
    var secondaryUsedPercent: Double
    var primaryResetAt: Double?
    var secondaryResetAt: Double?
    var primaryLimitWindowSeconds: Int?
    var secondaryLimitWindowSeconds: Int?
    var lastChecked: Double?
    var isSuspended: Bool
    var tokenExpired: Bool

    static func legacy(from account: TokenAccount) -> Self {
        Self(
            accountId: account.accountId,
            email: account.email,
            planType: account.planType,
            primaryUsedPercent: account.primaryUsedPercent,
            secondaryUsedPercent: account.secondaryUsedPercent,
            primaryResetAt: account.primaryResetAt?.timeIntervalSince1970,
            secondaryResetAt: account.secondaryResetAt?.timeIntervalSince1970,
            primaryLimitWindowSeconds: account.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: account.secondaryLimitWindowSeconds,
            lastChecked: account.lastChecked?.timeIntervalSince1970,
            isSuspended: account.isSuspended,
            tokenExpired: account.tokenExpired
        )
    }
}

struct PortableCoreGatewayStickyBindingInput: Codable, Equatable {
    var stickyKey: String
    var accountId: String
    var updatedAt: Double
}

struct PortableCoreGatewayRuntimeBlockedAccountInput: Codable, Equatable {
    var accountId: String
    var retryAt: Double
}

struct PortableCoreGatewayCandidatePlanResult: Codable, Equatable {
    var accountIds: [String]
    var stickyAccountId: String?
    var rustOwner: String
}

struct PortableCoreGatewayStickyBindingStateInput: Codable, Equatable {
    var threadID: String
    var accountId: String
    var updatedAt: Double

    static func legacy(threadID: String, binding: OpenAIAggregateStickyBindingSnapshot) -> Self {
        Self(
            threadID: threadID,
            accountId: binding.accountID,
            updatedAt: binding.updatedAt.timeIntervalSince1970
        )
    }

    func stickyBindingSnapshot() -> OpenAIAggregateStickyBindingSnapshot {
        OpenAIAggregateStickyBindingSnapshot(
            threadID: self.threadID,
            accountID: self.accountId,
            updatedAt: Date(timeIntervalSince1970: self.updatedAt)
        )
    }
}

struct PortableCoreGatewayStickyBindRequest: Codable, Equatable {
    var currentRoutedAccountId: String?
    var stickyKey: String?
    var accountId: String
    var now: Double
    var stickyBindings: [PortableCoreGatewayStickyBindingStateInput]
    var expirationIntervalSeconds: Double
    var maxEntries: Int
}

struct PortableCoreGatewayStickyBindResult: Codable, Equatable {
    var nextRoutedAccountId: String?
    var stickyBindings: [PortableCoreGatewayStickyBindingStateInput]
    var routeChanged: Bool
    var shouldRecordRoute: Bool
    var rustOwner: String
}

struct PortableCoreGatewayStickyClearRequest: Codable, Equatable {
    var threadID: String
    var accountId: String?
    var stickyBindings: [PortableCoreGatewayStickyBindingStateInput]
}

struct PortableCoreGatewayStickyClearResult: Codable, Equatable {
    var stickyBindings: [PortableCoreGatewayStickyBindingStateInput]
    var cleared: Bool
    var rustOwner: String
}

struct PortableCoreGatewayRuntimeBlockedAccountStateInput: Codable, Equatable {
    var accountId: String
    var retryAt: Double
}

struct PortableCoreGatewayRuntimeBlockApplyRequest: Codable, Equatable {
    var currentRoutedAccountId: String?
    var blockedAccountId: String
    var retryAt: Double
    var now: Double
    var runtimeBlockedAccounts: [PortableCoreGatewayRuntimeBlockedAccountStateInput]
}

struct PortableCoreGatewayRuntimeBlockApplyResult: Codable, Equatable {
    var nextRoutedAccountId: String?
    var runtimeBlockedAccounts: [PortableCoreGatewayRuntimeBlockedAccountStateInput]
    var rustOwner: String
}

struct PortableCoreGatewayStateNormalizationRequest: Codable, Equatable {
    var currentRoutedAccountId: String?
    var knownAccountIds: [String]
    var stickyBindings: [PortableCoreGatewayStickyBindingStateInput]
    var runtimeBlockedAccounts: [PortableCoreGatewayRuntimeBlockedAccountStateInput]
    var now: Double
    var stickyExpirationIntervalSeconds: Double
    var stickyMaxEntries: Int
}

struct PortableCoreGatewayStateNormalizationResult: Codable, Equatable {
    var nextRoutedAccountId: String?
    var stickyBindings: [PortableCoreGatewayStickyBindingStateInput]
    var runtimeBlockedAccounts: [PortableCoreGatewayRuntimeBlockedAccountStateInput]
    var rustOwner: String
}

struct PortableCoreOpenAIResponsesRequestNormalizationRequest: Codable, Equatable {
    var route: String
    var bodyJson: JSONValue
}

struct PortableCoreOpenAIResponsesRequestNormalizationResult: Codable, Equatable {
    var normalizedJson: JSONValue
    var rustOwner: String
}

struct PortableCoreOpenRouterRequestNormalizationRequest: Codable, Equatable {
    var route: String
    var selectedModelId: String
    var bodyJson: JSONValue
}

struct PortableCoreOpenRouterRequestNormalizationResult: Codable, Equatable {
    var normalizedJson: JSONValue
    var rustOwner: String
}

struct PortableCoreOpenRouterGatewayAccountStateRequest: Codable, Equatable {
    var provider: PortableCoreOpenRouterProviderInput?
}

struct PortableCoreOpenRouterGatewayAccountStateResult: Codable, Equatable {
    var account: PortableCoreOpenRouterProviderAccountInput?
    var modelId: String?
    var rustOwner: String
}

struct PortableCoreOpenRouterModelInput: Codable, Equatable {
    var id: String
    var name: String?

    static func legacy(from model: CodexBarOpenRouterModel) -> Self {
        Self(id: model.id, name: model.name)
    }

    func openRouterModel() -> CodexBarOpenRouterModel {
        CodexBarOpenRouterModel(id: self.id, name: self.name)
    }
}

struct PortableCoreOpenRouterProviderAccountInput: Codable, Equatable {
    var id: String
    var kind: String
    var label: String
    var apiKey: String?

    static func legacy(from account: CodexBarProviderAccount) -> Self {
        Self(
            id: account.id,
            kind: account.kind.rawValue,
            label: account.label,
            apiKey: account.apiKey
        )
    }

    func providerAccount() -> CodexBarProviderAccount {
        CodexBarProviderAccount(
            id: self.id,
            kind: CodexBarAccountKind(rawValue: self.kind) ?? .apiKey,
            label: self.label,
            apiKey: self.apiKey
        )
    }
}

struct PortableCoreOpenRouterProviderInput: Codable, Equatable {
    var id: String
    var kind: String
    var label: String
    var enabled: Bool
    var baseURL: String?
    var defaultModel: String?
    var selectedModelID: String?
    var pinnedModelIDs: [String]
    var cachedModelCatalog: [PortableCoreOpenRouterModelInput]
    var modelCatalogFetchedAt: Double?
    var activeAccountID: String?
    var accounts: [PortableCoreOpenRouterProviderAccountInput]

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
        case activeAccountID
        case accounts
    }

    init(
        id: String,
        kind: String,
        label: String,
        enabled: Bool,
        baseURL: String?,
        defaultModel: String?,
        selectedModelID: String?,
        pinnedModelIDs: [String],
        cachedModelCatalog: [PortableCoreOpenRouterModelInput],
        modelCatalogFetchedAt: Double?,
        activeAccountID: String?,
        accounts: [PortableCoreOpenRouterProviderAccountInput]
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.enabled = enabled
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.selectedModelID = selectedModelID
        self.pinnedModelIDs = pinnedModelIDs
        self.cachedModelCatalog = cachedModelCatalog
        self.modelCatalogFetchedAt = modelCatalogFetchedAt
        self.activeAccountID = activeAccountID
        self.accounts = accounts
    }

    static func legacy(from provider: CodexBarProvider) -> Self {
        Self(
            id: provider.id,
            kind: provider.kind.rawValue,
            label: provider.label,
            enabled: provider.enabled,
            baseURL: provider.baseURL,
            defaultModel: provider.defaultModel,
            selectedModelID: provider.selectedModelID,
            pinnedModelIDs: provider.pinnedModelIDs,
            cachedModelCatalog: provider.cachedModelCatalog.map(PortableCoreOpenRouterModelInput.legacy(from:)),
            modelCatalogFetchedAt: provider.modelCatalogFetchedAt?.timeIntervalSince1970,
            activeAccountID: provider.activeAccountId,
            accounts: provider.accounts.map(PortableCoreOpenRouterProviderAccountInput.legacy(from:))
        )
    }

    func provider() -> CodexBarProvider {
        CodexBarProvider(
            id: self.id,
            kind: CodexBarProviderKind(rawValue: self.kind) ?? .openAICompatible,
            label: self.label,
            enabled: self.enabled,
            baseURL: self.baseURL,
            defaultModel: self.defaultModel,
            selectedModelID: self.selectedModelID,
            pinnedModelIDs: self.pinnedModelIDs,
            cachedModelCatalog: self.cachedModelCatalog.map { $0.openRouterModel() },
            modelCatalogFetchedAt: self.modelCatalogFetchedAt.map(Date.init(timeIntervalSince1970:)),
            activeAccountId: self.activeAccountID,
            accounts: self.accounts.map { $0.providerAccount() }
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PortableCoreDynamicCodingKey.self)
        self = PortableCoreOpenRouterProviderInput(
            id: try container.decode(String.self, forKey: .init(stringValue: "id")!),
            kind: try container.decode(String.self, forKey: .init(stringValue: "kind")!),
            label: try container.decode(String.self, forKey: .init(stringValue: "label")!),
            enabled: try container.decode(Bool.self, forKey: .init(stringValue: "enabled")!),
            baseURL: try container.decodeIfPresent(String.self, forKey: .init(stringValue: "baseURL")!),
            defaultModel: try container.decodeIfPresent(String.self, forKey: .init(stringValue: "defaultModel")!),
            selectedModelID: try container.decodeIfPresent(String.self, forKey: .init(stringValue: "selectedModelID")!),
            pinnedModelIDs: try container.decodeIfPresent([String].self, forKey: .init(stringValue: "pinnedModelIDs")!) ?? [],
            cachedModelCatalog: try container.decodeIfPresent([PortableCoreOpenRouterModelInput].self, forKey: .init(stringValue: "cachedModelCatalog")!) ?? [],
            modelCatalogFetchedAt: try container.decodeIfPresent(Double.self, forKey: .init(stringValue: "modelCatalogFetchedAt")!),
            activeAccountID: try container.decodeIfPresent(String.self, forKey: .init(stringValue: "activeAccountID")!),
            accounts: try container.decodeIfPresent([PortableCoreOpenRouterProviderAccountInput].self, forKey: .init(stringValue: "accounts")!) ?? []
        )
    }
}

struct PortableCoreOpenRouterNormalizationRequest: Codable, Equatable {
    var globalDefaultModel: String
    var recentOpenRouterModelID: String?
    var activeProviderID: String?
    var activeAccountID: String?
    var switchProviderID: String?
    var switchAccountID: String?
    var providers: [PortableCoreOpenRouterProviderInput]

    enum CodingKeys: String, CodingKey {
        case globalDefaultModel
        case recentOpenRouterModelID
        case activeProviderID
        case activeAccountID
        case switchProviderID
        case switchAccountID
        case providers
    }
}

struct PortableCoreOpenRouterNormalizationResult: Codable, Equatable {
    var changed: Bool
    var removeProviderIDs: [String]
    var mergedProvider: PortableCoreOpenRouterProviderInput?
    var activeProviderID: String?
    var activeAccountID: String?
    var switchProviderID: String?
    var switchAccountID: String?

    enum CodingKeys: String, CodingKey {
        case changed
        case removeProviderIDs
        case mergedProvider
        case activeProviderID
        case activeAccountID
        case switchProviderID
        case switchAccountID
    }
}

struct PortableCoreOpenRouterCompatPersistenceRequest: Codable, Equatable {
    var provider: PortableCoreOpenRouterProviderInput
    var activeProviderID: String?
    var switchProviderID: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case activeProviderID
        case switchProviderID
    }
}

struct PortableCoreOpenRouterCompatPersistenceResult: Codable, Equatable {
    var persistedProvider: PortableCoreOpenRouterProviderInput
    var activeProviderID: String?
    var switchProviderID: String?

    enum CodingKeys: String, CodingKey {
        case persistedProvider
        case activeProviderID
        case switchProviderID
    }
}

struct PortableCoreOAuthStoredAccountInput: Codable, Equatable {
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
    var lastRefresh: Double?
    var apiKey: String?
    var addedAt: Double?
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

    static func legacy(from account: CodexBarProviderAccount) -> Self {
        Self(
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
            lastRefresh: account.lastRefresh?.timeIntervalSince1970,
            apiKey: account.apiKey,
            addedAt: account.addedAt?.timeIntervalSince1970,
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

    func providerAccount() -> CodexBarProviderAccount {
        CodexBarProviderAccount(
            id: self.id,
            kind: CodexBarAccountKind(rawValue: self.kind) ?? .oauthTokens,
            label: self.label,
            email: self.email,
            openAIAccountId: self.openaiAccountID,
            accessToken: self.accessToken,
            refreshToken: self.refreshToken,
            idToken: self.idToken,
            expiresAt: self.expiresAt.map(Date.init(timeIntervalSince1970:)),
            oauthClientID: self.oauthClientID,
            tokenLastRefreshAt: self.tokenLastRefreshAt.map(Date.init(timeIntervalSince1970:)),
            lastRefresh: self.lastRefresh.map(Date.init(timeIntervalSince1970:)),
            apiKey: self.apiKey,
            addedAt: self.addedAt.map(Date.init(timeIntervalSince1970:)),
            planType: self.planType,
            primaryUsedPercent: self.primaryUsedPercent,
            secondaryUsedPercent: self.secondaryUsedPercent,
            primaryResetAt: self.primaryResetAt.map(Date.init(timeIntervalSince1970:)),
            secondaryResetAt: self.secondaryResetAt.map(Date.init(timeIntervalSince1970:)),
            primaryLimitWindowSeconds: self.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: self.secondaryLimitWindowSeconds,
            lastChecked: self.lastChecked.map(Date.init(timeIntervalSince1970:)),
            isSuspended: self.isSuspended,
            tokenExpired: self.tokenExpired,
            organizationName: self.organizationName,
            interopProxyKey: self.interopProxyKey,
            interopNotes: self.interopNotes,
            interopConcurrency: self.interopConcurrency,
            interopPriority: self.interopPriority,
            interopRateMultiplier: self.interopRateMultiplier,
            interopAutoPauseOnExpired: self.interopAutoPauseOnExpired,
            interopCredentialsJSON: self.interopCredentialsJSON,
            interopExtraJSON: self.interopExtraJSON
        )
    }
}

struct PortableCoreAuthJSONSnapshotAccountInput: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Double?
    var oauthClientID: String?
    var tokenLastRefreshAt: Double?
    var planType: String?
}

struct PortableCoreAuthJSONSnapshotInput: Codable, Equatable {
    var localAccountID: String
    var remoteAccountID: String
    var email: String?
    var tokenLastRefreshAt: Double?
    var account: PortableCoreAuthJSONSnapshotAccountInput

    static func legacy(from snapshot: OpenAIAuthJSONSnapshot) -> Self {
        Self(
            localAccountID: snapshot.localAccountID,
            remoteAccountID: snapshot.remoteAccountID,
            email: snapshot.email,
            tokenLastRefreshAt: snapshot.tokenLastRefreshAt?.timeIntervalSince1970,
            account: PortableCoreAuthJSONSnapshotAccountInput(
                accessToken: snapshot.account.accessToken,
                refreshToken: snapshot.account.refreshToken,
                idToken: snapshot.account.idToken,
                expiresAt: snapshot.account.expiresAt?.timeIntervalSince1970,
                oauthClientID: snapshot.account.oauthClientID,
                tokenLastRefreshAt: snapshot.account.tokenLastRefreshAt?.timeIntervalSince1970,
                planType: snapshot.account.planType
            )
        )
    }

    func openAIAuthJSONSnapshot() -> OpenAIAuthJSONSnapshot {
        let account = TokenAccount(
            email: self.email ?? "",
            accountId: self.localAccountID,
            openAIAccountId: self.remoteAccountID,
            accessToken: self.account.accessToken,
            refreshToken: self.account.refreshToken,
            idToken: self.account.idToken,
            expiresAt: self.account.expiresAt.map(Date.init(timeIntervalSince1970:)),
            oauthClientID: self.account.oauthClientID,
            planType: self.account.planType ?? "free",
            tokenLastRefreshAt: self.account.tokenLastRefreshAt.map(Date.init(timeIntervalSince1970:))
        )
        return OpenAIAuthJSONSnapshot(
            account: account,
            localAccountID: self.localAccountID,
            remoteAccountID: self.remoteAccountID,
            email: self.email,
            tokenLastRefreshAt: self.tokenLastRefreshAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}

struct PortableCoreAuthJSONSnapshotParseRequest: Codable, Equatable {
    var text: String
}

struct PortableCoreAuthJSONSnapshotParseResult: Codable, Equatable {
    var snapshot: PortableCoreAuthJSONSnapshotInput?
}

struct PortableCoreOAuthAuthReconciliationRequest: Codable, Equatable {
    var accounts: [PortableCoreOAuthStoredAccountInput]
    var snapshot: PortableCoreAuthJSONSnapshotInput
    var onlyAccountIDs: [String]
}

struct PortableCoreOAuthAuthReconciliationResult: Codable, Equatable {
    var changed: Bool
    var matchedIndex: Int?
    var updatedAccount: PortableCoreOAuthStoredAccountInput?
}

struct PortableCoreOAuthMetadataRefreshRequest: Codable, Equatable {
    var accounts: [PortableCoreOAuthStoredAccountInput]
}

struct PortableCoreOAuthMetadataRefreshResult: Codable, Equatable {
    var changed: Bool
    var accounts: [PortableCoreOAuthStoredAccountInput]
}

struct PortableCoreSharedTeamOrganizationNormalizationRequest: Codable, Equatable {
    var accounts: [PortableCoreOAuthStoredAccountInput]
}

struct PortableCoreSharedTeamOrganizationNormalizationResult: Codable, Equatable {
    var changed: Bool
    var accounts: [PortableCoreOAuthStoredAccountInput]
}

struct PortableCoreReservedProviderIdInput: Codable, Equatable {
    var id: String
    var kind: String
}

struct PortableCoreReservedProviderIdNormalizationRequest: Codable, Equatable {
    var activeProviderID: String?
    var switchProviderID: String?
    var providers: [PortableCoreReservedProviderIdInput]
}

struct PortableCoreReservedProviderIdNormalizationResult: Codable, Equatable {
    var changed: Bool
    var activeProviderID: String?
    var switchProviderID: String?
    var providers: [PortableCoreReservedProviderIdInput]
}

struct PortableCoreLegacyCodexTomlParseRequest: Codable, Equatable {
    var text: String
}

struct PortableCoreLegacyCodexTomlParseResult: Codable, Equatable {
    var model: String?
    var reviewModel: String?
    var reasoningEffort: String?
    var openAIBaseURL: String?

    func legacySnapshot() -> LegacyCodexTomlSnapshot {
        LegacyCodexTomlSnapshot(
            model: self.model,
            reviewModel: self.reviewModel,
            reasoningEffort: self.reasoningEffort,
            openAIBaseURL: self.openAIBaseURL
        )
    }
}

struct PortableCoreGatewayLeaseSnapshotInput: Codable, Equatable {
    var leasedProcessIDs: [Int]
    var sourceProviderId: String

    enum CodingKeys: String, CodingKey {
        case leasedProcessIDs = "leasedProcessIds"
        case sourceProviderId
    }

    static func legacy(from snapshot: OpenRouterGatewayLeaseSnapshot?) -> Self? {
        guard let snapshot else { return nil }
        return Self(
            leasedProcessIDs: snapshot.leasedProcessIDs.map(Int.init),
            sourceProviderId: snapshot.sourceProviderId
        )
    }

    func openRouterGatewayLeaseSnapshot() -> OpenRouterGatewayLeaseSnapshot {
        OpenRouterGatewayLeaseSnapshot(
            processIDs: Set(self.leasedProcessIDs.map(pid_t.init)),
            sourceProviderId: self.sourceProviderId
        )
    }
}

struct PortableCoreGatewayLifecyclePlanRequest: Codable, Equatable {
    var configuredOpenAIUsageMode: String
    var aggregateLeasedProcessIDs: [Int]
    var activeProviderKind: String?
    var openrouterServiceableProviderId: String?
    var lastPublishedOpenrouterSelected: Bool
    var runningCodexProcessIDs: [Int]
    var existingOpenrouterLease: PortableCoreGatewayLeaseSnapshotInput?

    enum CodingKeys: String, CodingKey {
        case configuredOpenAIUsageMode = "configuredOpenaiUsageMode"
        case aggregateLeasedProcessIDs = "aggregateLeasedProcessIds"
        case activeProviderKind
        case openrouterServiceableProviderId
        case lastPublishedOpenrouterSelected
        case runningCodexProcessIDs = "runningCodexProcessIds"
        case existingOpenrouterLease
    }
}

struct PortableCoreGatewayLifecyclePlanResult: Codable, Equatable {
    var effectiveOpenAIUsageMode: String
    var shouldRunOpenAIGateway: Bool
    var shouldRunOpenrouterGateway: Bool
    var nextOpenrouterLease: PortableCoreGatewayLeaseSnapshotInput?
    var openrouterLeaseChanged: Bool
    var openrouterLeaseShouldPoll: Bool
    var rustOwner: String

    enum CodingKeys: String, CodingKey {
        case effectiveOpenAIUsageMode = "effectiveOpenaiUsageMode"
        case shouldRunOpenAIGateway = "shouldRunOpenaiGateway"
        case shouldRunOpenrouterGateway
        case nextOpenrouterLease
        case openrouterLeaseChanged
        case openrouterLeaseShouldPoll
        case rustOwner
    }
}

struct PortableCoreOAuthAuthorizationUrlRequest: Codable, Equatable {
    var authUrl: String
    var clientId: String
    var redirectUri: String
    var scope: String
    var codeVerifier: String
    var expectedState: String
    var originator: String
}

struct PortableCoreOAuthAuthorizationUrlResult: Codable, Equatable {
    var authUrl: String
}

struct PortableCoreOAuthCallbackInterpretationRequest: Codable, Equatable {
    var callbackInput: String?
    var code: String?
    var returnedState: String?
    var expectedState: String
}

struct PortableCoreOAuthCallbackInterpretationResult: Codable, Equatable {
    var code: String?
    var returnedState: String?
    var stateMismatch: Bool
}

struct PortableCoreUpdateArtifactInput: Codable, Equatable {
    var architecture: String
    var format: String
    var downloadUrl: String
    var sha256: String?

    func appUpdateArtifact() -> AppUpdateArtifact? {
        guard let architecture = UpdateArtifactArchitecture(rawValue: self.architecture),
              let format = UpdateArtifactFormat(rawValue: self.format),
              let downloadURL = URL(string: self.downloadUrl) else {
            return nil
        }
        return AppUpdateArtifact(
            architecture: architecture,
            format: format,
            downloadURL: downloadURL,
            sha256: self.sha256
        )
    }
}

struct PortableCoreUpdateReleaseInput: Codable, Equatable {
    var version: String
    var deliveryMode: String
    var minimumAutomaticUpdateVersion: String?
    var artifacts: [PortableCoreUpdateArtifactInput]

    static func legacy(from release: AppUpdateRelease) -> PortableCoreUpdateReleaseInput {
        PortableCoreUpdateReleaseInput(
            version: release.version,
            deliveryMode: release.deliveryMode.rawValue,
            minimumAutomaticUpdateVersion: release.minimumAutomaticUpdateVersion,
            artifacts: release.artifacts.map {
                PortableCoreUpdateArtifactInput(
                    architecture: $0.architecture.rawValue,
                    format: $0.format.rawValue,
                    downloadUrl: $0.downloadURL.absoluteString,
                    sha256: $0.sha256
                )
            }
        )
    }
}

struct PortableCoreUpdateEnvironmentFacts: Codable, Equatable {
    var currentVersion: String
    var architecture: String
    var installLocation: String
    var signatureUsable: Bool
    var signatureSummary: String
    var gatekeeperPasses: Bool
    var gatekeeperSummary: String
    var automaticUpdaterAvailable: Bool
}

struct PortableCoreUpdateResolutionRequest: Codable, Equatable {
    var release: PortableCoreUpdateReleaseInput
    var environment: PortableCoreUpdateEnvironmentFacts
}

struct PortableCoreGitHubInstallableReleaseSelectionFromJSONRequest: Codable, Equatable {
    var jsonText: String
}

struct PortableCoreGitHubInstallableReleaseInput: Codable, Equatable {
    var version: String
    var publishedAt: Double?
    var summary: String?
    var releaseNotesUrl: String
    var downloadPageUrl: String
    var deliveryMode: String
    var minimumAutomaticUpdateVersion: String?
    var artifacts: [PortableCoreUpdateArtifactInput]

    func appUpdateRelease() -> AppUpdateRelease? {
        guard let releaseNotesURL = URL(string: self.releaseNotesUrl),
              let downloadPageURL = URL(string: self.downloadPageUrl),
              let deliveryMode = UpdateDeliveryMode(rawValue: self.deliveryMode) else {
            return nil
        }
        return AppUpdateRelease(
            version: self.version,
            publishedAt: self.publishedAt.map(Date.init(timeIntervalSince1970:)),
            summary: self.summary,
            releaseNotesURL: releaseNotesURL,
            downloadPageURL: downloadPageURL,
            deliveryMode: deliveryMode,
            minimumAutomaticUpdateVersion: self.minimumAutomaticUpdateVersion,
            artifacts: self.artifacts.compactMap { $0.appUpdateArtifact() }
        )
    }
}

struct PortableCoreGitHubInstallableReleaseSelectionResult: Codable, Equatable {
    var release: PortableCoreGitHubInstallableReleaseInput?
}

struct PortableCoreUpdateArtifactSelectionRequest: Codable, Equatable {
    var architecture: String
    var artifacts: [PortableCoreUpdateArtifactInput]
}

struct PortableCoreUpdateArtifactSelectionResult: Codable, Equatable {
    var selectedArtifact: PortableCoreUpdateArtifactInput?
}

struct PortableCoreUpdateBlockerEvaluationRequest: Codable, Equatable {
    var release: PortableCoreUpdateReleaseInput
    var environment: PortableCoreUpdateEnvironmentFacts
}

struct PortableCoreUpdateBlockerEvaluationResult: Codable, Equatable {
    var blockers: [PortableCoreUpdateBlockerResult]
}

struct PortableCoreUpdateBlockerResult: Codable, Equatable {
    var code: String
    var detail: String

    func appUpdateBlocker() -> AppUpdateBlocker? {
        switch self.code {
        case "guidedDownloadOnlyRelease":
            return .guidedDownloadOnlyRelease
        case "bootstrapRequired":
            let tokens = self.detail.components(separatedBy: " ")
            if tokens.count >= 7 {
                return .bootstrapRequired(currentVersion: tokens[1], minimumAutomaticVersion: tokens[6])
            }
            return .bootstrapRequired(currentVersion: "", minimumAutomaticVersion: "")
        case "automaticUpdaterUnavailable":
            return .automaticUpdaterUnavailable
        case "missingTrustedSignature":
            return .missingTrustedSignature(summary: self.detail)
        case "failingGatekeeperAssessment":
            return .failingGatekeeperAssessment(summary: self.detail)
        case "unsupportedInstallLocation":
            return .unsupportedInstallLocation(.other)
        default:
            return nil
        }
    }
}

struct PortableCoreUpdateAvailabilityResult: Codable, Equatable {
    var updateAvailable: Bool
    var selectedArtifact: PortableCoreUpdateArtifactInput?
    var blockers: [PortableCoreUpdateBlockerResult]
}

extension PortableCoreCanonicalAccountSnapshot {
    func tokenAccount() -> TokenAccount {
        TokenAccount(
            email: self.email,
            accountId: self.localAccountID,
            openAIAccountId: self.remoteAccountID,
            accessToken: self.accessToken,
            refreshToken: self.refreshToken,
            idToken: self.idToken,
            expiresAt: self.expiresAt.map(Date.init(timeIntervalSince1970:)),
            oauthClientID: self.oauthClientID,
            planType: self.planType,
            primaryUsedPercent: self.primaryUsedPercent,
            secondaryUsedPercent: self.secondaryUsedPercent,
            primaryResetAt: self.primaryResetAt.map(Date.init(timeIntervalSince1970:)),
            secondaryResetAt: self.secondaryResetAt.map(Date.init(timeIntervalSince1970:)),
            primaryLimitWindowSeconds: self.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: self.secondaryLimitWindowSeconds,
            lastChecked: self.lastChecked.map(Date.init(timeIntervalSince1970:)),
            isActive: self.isActive,
            isSuspended: self.isSuspended,
            tokenExpired: self.tokenExpired,
            tokenLastRefreshAt: self.tokenLastRefreshAt.map(Date.init(timeIntervalSince1970:)),
            organizationName: self.organizationName
        )
    }
}
