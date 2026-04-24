import Foundation

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
