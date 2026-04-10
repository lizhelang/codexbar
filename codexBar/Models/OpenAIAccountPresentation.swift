import Foundation

struct OpenAIAccountRowState: Equatable {
    let isNextUseTarget: Bool
    let runningThreadCount: Int
    let accountUsageMode: CodexBarOpenAIAccountUsageMode

    var showsUseAction: Bool {
        self.accountUsageMode == .switchAccount && self.isNextUseTarget == false
    }

    var useActionTitle: String {
        L.useBtn
    }

    var runningThreadBadgeTitle: String? {
        guard self.runningThreadCount > 0 else { return nil }
        return L.runningThreads(self.runningThreadCount)
    }
}

struct OpenAIAccountContextActionState: Equatable {
    let behavior: CodexBarOpenAIManualActivationBehavior
    let trigger: OpenAIManualActivationTrigger
    let title: String
    let isDefault: Bool
}

enum OpenAIAccountPresentation {
    static let primaryManualActivationTrigger: OpenAIManualActivationTrigger = .primaryTap

    static func usesExpandedTeamBadgeHoverLayout(
        for account: TokenAccount,
        isHovered: Bool
    ) -> Bool {
        isHovered
            && self.normalizedPlanType(for: account) == "team"
            && self.trimmedOrganizationName(for: account) != nil
    }

    static func planBadgeTitle(for account: TokenAccount, isHovered: Bool) -> String {
        let normalizedPlanType = self.normalizedPlanType(for: account)

        guard normalizedPlanType == "team" else {
            return account.planType.uppercased()
        }

        if isHovered,
           let organizationName = self.trimmedOrganizationName(for: account) {
            return organizationName
        }

        return "TEAM"
    }

    static func rowState(
        for account: TokenAccount,
        attribution: OpenAILiveSessionAttribution,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        now: Date = Date()
    ) -> OpenAIAccountRowState {
        self.rowState(
            for: account,
            summary: attribution.liveSummary(now: now),
            accountUsageMode: accountUsageMode
        )
    }

    static func rowState(
        for account: TokenAccount,
        summary: OpenAILiveSessionAttribution.LiveSummary,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    ) -> OpenAIAccountRowState {
        self.rowState(
            for: account,
            runningThreadCount: summary.inUseSessionCount(for: account.accountId),
            accountUsageMode: accountUsageMode
        )
    }

    static func rowState(
        for account: TokenAccount,
        summary: OpenAIRunningThreadAttribution.Summary,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    ) -> OpenAIAccountRowState {
        self.rowState(
            for: account,
            runningThreadCount: summary.runningThreadCount(for: account.accountId),
            accountUsageMode: accountUsageMode
        )
    }

    static func runningThreadSummaryText(
        attribution: OpenAIRunningThreadAttribution
    ) -> String {
        if attribution.summary.isUnavailable {
            return self.runningThreadUnavailableText(
                reason: attribution.unavailableReason
            )
        }

        return self.runningThreadSummaryText(summary: attribution.summary)
    }

    static func runningThreadSummaryText(
        summary: OpenAIRunningThreadAttribution.Summary
    ) -> String {
        if summary.isUnavailable {
            return L.runningThreadUnavailable
        }

        if summary.totalRunningThreadCount == 0 {
            return L.runningThreadNone
        }

        let base = L.runningThreadSummary(
            summary.totalRunningThreadCount,
            summary.runningAccountCount
        )
        guard summary.unknownThreadCount > 0 else { return base }
        return "\(base) · \(L.runningThreadUnknown(summary.unknownThreadCount))"
    }

    private static func rowState(
        for account: TokenAccount,
        runningThreadCount: Int,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    ) -> OpenAIAccountRowState {
        OpenAIAccountRowState(
            isNextUseTarget: accountUsageMode == .switchAccount && account.isActive,
            runningThreadCount: runningThreadCount,
            accountUsageMode: accountUsageMode
        )
    }

    private static func runningThreadUnavailableText(
        reason: CodexThreadRuntimeStore.UnavailableReason?
    ) -> String {
        switch reason {
        case let .missingDatabase(name) where self.isRuntimeLogsDatabase(name):
            return L.runningThreadUnavailableRuntimeLogMissing
        case let .missingTable(database, table)
            where self.isRuntimeLogsDatabase(database) && table == "logs":
            return L.runningThreadUnavailableRuntimeLogUninitialized
        default:
            return L.runningThreadUnavailable
        }
    }

    private static func isRuntimeLogsDatabase(_ filename: String) -> Bool {
        filename.hasPrefix("logs_") && filename.hasSuffix(".sqlite")
    }

    static func manualActivationContextActions(
        defaultBehavior: CodexBarOpenAIManualActivationBehavior
    ) -> [OpenAIAccountContextActionState] {
        [
            OpenAIAccountContextActionState(
                behavior: .updateConfigOnly,
                trigger: .contextOverride(.updateConfigOnly),
                title: L.manualActivationUpdateConfigOnlyOneTime,
                isDefault: defaultBehavior == .updateConfigOnly
            ),
            OpenAIAccountContextActionState(
                behavior: .launchNewInstance,
                trigger: .contextOverride(.launchNewInstance),
                title: L.manualActivationLaunchNewInstanceOneTime,
                isDefault: defaultBehavior == .launchNewInstance
            ),
        ]
    }

    static func inUseSummaryText(
        attribution: OpenAILiveSessionAttribution,
        now: Date = Date()
    ) -> String {
        self.inUseSummaryText(summary: attribution.liveSummary(now: now))
    }

    static func inUseSummaryText(
        summary: OpenAILiveSessionAttribution.LiveSummary
    ) -> String {
        if summary.totalInUseSessionCount == 0 {
            return summary.unknownSessionCount > 0
                ? L.inUseUnknownSessions(summary.unknownSessionCount)
                : L.inUseNone
        }

        let base = L.inUseSummary(
            summary.totalInUseSessionCount,
            summary.inUseAccountCount
        )
        guard summary.unknownSessionCount > 0 else { return base }
        return "\(base) · \(L.inUseUnknownSessions(summary.unknownSessionCount))"
    }

    private static func trimmedOrganizationName(
        for account: TokenAccount
    ) -> String? {
        guard let organizationName = account.organizationName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            organizationName.isEmpty == false else {
            return nil
        }
        return organizationName
    }

    private static func normalizedPlanType(for account: TokenAccount) -> String {
        account.planType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
