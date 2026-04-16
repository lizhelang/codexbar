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

struct OpenAIStatusBannerPresentation: Equatable {
    enum Tone: Equatable {
        case info
        case warning
    }

    let title: String
    let message: String
    let actionTitle: String?
    let tone: Tone
}

enum OpenAIAccountPresentation {
    static let primaryManualActivationTrigger: OpenAIManualActivationTrigger = .primaryTap

    static func copyableAccountGroupEmail(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func accountGroupCopyConfirmationText(
        groupEmail: String,
        copiedEmail: String?
    ) -> String? {
        guard let normalizedGroupEmail = self.copyableAccountGroupEmail(groupEmail),
              let normalizedCopiedEmail = copiedEmail,
              normalizedGroupEmail == normalizedCopiedEmail else {
            return nil
        }

        return L.copied
    }

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

    static func aggregateSummaryTitle(
        providerLabel: String,
        routedAccount: TokenAccount?,
        usageDisplayMode: CodexBarUsageDisplayMode
    ) -> String {
        guard let routedAccount,
              let usageSummary = routedAccount.compactUsageSummary(mode: usageDisplayMode) else {
            return providerLabel
        }

        return "\(providerLabel) · \(L.openAIRouteSummaryCompact(usageSummary))"
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

    static func manualActivationButtonTitle(
        defaultBehavior: CodexBarOpenAIManualActivationBehavior?
    ) -> String {
        switch defaultBehavior {
        case .launchNewInstance:
            return L.manualActivationLaunchInstanceAction
        default:
            return L.manualActivationSetDefaultTargetAction
        }
    }

    static func manualSwitchBanner(
        result: OpenAIManualSwitchResult,
        targetAccount: TokenAccount?
    ) -> OpenAIStatusBannerPresentation {
        let targetLabel = self.accountLabel(for: targetAccount)
        switch result.copyKey {
        case .defaultTargetUpdated:
            return OpenAIStatusBannerPresentation(
                title: L.manualSwitchDefaultTargetUpdatedTitle,
                message: "\(L.manualSwitchDefaultTargetUpdatedDetail(targetLabel)) \(L.manualSwitchImmediateEffectHint)",
                actionTitle: result.immediateEffectRecommendation == .launchNewInstance
                    ? L.manualActivationLaunchInstanceAction
                    : nil,
                tone: .info
            )
        case .launchedNewInstance:
            return OpenAIStatusBannerPresentation(
                title: L.manualSwitchLaunchedInstanceTitle,
                message: L.manualSwitchLaunchedInstanceDetail(targetLabel),
                actionTitle: nil,
                tone: .info
            )
        }
    }

    static func runtimeRouteBanner(
        snapshot: OpenAIRuntimeRouteSnapshot,
        latestRoutedAccount: TokenAccount?,
        switchTargetAccount: TokenAccount?
    ) -> OpenAIStatusBannerPresentation? {
        guard snapshot.aggregateRuntimeActive else { return nil }

        let routedLabel = self.accountLabel(for: latestRoutedAccount)
        let targetLabel = self.accountLabel(for: switchTargetAccount)
        let staleStickyHint = snapshot.staleStickyEligible
            ? " \(L.aggregateRuntimeClearStaleStickyHint)"
            : ""

        if snapshot.configuredMode == .switchAccount {
            return OpenAIStatusBannerPresentation(
                title: L.aggregateRuntimeSwitchBackTitle,
                message: L.aggregateRuntimeSwitchBackDetail(
                    targetAccount: targetLabel,
                    routedAccount: routedLabel
                ) + staleStickyHint,
                actionTitle: snapshot.staleStickyEligible
                    ? L.aggregateRuntimeClearStaleStickyAction
                    : nil,
                tone: .warning
            )
        }

        return OpenAIStatusBannerPresentation(
            title: L.aggregateRuntimeActiveTitle,
            message: L.aggregateRuntimeActiveDetail(routedLabel) + staleStickyHint,
            actionTitle: snapshot.staleStickyEligible
                ? L.aggregateRuntimeClearStaleStickyAction
                : nil,
            tone: .info
        )
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

    private static func accountLabel(for account: TokenAccount?) -> String? {
        guard let account else { return nil }
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.isEmpty == false {
            return email
        }
        return account.accountId
    }
}
