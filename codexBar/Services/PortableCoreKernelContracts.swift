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
    var stateSqliteResolvedVersion: Int?
    var logsSqliteResolvedVersion: Int?
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
    var sessionsRootPath: String
    var archivedSessionsRootPath: String
    var oauthFlowsDirectoryPath: String
    var menuHostRootPath: String
    var menuHostAppPath: String
    var menuHostLeasePath: String
    var barConfigPath: String
    var costCachePath: String
    var costSessionCachePath: String
    var costEventLedgerPath: String
    var switchJournalPath: String
    var managedLaunchRootPath: String
    var managedLaunchBinPath: String
    var managedLaunchHitsPath: String
    var managedLaunchStatePath: String
    var openaiGatewayRootPath: String
    var openaiGatewayStatePath: String
    var openaiGatewayRouteJournalPath: String
    var openrouterGatewayRootPath: String
    var openrouterGatewayStatePath: String
    var configBackupPath: String
    var authBackupPath: String
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

    static func failClosed() -> Self {
        Self(
            shouldRefresh: false,
            accountId: nil,
            skipReason: "kernelUnavailable"
        )
    }
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

    static func failClosed(
        request: PortableCoreUsageModeTransitionRequest
    ) -> Self {
        let oauthProvider = request.providers.first { $0.providerId == request.oauthProviderId }
        let hasValidSwitchSelection = request.providers.contains { provider in
            provider.providerId == request.switchModeSelectionProviderId
                && provider.accountIds.contains(request.switchModeSelectionAccountId ?? "")
        }

        let nextSwitchProviderId =
            request.targetMode == CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue
                ? request.activeProviderId
                : request.switchModeSelectionProviderId
        let nextSwitchAccountId =
            request.targetMode == CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue
                ? request.activeAccountId
                : request.switchModeSelectionAccountId

        let nextActiveProviderId: String?
        let nextActiveAccountId: String?
        if request.targetMode == CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue,
           let oauthProvider {
            nextActiveProviderId = oauthProvider.providerId
            nextActiveAccountId = oauthProvider.activeAccountId
        } else if request.targetMode == CodexBarOpenAIAccountUsageMode.switchAccount.rawValue,
                  hasValidSwitchSelection {
            nextActiveProviderId = request.switchModeSelectionProviderId
            nextActiveAccountId = request.switchModeSelectionAccountId
        } else {
            nextActiveProviderId = request.activeProviderId
            nextActiveAccountId = request.activeAccountId
        }

        let shouldSyncCodex = request.targetMode == CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue
            || nextActiveProviderId == request.oauthProviderId

        return Self(
            nextMode: request.targetMode,
            nextActiveProviderId: nextActiveProviderId,
            nextActiveAccountId: nextActiveAccountId,
            nextSwitchModeSelectionProviderId: nextSwitchProviderId,
            nextSwitchModeSelectionAccountId: nextSwitchAccountId,
            shouldSyncCodex: shouldSyncCodex,
            rustOwner: "swift.failClosedUsageModeTransition"
        )
    }
}

struct PortableCoreSettingsSaveSyncRequest: Codable, Equatable {
    var previousUsageMode: String
    var requestedUsageMode: String?
    var activeProviderId: String?
    var oauthProviderId: String?
}

struct PortableCoreSettingsSaveSyncResult: Codable, Equatable {
    var shouldSyncCodex: Bool
    var rustOwner: String

    static func failClosed(
        request: PortableCoreSettingsSaveSyncRequest
    ) -> Self {
        let shouldSyncCodex: Bool
        if let requestedUsageMode = request.requestedUsageMode,
           requestedUsageMode != request.previousUsageMode {
            shouldSyncCodex =
                request.activeProviderId == request.oauthProviderId
                || requestedUsageMode == CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue
        } else {
            shouldSyncCodex = false
        }

        return Self(
            shouldSyncCodex: shouldSyncCodex,
            rustOwner: "swift.failClosedSettingsSaveSync"
        )
    }
}

struct PortableCoreOAuthAccountSyncRequest: Codable, Equatable {
    var activeProviderKind: String?
    var hasActiveAccount: Bool
}

struct PortableCoreOAuthAccountSyncResult: Codable, Equatable {
    var shouldSyncCodex: Bool
    var rustOwner: String

    static func failClosed(
        request: PortableCoreOAuthAccountSyncRequest
    ) -> Self {
        Self(
            shouldSyncCodex: request.activeProviderKind == CodexBarProviderKind.openAIOAuth.rawValue && request.hasActiveAccount,
            rustOwner: "swift.failClosedOAuthAccountSync"
        )
    }
}

struct PortableCoreActiveSelectionCandidateInput: Codable, Equatable {
    var providerId: String?
    var accountId: String?
}

struct PortableCoreProviderRemovalTransitionRequest: Codable, Equatable {
    var currentActiveProviderId: String?
    var currentActiveAccountId: String?
    var removedProviderId: String
    var removedAccountId: String?
    var providerStillExists: Bool
    var nextProviderActiveAccountId: String?
    var fallbackCandidates: [PortableCoreActiveSelectionCandidateInput]
}

struct PortableCoreProviderRemovalTransitionResult: Codable, Equatable {
    var nextActiveProviderId: String?
    var nextActiveAccountId: String?
    var shouldSyncCodex: Bool
    var rustOwner: String

    static func failClosed(
        request: PortableCoreProviderRemovalTransitionRequest
    ) -> Self {
        let nextActiveProviderId: String?
        let nextActiveAccountId: String?

        if request.providerStillExists == false {
            if request.currentActiveProviderId == request.removedProviderId {
                let fallback = request.fallbackCandidates.first {
                    $0.providerId?.isEmpty == false
                }
                nextActiveProviderId = fallback?.providerId
                nextActiveAccountId = fallback?.accountId
            } else {
                nextActiveProviderId = request.currentActiveProviderId
                nextActiveAccountId = request.currentActiveAccountId
            }
        } else if request.currentActiveProviderId == request.removedProviderId,
                  request.currentActiveAccountId == request.removedAccountId {
            nextActiveProviderId = request.removedProviderId
            nextActiveAccountId = request.nextProviderActiveAccountId
        } else {
            nextActiveProviderId = request.currentActiveProviderId
            nextActiveAccountId = request.currentActiveAccountId
        }

        let shouldSyncCodex: Bool
        if request.providerStillExists {
            shouldSyncCodex =
                request.currentActiveProviderId == request.removedProviderId
                && request.currentActiveAccountId == request.removedAccountId
        } else {
            shouldSyncCodex =
                request.currentActiveProviderId == request.removedProviderId
                && nextActiveProviderId?.isEmpty == false
        }

        return Self(
            nextActiveProviderId: nextActiveProviderId,
            nextActiveAccountId: nextActiveAccountId,
            shouldSyncCodex: shouldSyncCodex,
            rustOwner: "swift.failClosedProviderRemovalTransition"
        )
    }
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

struct PortableCoreWhamUsageParseRequest: Codable, Equatable {
    var bodyJson: JSONValue
}

struct PortableCoreWhamUsageParseResult: Codable, Equatable {
    var planType: String
    var primaryUsedPercent: Double
    var secondaryUsedPercent: Double
    var primaryResetAt: Double?
    var secondaryResetAt: Double?
    var primaryLimitWindowSeconds: Int?
    var secondaryLimitWindowSeconds: Int?

    func whamUsageResult() -> WhamUsageResult {
        WhamUsageResult(
            planType: self.planType,
            primaryUsedPercent: self.primaryUsedPercent,
            secondaryUsedPercent: self.secondaryUsedPercent,
            primaryResetAt: self.primaryResetAt.map(Date.init(timeIntervalSince1970:)),
            secondaryResetAt: self.secondaryResetAt.map(Date.init(timeIntervalSince1970:)),
            primaryLimitWindowSeconds: self.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: self.secondaryLimitWindowSeconds
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

    static func failClosed(now: Double) -> Self {
        Self(
            todayCostUsd: 0,
            todayTokens: 0,
            last30DaysCostUsd: 0,
            last30DaysTokens: 0,
            lifetimeCostUsd: 0,
            lifetimeTokens: 0,
            dailyEntries: [],
            updatedAt: now
        )
    }

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

struct PortableCoreHistoricalModelsMergeRequest: Codable, Equatable {
    var preferredHistoricalModels: [String]
    var fallbackHistoricalModels: [String]
}

struct PortableCoreHistoricalModelsMergeResult: Codable, Equatable {
    var models: [String]
    var rustOwner: String

    static func failClosed(
        request: PortableCoreHistoricalModelsMergeRequest
    ) -> Self {
        var models: [String] = []
        var seen: Set<String> = []
        for model in request.preferredHistoricalModels + request.fallbackHistoricalModels {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else {
                continue
            }
            models.append(trimmed)
        }
        models.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Self(
            models: models,
            rustOwner: "swift.failClosedHistoricalModelsMerge"
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

    static func failClosed(recentActivityWindowSeconds: Double) -> Self {
        Self(
            recentActivityWindowSeconds: recentActivityWindowSeconds,
            sessions: [],
            summary: PortableCoreLiveSessionAttributionSummary(
                inUseSessionCounts: [:],
                unknownSessionCount: 0
            )
        )
    }

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

    static func failClosed(recentActivityWindowSeconds: Double) -> Self {
        Self(
            recentActivityWindowSeconds: recentActivityWindowSeconds,
            diagnosticMessage: nil,
            unavailableReason: nil,
            threads: [],
            summary: PortableCoreRunningThreadSummary(
                summaryIsUnavailable: false,
                runningThreadCounts: [:],
                unknownThreadCount: 0
            )
        )
    }

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

struct PortableCoreRecentOpenRouterModelRequest: Codable, Equatable {
    var rootPaths: [String]
}

struct PortableCoreRecentOpenRouterModelResult: Codable, Equatable {
    var modelId: String?
    var rustOwner: String
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

    static func failClosed(
        proxyResolutionMode: String,
        systemProxySnapshot: PortableCoreGatewayProxySnapshot?
    ) -> Self {
        let systemSnapshot = systemProxySnapshot?.systemProxySnapshot()

        if proxyResolutionMode == "loopbackProxySafe" {
            let effectiveSnapshot = systemSnapshot?.applyingLoopbackSafePolicy()
            return Self(
                proxyResolutionMode: proxyResolutionMode,
                systemProxySnapshot: systemProxySnapshot,
                effectiveProxySnapshot: PortableCoreGatewayProxySnapshot.legacy(
                    from: effectiveSnapshot?.effectiveSnapshot
                ),
                loopbackProxySafeApplied: effectiveSnapshot?.applied ?? false
            )
        }

        return Self(
            proxyResolutionMode: proxyResolutionMode,
            systemProxySnapshot: systemProxySnapshot,
            effectiveProxySnapshot: systemProxySnapshot,
            loopbackProxySafeApplied: false
        )
    }

    func resolvedPolicy() -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        OpenAIAccountGatewayResolvedUpstreamTransportPolicy(
            proxyResolutionMode: self.proxyResolutionMode == "loopbackProxySafe" ? .loopbackProxySafe : .systemDefault,
            systemProxySnapshot: self.systemProxySnapshot?.systemProxySnapshot(),
            effectiveProxySnapshot: self.effectiveProxySnapshot?.systemProxySnapshot(),
            loopbackProxySafeApplied: self.loopbackProxySafeApplied
        )
    }
}

struct PortableCoreGatewayTransportFailureClassificationRequest: Codable, Equatable {
    var errorDomain: String?
    var errorCode: Int?
    var allowProtocolViolation: Bool
}

struct PortableCoreGatewayTransportFailureClassificationResult: Codable, Equatable {
    var failureClass: String
    var rustOwner: String

    static func failClosed(
        request: PortableCoreGatewayTransportFailureClassificationRequest
    ) -> Self {
        let isProtocolViolation =
            request.allowProtocolViolation &&
            request.errorDomain == NSURLErrorDomain &&
            (request.errorCode == URLError.badServerResponse.rawValue ||
                request.errorCode == URLError.cannotParseResponse.rawValue)
        return Self(
            failureClass: isProtocolViolation
                ? OpenAIAccountGatewayFailureClass.protocolViolation.rawValue
                : OpenAIAccountGatewayFailureClass.transport.rawValue,
            rustOwner: "swift.failClosedGatewayTransportFailureClassification"
        )
    }
}

struct PortableCoreGatewayStatusPolicyRequest: Codable, Equatable {
    var statusCode: Int
    var now: Double
    var allowFallbackRuntimeBlock: Bool
    var suggestedRetryAt: Double?
    var retryAfterValue: String?
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

    static func failClosed(
        statusCode: Int,
        now: Double,
        allowFallbackRuntimeBlock: Bool,
        suggestedRetryAt: Double?,
        retryAfterValue: String?,
        account: PortableCoreGatewayAccountInput?
    ) -> Self {
        let fallbackRetryAt: Double?
        if allowFallbackRuntimeBlock {
            fallbackRetryAt = suggestedRetryAt ?? (now + 10 * 60)
        } else {
            fallbackRetryAt = nil
        }

        return Self(
            failureClass: nil,
            failoverDisposition: "doNotFailover",
            isAccountScopedStatus: false,
            shouldRetry: false,
            shouldRuntimeBlockAccount: allowFallbackRuntimeBlock,
            runtimeBlockRetryAt: fallbackRetryAt,
            rustOwner: "swift.failClosedGatewayStatusPolicy"
        )
    }

    func gatewayFailure(statusCode: Int) -> OpenAIAccountGatewayUpstreamFailure? {
        switch self.failureClass {
        case OpenAIAccountGatewayFailureClass.accountStatus.rawValue:
            return .accountStatus(statusCode)
        case OpenAIAccountGatewayFailureClass.upstreamStatus.rawValue:
            return .upstreamStatus(statusCode)
        default:
            return nil
        }
    }
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

    static func failClosed() -> Self {
        Self(
            shouldAttemptStickyContextRecovery: false,
            rustOwner: "swift.failClosedGatewayStickyRecoveryPolicy"
        )
    }
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

    static func failClosed() -> Self {
        Self(
            isRuntimeLimitSignal: false,
            message: nil,
            retryAt: nil,
            retryAtHumanText: nil,
            rustOwner: "swift.failClosedGatewayProtocolSignalInterpretation"
        )
    }

    func accountProtocolSignal() -> OpenAIAccountProtocolSignal? {
        guard self.isRuntimeLimitSignal else {
            return nil
        }

        return OpenAIAccountProtocolSignal(
            message: self.message ?? self.retryAtHumanText,
            retryAt: self.retryAt.map(Date.init(timeIntervalSince1970:))
        )
    }
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

    static func failClosed() -> Self {
        Self(
            decision: "streamNow",
            message: nil,
            retryAt: nil,
            retryAtHumanText: nil,
            rustOwner: "swift.failClosedGatewayProtocolPreviewDecision"
        )
    }

    func protocolPreviewDecision() -> OpenAIAccountGatewayProtocolPreviewDecision {
        switch self.decision {
        case "needMoreData":
            return .needMoreData
        case "accountSignal":
            return .accountSignal(
                OpenAIAccountProtocolSignal(
                    message: self.message ?? self.retryAtHumanText,
                    retryAt: self.retryAt.map(Date.init(timeIntervalSince1970:))
                )
            )
        default:
            return .streamNow
        }
    }
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

    static func failClosed() -> Self {
        Self(
            accountIds: [],
            stickyAccountId: nil,
            rustOwner: "swift.failClosedGatewayCandidatePlan"
        )
    }
}

struct PortableCoreGatewayStickyKeyResolutionRequest: Codable, Equatable {
    var sessionID: String?
    var windowID: String?
}

struct PortableCoreGatewayStickyKeyResolutionResult: Codable, Equatable {
    var stickyKey: String?
    var rustOwner: String

    static func failClosed(
        request: PortableCoreGatewayStickyKeyResolutionRequest
    ) -> Self {
        let stickyKey = [request.sessionID, request.windowID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
        return Self(
            stickyKey: stickyKey,
            rustOwner: "swift.failClosedGatewayStickyKeyResolution"
        )
    }
}

struct PortableCoreGatewayResponseHeaderFieldInput: Codable, Equatable {
    var name: String
    var value: String
}

struct PortableCoreGatewayResponseHeadRenderRequest: Codable, Equatable {
    var statusCode: Int
    var headerFields: [PortableCoreGatewayResponseHeaderFieldInput]
}

struct PortableCoreGatewayResponseHeadRenderResult: Codable, Equatable {
    var headerText: String
    var filteredHeaders: [PortableCoreGatewayResponseHeaderFieldInput]
    var rustOwner: String

    static func failClosed(
        request: PortableCoreGatewayResponseHeadRenderRequest
    ) -> Self {
        var filteredHeaders: [PortableCoreGatewayResponseHeaderFieldInput] = []
        var headerLines = ["HTTP/1.1 \(request.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: request.statusCode).capitalized)"]
        for field in request.headerFields {
            let lowercased = field.name.lowercased()
            if lowercased == "content-length" || lowercased == "transfer-encoding" || lowercased == "connection" {
                continue
            }
            filteredHeaders.append(field)
            headerLines.append("\(field.name): \(field.value)")
        }
        filteredHeaders.append(.init(name: "Connection", value: "close"))
        headerLines.append("Connection: close")
        headerLines.append("")
        headerLines.append("")
        return Self(
            headerText: headerLines.joined(separator: "\r\n"),
            filteredHeaders: filteredHeaders,
            rustOwner: "swift.failClosedGatewayResponseHeadRender"
        )
    }
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

    static func failClosed(
        currentRoutedAccountId: String?,
        stickyKey: String?,
        accountId: String,
        now: Double,
        stickyBindings: [PortableCoreGatewayStickyBindingStateInput],
        expirationIntervalSeconds: Double,
        maxEntries: Int
    ) -> Self {
        let trimmedStickyKey = stickyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldBind = trimmedStickyKey?.isEmpty == false
        let nextRoutedAccountId = accountId
        let routeChanged = currentRoutedAccountId != accountId

        var bindingsByThread = Dictionary(
            uniqueKeysWithValues: stickyBindings.map { ($0.threadID, $0) }
        )
        let shouldRecordRoute: Bool
        if let trimmedStickyKey, shouldBind {
            shouldRecordRoute = bindingsByThread[trimmedStickyKey]?.accountId != accountId
            bindingsByThread[trimmedStickyKey] = PortableCoreGatewayStickyBindingStateInput(
                threadID: trimmedStickyKey,
                accountId: accountId,
                updatedAt: now
            )
        } else {
            shouldRecordRoute = false
        }

        let cutoff = now - expirationIntervalSeconds
        var nextBindings = bindingsByThread.values
            .filter { $0.updatedAt >= cutoff }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.threadID < $1.threadID
            }

        if nextBindings.count > maxEntries {
            nextBindings = Array(nextBindings.prefix(maxEntries))
        }

        return Self(
            nextRoutedAccountId: nextRoutedAccountId,
            stickyBindings: nextBindings,
            routeChanged: routeChanged,
            shouldRecordRoute: shouldRecordRoute,
            rustOwner: "swift.failClosedGatewayStickyBind"
        )
    }
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

    static func failClosed(
        threadID: String,
        accountId: String?,
        stickyBindings: [PortableCoreGatewayStickyBindingStateInput]
    ) -> Self {
        var bindingsByThread = Dictionary(
            uniqueKeysWithValues: stickyBindings.map { ($0.threadID, $0) }
        )
        let cleared: Bool
        if let accountId {
            if bindingsByThread[threadID]?.accountId == accountId {
                bindingsByThread.removeValue(forKey: threadID)
                cleared = true
            } else {
                cleared = false
            }
        } else {
            cleared = bindingsByThread.removeValue(forKey: threadID) != nil
        }

        let nextBindings = bindingsByThread.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.threadID < $1.threadID
        }

        return Self(
            stickyBindings: nextBindings,
            cleared: cleared,
            rustOwner: "swift.failClosedGatewayStickyClear"
        )
    }
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

    static func failClosed(
        currentRoutedAccountId: String?,
        blockedAccountId: String,
        retryAt: Double,
        now: Double,
        runtimeBlockedAccounts: [PortableCoreGatewayRuntimeBlockedAccountStateInput]
    ) -> Self {
        var blockedByAccount = Dictionary(
            uniqueKeysWithValues: runtimeBlockedAccounts.map { ($0.accountId, $0.retryAt) }
        )
        blockedByAccount[blockedAccountId] = retryAt
        let nextBlockedAccounts = blockedByAccount
            .filter { $0.value > now }
            .map {
                PortableCoreGatewayRuntimeBlockedAccountStateInput(
                    accountId: $0.key,
                    retryAt: $0.value
                )
            }
            .sorted { $0.accountId < $1.accountId }

        return Self(
            nextRoutedAccountId: currentRoutedAccountId == blockedAccountId ? nil : currentRoutedAccountId,
            runtimeBlockedAccounts: nextBlockedAccounts,
            rustOwner: "swift.failClosedGatewayRuntimeBlockApply"
        )
    }
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

    static func failClosed(
        currentRoutedAccountId: String?,
        knownAccountIds: [String],
        stickyBindings: [PortableCoreGatewayStickyBindingStateInput],
        runtimeBlockedAccounts: [PortableCoreGatewayRuntimeBlockedAccountStateInput],
        now: Double,
        stickyExpirationIntervalSeconds: Double,
        stickyMaxEntries: Int
    ) -> Self {
        let knownIds = Set(knownAccountIds)
        let cutoff = now - stickyExpirationIntervalSeconds
        var nextStickyBindings = stickyBindings
            .filter { knownIds.contains($0.accountId) && $0.updatedAt >= cutoff }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.threadID < $1.threadID
            }
        if nextStickyBindings.count > stickyMaxEntries {
            nextStickyBindings = Array(nextStickyBindings.prefix(stickyMaxEntries))
        }

        let nextRuntimeBlockedAccounts = runtimeBlockedAccounts
            .filter { knownIds.contains($0.accountId) && $0.retryAt > now }
            .sorted { $0.accountId < $1.accountId }

        return Self(
            nextRoutedAccountId: currentRoutedAccountId.flatMap { knownIds.contains($0) ? $0 : nil },
            stickyBindings: nextStickyBindings,
            runtimeBlockedAccounts: nextRuntimeBlockedAccounts,
            rustOwner: "swift.failClosedGatewayStateNormalization"
        )
    }
}

struct PortableCoreOpenAIResponsesRequestNormalizationRequest: Codable, Equatable {
    var route: String
    var bodyJson: JSONValue
}

struct PortableCoreOpenAIResponsesRequestNormalizationResult: Codable, Equatable {
    var normalizedJson: JSONValue
    var rustOwner: String

    static func failClosed(bodyJson: JSONValue) -> Self {
        Self(
            normalizedJson: bodyJson,
            rustOwner: "swift.failClosedOpenAIResponsesRequestNormalization"
        )
    }
}

struct PortableCoreOpenRouterRequestNormalizationRequest: Codable, Equatable {
    var route: String
    var selectedModelId: String
    var bodyJson: JSONValue
}

struct PortableCoreOpenRouterRequestNormalizationResult: Codable, Equatable {
    var normalizedJson: JSONValue
    var rustOwner: String

    static func failClosed(bodyJson: JSONValue) -> Self {
        Self(
            normalizedJson: bodyJson,
            rustOwner: "swift.failClosedOpenRouterRequestNormalization"
        )
    }
}

struct PortableCoreOpenRouterGatewayAccountStateRequest: Codable, Equatable {
    var provider: PortableCoreOpenRouterProviderInput?
}

struct PortableCoreOpenRouterGatewayAccountStateResult: Codable, Equatable {
    var account: PortableCoreOpenRouterProviderAccountInput?
    var modelId: String?
    var rustOwner: String

    static func failClosed() -> Self {
        Self(
            account: nil,
            modelId: nil,
            rustOwner: "swift.failClosedOpenRouterGatewayAccountState"
        )
    }
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
    var openAIAPIKey: String?

    enum CodingKeys: String, CodingKey {
        case snapshot
        case openAIAPIKey = "openaiApiKey"
    }
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

struct PortableCoreOAuthIdentityNormalizationRequest: Codable, Equatable {
    var accounts: [PortableCoreOAuthStoredAccountInput]
}

struct PortableCoreOAuthIdentityNormalizationResult: Codable, Equatable {
    var changed: Bool
    var migratedAccountIDs: [String: String]
    var accounts: [PortableCoreOAuthStoredAccountInput]

    enum CodingKeys: String, CodingKey {
        case changed
        case migratedAccountIDs = "migratedAccountIds"
        case accounts
    }
}

struct PortableCoreOAuthQuotaSnapshotSanitizationRequest: Codable, Equatable {
    var now: Double
    var accounts: [PortableCoreOAuthStoredAccountInput]
}

struct PortableCoreOAuthQuotaSnapshotSanitizationResult: Codable, Equatable {
    var changed: Bool
    var accounts: [PortableCoreOAuthStoredAccountInput]
}

struct PortableCoreOAuthProviderAssemblyRequest: Codable, Equatable {
    var importedAccounts: [PortableCoreOAuthStoredAccountInput]
    var snapshot: PortableCoreAuthJSONSnapshotInput?
}

struct PortableCoreOAuthProviderAssemblyResult: Codable, Equatable {
    var shouldCreate: Bool
    var activeAccountID: String?
    var accounts: [PortableCoreOAuthStoredAccountInput]
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

struct PortableCoreProviderSecretsEnvParseRequest: Codable, Equatable {
    var text: String
}

struct PortableCoreProviderSecretsEnvParseResult: Codable, Equatable {
    var values: [String: String]
}

struct PortableCoreInteropProxyMergeRequest: Codable, Equatable {
    var existingJSON: String?
    var incomingJSON: String?
}

struct PortableCoreInteropProxyMergeResult: Codable, Equatable {
    var mergedJSON: String?

    static func failClosed(
        request: PortableCoreInteropProxyMergeRequest
    ) -> Self {
        Self(mergedJSON: request.incomingJSON ?? request.existingJSON)
    }
}

struct PortableCoreOAuthInteropMetadataEntry: Codable, Equatable {
    var accountId: String
    var proxyKey: String?
    var notes: String?
    var concurrency: Int?
    var priority: Int?
    var rateMultiplier: Double?
    var autoPauseOnExpired: Bool?
    var credentialsJSON: String?
    var extraJSON: String?
}

struct PortableCoreOAuthInteropContextApplyRequest: Codable, Equatable {
    var accounts: [PortableCoreOAuthStoredAccountInput]
    var metadataEntries: [PortableCoreOAuthInteropMetadataEntry]
    var existingJSON: String?
    var incomingJSON: String?
}

struct PortableCoreOAuthInteropContextApplyResult: Codable, Equatable {
    var accounts: [PortableCoreOAuthStoredAccountInput]
    var mergedJSON: String?

    static func failClosed(
        request: PortableCoreOAuthInteropContextApplyRequest
    ) -> Self {
        var accounts = request.accounts
        let metadataByAccountID = Dictionary(
            uniqueKeysWithValues: request.metadataEntries.map { ($0.accountId, $0) }
        )
        for index in accounts.indices {
            guard let metadata = metadataByAccountID[accounts[index].id] else { continue }
            accounts[index].interopProxyKey = metadata.proxyKey
            accounts[index].interopNotes = metadata.notes
            accounts[index].interopConcurrency = metadata.concurrency
            accounts[index].interopPriority = metadata.priority
            accounts[index].interopRateMultiplier = metadata.rateMultiplier
            accounts[index].interopAutoPauseOnExpired = metadata.autoPauseOnExpired
            accounts[index].interopCredentialsJSON = metadata.credentialsJSON
            accounts[index].interopExtraJSON = metadata.extraJSON
        }
        return Self(
            accounts: accounts,
            mergedJSON: PortableCoreInteropProxyMergeResult.failClosed(
                request: .init(existingJSON: request.existingJSON, incomingJSON: request.incomingJSON)
            ).mergedJSON
        )
    }
}

struct PortableCoreOAuthInteropExportAccountInput: Codable, Equatable {
    var accountId: String
    var remoteAccountId: String
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Double?
    var oauthClientId: String?
    var planType: String

    static func legacy(from account: TokenAccount) -> Self {
        Self(
            accountId: account.accountId,
            remoteAccountId: account.remoteAccountId,
            email: account.email,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            expiresAt: account.expiresAt?.timeIntervalSince1970,
            oauthClientId: account.oauthClientID,
            planType: account.planType
        )
    }
}

struct PortableCoreOAuthInteropExportRequest: Codable, Equatable {
    var accounts: [PortableCoreOAuthInteropExportAccountInput]
    var metadataEntries: [PortableCoreOAuthInteropMetadataEntry]
    var availableProxyKeys: [String]
}

struct PortableCoreOAuthInteropExportResult: Codable, Equatable {
    var accountsPayload: String
}

struct PortableCoreOAuthInteropBundleParseRequest: Codable, Equatable {
    var text: String
}

struct PortableCoreOAuthInteropImportedAccountInput: Codable, Equatable {
    var accountId: String
    var remoteAccountID: String
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Double?
    var oauthClientID: String?
    var planType: String

    func tokenAccount() -> TokenAccount {
        TokenAccount(
            email: self.email,
            accountId: self.accountId,
            openAIAccountId: self.remoteAccountID,
            accessToken: self.accessToken,
            refreshToken: self.refreshToken,
            idToken: self.idToken,
            expiresAt: self.expiresAt.map(Date.init(timeIntervalSince1970:)),
            oauthClientID: self.oauthClientID,
            planType: self.planType
        )
    }
}

struct PortableCoreOAuthInteropBundleParseResult: Codable, Equatable {
    var accounts: [PortableCoreOAuthInteropImportedAccountInput]
    var activeAccountID: String?
    var rowCount: Int
    var metadataEntries: [PortableCoreOAuthInteropMetadataEntry]
    var proxiesJSON: String?
}

struct PortableCoreOAuthLegacyCSVParseRequest: Codable, Equatable {
    var text: String
}

struct PortableCoreOAuthLegacyCSVParseResult: Codable, Equatable {
    var accounts: [PortableCoreOAuthInteropImportedAccountInput]
    var activeAccountID: String?
    var rowCount: Int
}

struct PortableCoreLegacyMigrationProviderAccountInput: Codable, Equatable {
    var id: String
    var openAIAccountId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case openAIAccountId = "openaiAccountId"
    }
}

struct PortableCoreLegacyMigrationProviderInput: Codable, Equatable {
    var id: String
    var kind: String
    var baseURL: String?
    var activeAccountId: String?
    var accounts: [PortableCoreLegacyMigrationProviderAccountInput]

    static func legacy(from provider: CodexBarProvider) -> Self {
        Self(
            id: provider.id,
            kind: provider.kind.rawValue,
            baseURL: provider.baseURL,
            activeAccountId: provider.activeAccountId,
            accounts: provider.accounts.map {
                .init(id: $0.id, openAIAccountId: $0.openAIAccountId)
            }
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case baseURL = "baseUrl"
        case activeAccountId
        case accounts
    }
}

struct PortableCoreLegacyMigrationActiveSelectionRequest: Codable, Equatable {
    var openAIBaseURL: String?
    var hasOpenAIAPIKey: Bool
    var authSnapshotLocalAccountId: String?
    var authSnapshotRemoteAccountId: String?
    var providers: [PortableCoreLegacyMigrationProviderInput]

    enum CodingKeys: String, CodingKey {
        case openAIBaseURL = "openaiBaseUrl"
        case hasOpenAIAPIKey = "hasOpenaiApiKey"
        case authSnapshotLocalAccountId
        case authSnapshotRemoteAccountId
        case providers
    }
}

struct PortableCoreLegacyMigrationActiveSelectionResult: Codable, Equatable {
    var providerId: String?
    var accountId: String?

    func activeSelection() -> CodexBarActiveSelection {
        CodexBarActiveSelection(providerId: self.providerId, accountId: self.accountId)
    }

    static func failClosed(
        request: PortableCoreLegacyMigrationActiveSelectionRequest
    ) -> Self {
        if let baseURL = request.openAIBaseURL,
           let provider = request.providers.first(where: { $0.baseURL == baseURL }) {
            return Self(
                providerId: provider.id,
                accountId: provider.activeAccountId ?? provider.accounts.first?.id
            )
        }

        if let provider = request.providers.first(where: { $0.kind == CodexBarProviderKind.openAIOAuth.rawValue }),
           request.authSnapshotLocalAccountId != nil || request.authSnapshotRemoteAccountId != nil {
            let selectedAccountID =
                provider.accounts.first(where: { $0.id == request.authSnapshotLocalAccountId })?.id
                ?? {
                    guard let remoteAccountId = request.authSnapshotRemoteAccountId else { return nil }
                    let matches = provider.accounts.filter { ($0.openAIAccountId ?? $0.id) == remoteAccountId }
                    return matches.count == 1 ? matches.first?.id : nil
                }()
                ?? provider.activeAccountId
                ?? provider.accounts.first?.id
            return Self(providerId: provider.id, accountId: selectedAccountID)
        }

        if request.hasOpenAIAPIKey,
           let provider = request.providers.first(where: { $0.kind == CodexBarProviderKind.openAICompatible.rawValue }) {
            return Self(
                providerId: provider.id,
                accountId: provider.activeAccountId ?? provider.accounts.first?.id
            )
        }

        let fallbackProvider = request.providers.first
        return Self(
            providerId: fallbackProvider?.id,
            accountId: fallbackProvider?.activeAccountId ?? fallbackProvider?.accounts.first?.id
        )
    }
}

struct PortableCoreLegacyImportedProviderPlanRequest: Codable, Equatable {
    var baseURL: String?
    var apiKey: String
    var existingBaseURLs: [String]

    enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case apiKey
        case existingBaseURLs = "existingBaseUrls"
    }
}

struct PortableCoreLegacyImportedProviderPlanResult: Codable, Equatable {
    var shouldCreate: Bool
    var providerId: String?
    var label: String?
    var normalizedBaseURL: String?
    var accountLabel: String?

    enum CodingKeys: String, CodingKey {
        case shouldCreate
        case providerId
        case label
        case normalizedBaseURL = "normalizedBaseUrl"
        case accountLabel
    }

    static func failClosed(
        request: PortableCoreLegacyImportedProviderPlanRequest
    ) -> Self {
        let normalizedBaseURL = request.baseURL ?? "https://api.openai.com/v1"
        if request.existingBaseURLs.contains(normalizedBaseURL) {
            return Self(
                shouldCreate: false,
                providerId: nil,
                label: nil,
                normalizedBaseURL: nil,
                accountLabel: nil
            )
        }

        let label = URL(string: normalizedBaseURL)?.host ?? "Imported"
        let slug = label.lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let providerId = slug.isEmpty ? "imported" : (slug == "openrouter" ? "openrouter-compat" : slug)

        return Self(
            shouldCreate: true,
            providerId: providerId,
            label: label,
            normalizedBaseURL: normalizedBaseURL,
            accountLabel: "Imported"
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

    static func failClosed(
        configuredOpenAIUsageMode: String,
        existingOpenrouterLease: PortableCoreGatewayLeaseSnapshotInput?
    ) -> Self {
        Self(
            effectiveOpenAIUsageMode: configuredOpenAIUsageMode,
            shouldRunOpenAIGateway: false,
            shouldRunOpenrouterGateway: false,
            nextOpenrouterLease: nil,
            openrouterLeaseChanged: existingOpenrouterLease != nil,
            openrouterLeaseShouldPoll: false,
            rustOwner: "swift.failClosedGatewayLifecyclePlan"
        )
    }
}

struct PortableCoreAggregateGatewayLeaseTransitionPlanRequest: Codable, Equatable {
    var previousOpenAIUsageMode: String
    var nextOpenAIUsageMode: String
    var currentLeasedProcessIDs: [Int]
    var runningCodexProcessIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case previousOpenAIUsageMode = "previousOpenaiUsageMode"
        case nextOpenAIUsageMode = "nextOpenaiUsageMode"
        case currentLeasedProcessIDs = "currentLeasedProcessIds"
        case runningCodexProcessIDs = "runningCodexProcessIds"
    }
}

struct PortableCoreAggregateGatewayLeaseTransitionPlanResult: Codable, Equatable {
    var nextLeasedProcessIDs: [Int]
    var leaseChanged: Bool
    var shouldPoll: Bool
    var rustOwner: String

    enum CodingKeys: String, CodingKey {
        case nextLeasedProcessIDs = "nextLeasedProcessIds"
        case leaseChanged
        case shouldPoll
        case rustOwner
    }

    static func failClosed(
        previousOpenAIUsageMode: String,
        nextOpenAIUsageMode: String,
        currentLeasedProcessIDs: [Int],
        runningCodexProcessIDs: [Int]
    ) -> Self {
        let current = Array(Set(currentLeasedProcessIDs)).sorted()
        let running = Array(Set(runningCodexProcessIDs)).sorted()
        let next: [Int]
        if previousOpenAIUsageMode == CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue,
           nextOpenAIUsageMode != CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue {
            next = running
        } else if nextOpenAIUsageMode == CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue {
            next = []
        } else {
            next = current
        }

        return Self(
            nextLeasedProcessIDs: next,
            leaseChanged: next != current,
            shouldPoll: nextOpenAIUsageMode != CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue
                && next.isEmpty == false,
            rustOwner: "swift.failClosedAggregateGatewayLeaseTransition"
        )
    }
}

struct PortableCoreAggregateGatewayLeaseRefreshPlanRequest: Codable, Equatable {
    var currentOpenAIUsageMode: String
    var currentLeasedProcessIDs: [Int]
    var runningCodexProcessIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case currentOpenAIUsageMode = "currentOpenaiUsageMode"
        case currentLeasedProcessIDs = "currentLeasedProcessIds"
        case runningCodexProcessIDs = "runningCodexProcessIds"
    }
}

struct PortableCoreAggregateGatewayLeaseRefreshPlanResult: Codable, Equatable {
    var nextLeasedProcessIDs: [Int]
    var leaseChanged: Bool
    var shouldPoll: Bool
    var rustOwner: String

    enum CodingKeys: String, CodingKey {
        case nextLeasedProcessIDs = "nextLeasedProcessIds"
        case leaseChanged
        case shouldPoll
        case rustOwner
    }

    static func failClosed(
        currentOpenAIUsageMode: String,
        currentLeasedProcessIDs: [Int],
        runningCodexProcessIDs: [Int]
    ) -> Self {
        let current = Array(Set(currentLeasedProcessIDs)).sorted()
        let running = Set(runningCodexProcessIDs)
        let next: [Int]
        if currentOpenAIUsageMode == CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue {
            next = []
        } else {
            next = current.filter { running.contains($0) }
        }

        return Self(
            nextLeasedProcessIDs: next,
            leaseChanged: next != current,
            shouldPoll: currentOpenAIUsageMode != CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue
                && next.isEmpty == false,
            rustOwner: "swift.failClosedAggregateGatewayLeaseRefresh"
        )
    }
}

struct PortableCoreGatewayPostCompletionBindingDecisionRequest: Codable, Equatable {
    var allowsBinding: Bool
    var usedStickyContextRecovery: Bool
    var statusCode: Int
}

struct PortableCoreGatewayPostCompletionBindingDecisionResult: Codable, Equatable {
    var shouldBindSticky: Bool
    var rustOwner: String

    static func failClosed(
        allowsBinding: Bool,
        usedStickyContextRecovery: Bool,
        statusCode: Int
    ) -> Self {
        Self(
            shouldBindSticky: allowsBinding && (usedStickyContextRecovery == false || statusCode < 400),
            rustOwner: "swift.failClosedGatewayPostCompletionBinding"
        )
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

    static func failClosed(
        callbackInput: String?,
        code: String?,
        returnedState: String?
    ) -> Self {
        let parsed = Self.manualInterpretation(
            callbackInput: callbackInput,
            code: code,
            returnedState: returnedState
        )
        return Self(
            code: parsed.code,
            returnedState: parsed.returnedState,
            stateMismatch: false
        )
    }

    private static func manualInterpretation(
        callbackInput: String?,
        code: String?,
        returnedState: String?
    ) -> (code: String?, returnedState: String?) {
        if let callbackInput {
            let trimmed = callbackInput.trimmingCharacters(in: .whitespacesAndNewlines)

            if let url = URL(string: trimmed),
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let parsedCode = components.queryItems?.first(where: { $0.name == "code" })?.value
                let parsedState = components.queryItems?.first(where: { $0.name == "state" })?.value
                if parsedCode != nil || parsedState != nil {
                    return (parsedCode, parsedState)
                }
            }

            if let regex = try? NSRegularExpression(pattern: #"[?&]code=([^&]+)"#),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let codeRange = Range(match.range(at: 1), in: trimmed) {
                let stateRegex = try? NSRegularExpression(pattern: #"[?&]state=([^&]+)"#)
                var parsedState: String?
                if let stateRegex,
                   let stateMatch = stateRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                   let stateRange = Range(stateMatch.range(at: 1), in: trimmed) {
                    parsedState = String(trimmed[stateRange]).removingPercentEncoding
                }
                return (String(trimmed[codeRange]).removingPercentEncoding, parsedState)
            }

            return (trimmed, nil)
        }

        return (
            code?.trimmingCharacters(in: .whitespacesAndNewlines),
            returnedState
        )
    }
}

struct PortableCoreOAuthTokenResponseParseRequest: Codable, Equatable {
    var bodyText: String
    var fallbackRefreshToken: String?
    var fallbackIDToken: String?
    var fallbackClientID: String?
}

struct PortableCoreOAuthTokenResponseParseResult: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var oauthClientID: String?

    func oauthTokens(tokenLastRefreshAt: Date?) -> OAuthTokens {
        OAuthTokens(
            accessToken: self.accessToken,
            refreshToken: self.refreshToken,
            idToken: self.idToken,
            oauthClientID: self.oauthClientID,
            tokenLastRefreshAt: tokenLastRefreshAt
        )
    }
}

struct PortableCoreOAuthAccountBuildRequest: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var oauthClientID: String?
    var tokenLastRefreshAt: Double?
}

struct PortableCoreRefreshOAuthAccountFromTokensRequest: Codable, Equatable {
    var currentAccount: PortableCoreCanonicalAccountSnapshot
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var oauthClientID: String?
    var tokenLastRefreshAt: Double?
}

struct PortableCoreOAuthTokenMetadataRequest: Codable, Equatable {
    var accessToken: String
    var idToken: String?
}

struct PortableCoreOAuthTokenMetadataResult: Codable, Equatable {
    var profileEmail: String?
    var chatGPTUserID: String?
    var oauthClientID: String?
    var organizationID: String?

    static func failClosed() -> Self {
        Self(
            profileEmail: nil,
            chatGPTUserID: nil,
            oauthClientID: nil,
            organizationID: nil
        )
    }
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
