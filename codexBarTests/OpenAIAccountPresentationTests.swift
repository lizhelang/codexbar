import XCTest

final class OpenAIAccountPresentationTests: XCTestCase {
    private var originalLanguageOverride: Bool?

    override func setUp() {
        super.setUp()
        self.originalLanguageOverride = L.languageOverride
        L.languageOverride = false
    }

    override func tearDown() {
        L.languageOverride = self.originalLanguageOverride
        super.tearDown()
    }

    func testRowStateShowsUseActionWhenAccountIsNotNextUseTarget() {
        let account = self.makeAccount(accountId: "acct_idle", isActive: false)

        let state = OpenAIAccountPresentation.rowState(
            for: account,
            summary: OpenAIRunningThreadAttribution.Summary.empty,
            accountUsageMode: .switchAccount
        )

        XCTAssertTrue(state.showsUseAction)
        XCTAssertEqual(
            OpenAIAccountPresentation.manualActivationButtonTitle(defaultBehavior: .updateConfigOnly),
            "Set Default"
        )
        XCTAssertNil(state.runningThreadBadgeTitle)
    }

    func testRowStateShowsSelectedNextUseStateWithoutUseAction() {
        let account = self.makeAccount(accountId: "acct_next", isActive: true)

        let state = OpenAIAccountPresentation.rowState(
            for: account,
            summary: OpenAIRunningThreadAttribution.Summary.empty,
            accountUsageMode: .switchAccount
        )

        XCTAssertTrue(state.isNextUseTarget)
        XCTAssertFalse(state.showsUseAction)
    }

    func testRowStateShowsRunningThreadBadgeWhenThreadsAreAttributed() {
        let account = self.makeAccount(accountId: "acct_busy", isActive: false)
        let summary = OpenAIRunningThreadAttribution.Summary(
            availability: .available,
            runningThreadCounts: ["acct_busy": 2],
            unknownThreadCount: 0
        )

        let state = OpenAIAccountPresentation.rowState(
            for: account,
            summary: summary,
            accountUsageMode: .switchAccount
        )

        XCTAssertEqual(state.runningThreadCount, 2)
        XCTAssertEqual(state.runningThreadBadgeTitle, "Running 2")
    }

    func testNextUseAndRunningThreadsCanCoexistOnSameAccount() {
        let account = self.makeAccount(accountId: "acct_dual", isActive: true)
        let summary = OpenAIRunningThreadAttribution.Summary(
            availability: .available,
            runningThreadCounts: ["acct_dual": 2],
            unknownThreadCount: 0
        )

        let state = OpenAIAccountPresentation.rowState(
            for: account,
            summary: summary,
            accountUsageMode: .switchAccount
        )

        XCTAssertTrue(state.isNextUseTarget)
        XCTAssertEqual(state.runningThreadCount, 2)
        XCTAssertFalse(state.showsUseAction)
        XCTAssertEqual(state.runningThreadBadgeTitle, "Running 2")
    }

    func testRowStateShowsCompactChineseRunningThreadBadge() {
        L.languageOverride = true
        let account = self.makeAccount(accountId: "acct_busy", isActive: false)
        let summary = OpenAIRunningThreadAttribution.Summary(
            availability: .available,
            runningThreadCounts: ["acct_busy": 2],
            unknownThreadCount: 0
        )

        let state = OpenAIAccountPresentation.rowState(
            for: account,
            summary: summary,
            accountUsageMode: .switchAccount
        )

        XCTAssertEqual(state.runningThreadBadgeTitle, "运行 2")
    }

    func testUnavailableSummaryHidesBadgeAndShowsUnavailableText() {
        let account = self.makeAccount(accountId: "acct_busy", isActive: false)

        let state = OpenAIAccountPresentation.rowState(
            for: account,
            summary: .unavailable,
            accountUsageMode: .switchAccount
        )
        let summaryText = OpenAIAccountPresentation.runningThreadSummaryText(summary: .unavailable)

        XCTAssertEqual(state.runningThreadCount, 0)
        XCTAssertNil(state.runningThreadBadgeTitle)
        XCTAssertEqual(summaryText, "Running status unavailable")
    }

    func testUnavailableAttributionShowsRuntimeLogInitializationHint() {
        let logsDatabaseName = CodexPaths.logsSQLiteURL.lastPathComponent
        let attribution = OpenAIRunningThreadAttribution(
            threads: [],
            summary: .unavailable,
            recentActivityWindow: 5,
            diagnosticMessage: "runtime database missing table: \(logsDatabaseName).logs",
            unavailableReason: .missingTable(database: logsDatabaseName, table: "logs")
        )

        let summaryText = OpenAIAccountPresentation.runningThreadSummaryText(
            attribution: attribution
        )

        XCTAssertEqual(
            summaryText,
            "Running status unavailable (runtime logs not initialized)"
        )
    }

    func testSummaryTextIncludesUnattributedRunningThreads() {
        let summary = OpenAIRunningThreadAttribution.Summary(
            availability: .available,
            runningThreadCounts: ["acct_busy": 2],
            unknownThreadCount: 1
        )

        let text = OpenAIAccountPresentation.runningThreadSummaryText(summary: summary)

        XCTAssertEqual(text, "Running · 3 threads / 1 account · 1 unattributed thread")
    }

    func testManualActivationContextActionsExposeTwoOverridesAndMarkUpdateConfigDefault() {
        let actions = OpenAIAccountPresentation.manualActivationContextActions(
            defaultBehavior: .updateConfigOnly
        )

        XCTAssertEqual(OpenAIAccountPresentation.primaryManualActivationTrigger, .primaryTap)
        XCTAssertEqual(actions.map(\.behavior), [.updateConfigOnly, .launchNewInstance])
        XCTAssertEqual(
            actions.map(\.trigger),
            [.contextOverride(.updateConfigOnly), .contextOverride(.launchNewInstance)]
        )
        XCTAssertEqual(
            actions.map(\.title),
            ["Default Target Only (This Time)", "Launch New Instance (This Time)"]
        )
        XCTAssertEqual(actions.filter(\.isDefault).map(\.behavior), [.updateConfigOnly])
    }

    func testManualActivationContextActionsMarkLaunchDefault() {
        let actions = OpenAIAccountPresentation.manualActivationContextActions(
            defaultBehavior: .launchNewInstance
        )

        XCTAssertEqual(actions.filter(\.isDefault).map(\.behavior), [.launchNewInstance])
    }

    func testAggregateModeHidesUseActionEvenWhenAccountIsStoredAsActive() {
        let account = self.makeAccount(accountId: "acct_pool", isActive: true)

        let state = OpenAIAccountPresentation.rowState(
            for: account,
            summary: .empty,
            accountUsageMode: .aggregateGateway
        )

        XCTAssertFalse(state.isNextUseTarget)
        XCTAssertFalse(state.showsUseAction)
    }

    func testAggregateSummaryTitleUsesQuotaInsteadOfAggregateWord() {
        let account = self.makeAccount(
            accountId: "acct_pool",
            isActive: false,
            primaryUsedPercent: 20,
            secondaryUsedPercent: 60
        )

        let title = OpenAIAccountPresentation.aggregateSummaryTitle(
            providerLabel: "OpenAI",
            routedAccount: account,
            usageDisplayMode: .remaining
        )

        XCTAssertEqual(title, "OpenAI · ~5h 80% · 7d 40%")
    }

    func testAggregateSummaryTitleFallsBackToProviderLabelWhenRouteIsUnknown() {
        let title = OpenAIAccountPresentation.aggregateSummaryTitle(
            providerLabel: "OpenAI",
            routedAccount: nil,
            usageDisplayMode: .remaining
        )

        XCTAssertEqual(title, "OpenAI")
    }

    func testManualSwitchBannerExplainsFutureTargetOnlyAndOffersLaunchAction() {
        let result = OpenAIManualSwitchResult(
            action: .updateConfigOnly,
            targetAccountID: "acct-alpha",
            targetMode: .switchAccount,
            launchedNewInstance: false
        )
        let banner = OpenAIAccountPresentation.manualSwitchBanner(
            result: result,
            targetAccount: self.makeAccount(
                accountId: "acct-alpha",
                email: "alpha@example.com",
                isActive: false
            )
        )

        XCTAssertEqual(banner.title, "Default target updated")
        XCTAssertEqual(
            banner.message,
            "New requests now default to alpha@example.com; running threads are not guaranteed to switch. Launch a new instance if you need it to take effect immediately."
        )
        XCTAssertEqual(banner.actionTitle, "Launch Instance")
        XCTAssertEqual(banner.tone, OpenAIStatusBannerPresentation.Tone.info)
    }

    func testManualSwitchBannerForLaunchDoesNotOfferSecondAction() {
        let result = OpenAIManualSwitchResult(
            action: .launchNewInstance,
            targetAccountID: "acct-alpha",
            targetMode: .switchAccount,
            launchedNewInstance: true
        )
        let banner = OpenAIAccountPresentation.manualSwitchBanner(
            result: result,
            targetAccount: self.makeAccount(
                accountId: "acct-alpha",
                email: "alpha@example.com",
                isActive: false
            )
        )

        XCTAssertEqual(banner.title, "Default target updated and new instance launched")
        XCTAssertEqual(
            banner.message,
            "The new Codex instance will use alpha@example.com; existing running threads are not taken over."
        )
        XCTAssertNil(banner.actionTitle)
    }

    func testRuntimeRouteBannerWarnsWhenSwitchModeStillHasAggregateRuntime() {
        let snapshot = OpenAIRuntimeRouteSnapshot(
            configuredMode: .switchAccount,
            effectiveMode: .aggregateGateway,
            aggregateRuntimeActive: true,
            latestRoutedAccountID: "acct-route",
            latestRoutedAccountIsSummary: true,
            stickyAffectsFutureRouting: false,
            leaseActive: true,
            staleStickyEligible: true,
            staleStickyThreadID: "thread-stale",
            latestRouteAt: Date()
        )
        let banner = OpenAIAccountPresentation.runtimeRouteBanner(
            snapshot: snapshot,
            latestRoutedAccount: self.makeAccount(
                accountId: "acct-route",
                email: "route@example.com",
                isActive: false
            ),
            switchTargetAccount: self.makeAccount(
                accountId: "acct-target",
                email: "target@example.com",
                isActive: false
            )
        )

        XCTAssertEqual(
            banner,
            OpenAIStatusBannerPresentation(
                title: "New traffic is back on switch mode while old aggregate threads keep running",
                message: "The default target is target@example.com, but the latest route summary still points at route@example.com. That usually means an older aggregate lease or sticky binding has not naturally drained yet, not that switching failed. Clearing it only affects future routing / new threads and does not take over running threads.",
                actionTitle: "Clear Stale Sticky",
                tone: .warning
            )
        )
    }

    func testRuntimeRouteBannerExplainsAggregateSummaryWithoutLiveTakeoverLanguage() {
        let snapshot = OpenAIRuntimeRouteSnapshot(
            configuredMode: .aggregateGateway,
            effectiveMode: .aggregateGateway,
            aggregateRuntimeActive: true,
            latestRoutedAccountID: "acct-route",
            latestRoutedAccountIsSummary: true,
            stickyAffectsFutureRouting: true,
            leaseActive: false,
            staleStickyEligible: false,
            staleStickyThreadID: nil,
            latestRouteAt: Date()
        )
        let banner = OpenAIAccountPresentation.runtimeRouteBanner(
            snapshot: snapshot,
            latestRoutedAccount: self.makeAccount(
                accountId: "acct-route",
                email: "route@example.com",
                isActive: false
            ),
            switchTargetAccount: nil
        )

        XCTAssertEqual(
            banner,
            OpenAIStatusBannerPresentation(
                title: "Aggregate runtime is still affecting future routing",
                message: "The latest route summary still points at route@example.com. The same thread may keep following an older sticky binding; this is only a summary, not the truth for every live thread.",
                actionTitle: nil,
                tone: .info
            )
        )
    }

    func testPlanBadgeTitleShowsOrganizationNameForHoveredTeamAccount() {
        let account = self.makeAccount(
            accountId: "acct_team_hover",
            isActive: false,
            planType: "team",
            organizationName: "Acme Team"
        )

        XCTAssertEqual(
            OpenAIAccountPresentation.planBadgeTitle(for: account, isHovered: true),
            "Acme Team"
        )
    }

    func testPlanBadgeTitleShowsTeamForNonHoveredTeamAccount() {
        let account = self.makeAccount(
            accountId: "acct_team_idle",
            isActive: false,
            planType: "team",
            organizationName: "Acme Team"
        )

        XCTAssertEqual(
            OpenAIAccountPresentation.planBadgeTitle(for: account, isHovered: false),
            "TEAM"
        )
    }

    func testPlanBadgeTitleTrimsOrganizationNameForHoveredTeamAccount() {
        let account = self.makeAccount(
            accountId: "acct_team_trimmed",
            isActive: false,
            planType: "team",
            organizationName: "  Acme Team  "
        )

        XCTAssertEqual(
            OpenAIAccountPresentation.planBadgeTitle(for: account, isHovered: true),
            "Acme Team"
        )
    }

    func testPlanBadgeTitleFallsBackToTeamForHoveredTeamAccountWithoutOrganizationName() {
        let nilNameAccount = self.makeAccount(
            accountId: "acct_team_nil",
            isActive: false,
            planType: "team",
            organizationName: nil
        )
        let blankNameAccount = self.makeAccount(
            accountId: "acct_team_blank",
            isActive: false,
            planType: "team",
            organizationName: "   "
        )

        XCTAssertEqual(
            OpenAIAccountPresentation.planBadgeTitle(for: nilNameAccount, isHovered: true),
            "TEAM"
        )
        XCTAssertEqual(
            OpenAIAccountPresentation.planBadgeTitle(for: blankNameAccount, isHovered: true),
            "TEAM"
        )
    }

    func testPlanBadgeTitleKeepsOriginalPlanLabelForHoveredNonTeamAccount() {
        let account = self.makeAccount(
            accountId: "acct_plus_hover",
            isActive: false,
            planType: "plus",
            organizationName: "Acme Team"
        )

        XCTAssertEqual(
            OpenAIAccountPresentation.planBadgeTitle(for: account, isHovered: true),
            "PLUS"
        )
    }

    func testExpandedTeamBadgeHoverLayoutActivatesOnlyForHoveredTeamWithOrganizationName() {
        let account = self.makeAccount(
            accountId: "acct_team_layout",
            isActive: false,
            planType: "team",
            organizationName: "Acme Team"
        )

        XCTAssertTrue(
            OpenAIAccountPresentation.usesExpandedTeamBadgeHoverLayout(
                for: account,
                isHovered: true
            )
        )
        XCTAssertFalse(
            OpenAIAccountPresentation.usesExpandedTeamBadgeHoverLayout(
                for: account,
                isHovered: false
            )
        )
    }

    func testExpandedTeamBadgeHoverLayoutStaysDisabledWithoutOrganizationName() {
        let account = self.makeAccount(
            accountId: "acct_team_no_name",
            isActive: false,
            planType: "team",
            organizationName: "   "
        )

        XCTAssertFalse(
            OpenAIAccountPresentation.usesExpandedTeamBadgeHoverLayout(
                for: account,
                isHovered: true
            )
        )
    }

    func testExpandedTeamBadgeHoverLayoutStaysDisabledForNonTeamAccount() {
        let account = self.makeAccount(
            accountId: "acct_plus_layout",
            isActive: false,
            planType: "plus",
            organizationName: "Acme Team"
        )

        XCTAssertFalse(
            OpenAIAccountPresentation.usesExpandedTeamBadgeHoverLayout(
                for: account,
                isHovered: true
            )
        )
    }

    func testCopyableAccountGroupEmailReturnsOriginalEmail() {
        XCTAssertEqual(
            OpenAIAccountPresentation.copyableAccountGroupEmail("alpha@example.com"),
            "alpha@example.com"
        )
    }

    func testCopyableAccountGroupEmailTrimsWhitespace() {
        XCTAssertEqual(
            OpenAIAccountPresentation.copyableAccountGroupEmail("  alpha@example.com  "),
            "alpha@example.com"
        )
    }

    func testCopyableAccountGroupEmailRejectsBlankValue() {
        XCTAssertNil(
            OpenAIAccountPresentation.copyableAccountGroupEmail("   ")
        )
    }

    func testCopyActionWritesNormalizedEmailToPasteboard() {
        let pasteboard = PasteboardSpy()

        let copiedEmail = OpenAIAccountGroupEmailCopyAction.perform(
            email: "  alpha@example.com  ",
            pasteboard: pasteboard
        )

        XCTAssertEqual(copiedEmail, "alpha@example.com")
        XCTAssertEqual(pasteboard.clearContentsCallCount, 1)
        XCTAssertEqual(pasteboard.lastString, "alpha@example.com")
        XCTAssertEqual(pasteboard.lastType, .string)
    }

    func testCopyActionSkipsBlankEmail() {
        let pasteboard = PasteboardSpy()

        let copiedEmail = OpenAIAccountGroupEmailCopyAction.perform(
            email: "   ",
            pasteboard: pasteboard
        )

        XCTAssertNil(copiedEmail)
        XCTAssertEqual(pasteboard.clearContentsCallCount, 0)
        XCTAssertNil(pasteboard.lastString)
        XCTAssertNil(pasteboard.lastType)
    }

    func testAccountGroupCopyConfirmationTextShowsCopiedWhenEmailsMatch() {
        XCTAssertEqual(
            OpenAIAccountPresentation.accountGroupCopyConfirmationText(
                groupEmail: "  alpha@example.com ",
                copiedEmail: "alpha@example.com"
            ),
            "Copied"
        )
    }

    func testAccountGroupCopyConfirmationTextUsesChineseCopy() {
        L.languageOverride = true

        XCTAssertEqual(
            OpenAIAccountPresentation.accountGroupCopyConfirmationText(
                groupEmail: "alpha@example.com",
                copiedEmail: "alpha@example.com"
            ),
            "已复制"
        )
    }

    func testAccountGroupCopyConfirmationTextHidesWhenEmailsDoNotMatch() {
        XCTAssertNil(
            OpenAIAccountPresentation.accountGroupCopyConfirmationText(
                groupEmail: "alpha@example.com",
                copiedEmail: "beta@example.com"
            )
        )
    }

    private func makeAccount(
        accountId: String,
        email: String? = nil,
        isActive: Bool,
        planType: String = "free",
        organizationName: String? = nil,
        primaryUsedPercent: Double = 0,
        secondaryUsedPercent: Double = 0
    ) -> TokenAccount {
        TokenAccount(
            email: email ?? "\(accountId)@example.com",
            accountId: accountId,
            accessToken: "access-\(accountId)",
            refreshToken: "refresh-\(accountId)",
            idToken: "id-\(accountId)",
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            isActive: isActive,
            organizationName: organizationName
        )
    }
}

private final class PasteboardSpy: StringPasteboardWriting {
    private(set) var clearContentsCallCount = 0
    private(set) var lastString: String?
    private(set) var lastType: NSPasteboard.PasteboardType?

    func clearContents() -> Int {
        self.clearContentsCallCount += 1
        return self.clearContentsCallCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        self.lastString = string
        self.lastType = dataType
        return true
    }
}
