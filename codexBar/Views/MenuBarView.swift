import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum MenuSurface {
    private static func adaptive(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let backgroundTop = adaptive(NSColor(red: 48.0 / 255, green: 52.0 / 255, blue: 54.0 / 255, alpha: 1), NSColor(white: 0.97, alpha: 1))
    static let backgroundBottom = adaptive(NSColor(red: 47.0 / 255, green: 52.0 / 255, blue: 55.0 / 255, alpha: 1), NSColor(white: 0.95, alpha: 1))
    static let raised = adaptive(NSColor(red: 57.0 / 255, green: 62.0 / 255, blue: 65.0 / 255, alpha: 1), NSColor.white)
    static let foreground = Color.primary
    static let line = Color.primary.opacity(0.12)
    static let muted = Color.secondary
    static var accent: Color {
        switch ApplicationPreferencesStore.shared.preferences.accentColor {
        case .teal: return Color(red: 0.25, green: 0.68, blue: 0.70)
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        }
    }
    static func currency(_ dollars: Double) -> String {
        let preferences = ApplicationPreferencesStore.shared.preferences
        let converted = dollars * (preferences.displayCurrencyCode == "USD" ? 1 : preferences.usdExchangeRate)
        guard converted.isFinite, abs(converted) < 1e18 else { return L.zh ? "费用不可用" : "Cost unavailable" }
        return converted.formatted(.currency(code: preferences.displayCurrencyCode))
    }
    static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * ApplicationPreferencesStore.shared.preferences.fontScale, weight: weight, design: design)
    }
}

enum MenuPage: String, CaseIterable, Identifiable {
    case limits, home, tools, models, projects, sessions, devices, trends

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .home: L.zh ? "统计" : "Statistics"
        case .limits: L.zh ? "额度" : "Limits"
        case .tools: L.zh ? "工具" : "Tools"
        case .models: L.zh ? "模型" : "Models"
        case .projects: L.zh ? "项目" : "Projects"
        case .sessions: L.zh ? "会话" : "Sessions"
        case .devices: L.zh ? "设备" : "Devices"
        case .trends: L.zh ? "趋势" : "Trends"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .limits: "gauge"
        case .tools: "square.grid.2x2"
        case .models: "cube"
        case .projects: "folder"
        case .sessions: "text.bubble"
        case .devices: "desktopcomputer"
        case .trends: "chart.xyaxis.line"
        }
    }
}

private struct MonitorIndexedSnapshot: Sendable {
    let models: [MonitorModelUsage]
    let sessions: [MonitorCodexSessionUsage]
    let recentSessions: [MonitorCodexSessionUsage]
}

enum MenuBarErrorSource: Equatable {
    case generic
    case refresh
    case notice
}

struct MenuBarErrorBannerState: Equatable {
    let message: String
    let source: MenuBarErrorSource
}

enum MenuBarRefreshErrorResolver {
    static func nextBanner(
        current: MenuBarErrorBannerState?,
        announceResult: Bool,
        refreshMessage: String?
    ) -> MenuBarErrorBannerState? {
        if let refreshMessage {
            guard announceResult else { return current }
            return MenuBarErrorBannerState(message: refreshMessage, source: .refresh)
        }

        guard current?.source == .refresh else { return current }
        return nil
    }
}

struct MenuBarOpenRefreshGate: Equatable {
    private(set) var didTriggerOpenRefresh = false

    mutating func shouldTriggerRefresh(isRefreshing: Bool) -> Bool {
        guard self.didTriggerOpenRefresh == false else { return false }
        self.didTriggerOpenRefresh = true
        return isRefreshing == false
    }

    mutating func resetForClose() {
        self.didTriggerOpenRefresh = false
    }
}

enum MenuBarRefreshOrigin: Equatable {
    case menuOpen
    case manual

    var refreshesSessionCache: Bool {
        self == .manual
    }
}

/// The panel owns its viewport height; page contents only determine the scroll extent.
/// A native ScrollView lays out one display tree, without a second hidden hosting view.
struct AdaptiveMenuScrollContainer<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            self.content
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: max(1, self.maxHeight), alignment: .top)
    }
}

private struct ViewReferenceReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> ReporterView {
        ReporterView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveIfAttached()
    }

    final class ReporterView: NSView {
        var onResolve: (NSView) -> Void

        init(onResolve: @escaping (NSView) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfAttached()
        }

        override func layout() {
            super.layout()
            resolveIfAttached()
        }

        func resolveIfAttached() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onResolve(self)
            }
        }
    }
}


struct MenuBarView: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var oauth: OAuthManager
    @EnvironmentObject var updateCoordinator: UpdateCoordinator
    @ObservedObject private var toolUsageStore: ToolUsageStore
    @ObservedObject private var preferencesStore: ApplicationPreferencesStore
    @ObservedObject private var deviceSync: DeviceUsageSyncService

    @MainActor
    init(toolUsageStore: ToolUsageStore? = nil, preferencesStore: ApplicationPreferencesStore? = nil,
         deviceSync: DeviceUsageSyncService? = nil, initialPage: MenuPage = .limits) {
        self._toolUsageStore = ObservedObject(wrappedValue: toolUsageStore ?? .shared)
        self._preferencesStore = ObservedObject(wrappedValue: preferencesStore ?? .shared)
        self._deviceSync = ObservedObject(wrappedValue: deviceSync ?? .shared)
        self._selectedPage = AppStorage(wrappedValue: initialPage, "codexbar.menu.page")
    }

    private let costPanelID = "cost-details-hover-panel"
    private let resetCreditsPanelID = "reset-credits-hover-panel"
    private let usageRefreshInterval = OpenAIUsagePollingService.defaultRefreshInterval
    private let visibleOpenAIAccountLimit = 5
    private let openAIAccountsInitialHeight: CGFloat = 260
    private let runningThreadAttributionService = OpenAIRunningThreadAttributionService()
    private let oauthAccountService = CodexBarOAuthAccountService()
    private let openAIAccountCSVService = OpenAIAccountCSVService()
    private let openAIAccountCSVPanelService = OpenAIAccountCSVPanelService()

    @State private var isRefreshing = false
    @State private var errorBanner: MenuBarErrorBannerState?
    @State private var now = Date()
    @State private var runningThreadAttribution = OpenAIRunningThreadAttribution.empty
    @State private var refreshingAccounts: Set<String> = []
    @State private var copiedOpenAIAccountGroupEmail: String?
    @State private var languageToggle = false
    @State private var isCostSummaryHovered = false
    @State private var selectedUsageScope: UsageScope = .all
    @State private var selectedUsagePeriod: UsagePeriod = .today
    @State private var selectedUsageMetric: UsageMetric = .tokens
    @State private var isCostPanelHovered = false
    @State private var isCostPanelPresented = false
    @State private var isResetCreditsHovered = false
    @State private var isResetCreditsPanelHovered = false
    @State private var isResetCreditsPanelPresented = false
    @State private var isResetCreditsPanelPinned = false
    @State private var openRefreshGate = MenuBarOpenRefreshGate()
    @State private var pendingCostHide: DispatchWorkItem?
    @State private var pendingResetCreditsHide: DispatchWorkItem?
    @State private var pendingCopiedOpenAIAccountGroupEmailHide: DispatchWorkItem?
    @State private var costSummaryAnchorView: NSView?
    @State private var resetCreditsAnchorView: NSView?
    @State private var isProvidersExpanded = false
    @State private var isManagementReordering = false
    @AppStorage("codexbar.menu.page") private var selectedPage: MenuPage = .limits
    @StateObject private var projectNavigation = ProjectUsageNavigation()
    @State private var isLocalDeviceExpanded = false
    @State private var recordsSnapshot: RecordsSnapshot?
    @State private var isLoadingRecords = false
    @State private var recordsLoadFailed = false
    @State private var recordsLoadID = UUID()
    @State private var monitorDisplay = MenuMonitorDisplayState()
    @State private var monitorProjectionRefresh = CoalescedBackgroundRefreshController<MenuMonitorPresentation>()
    @State private var monitorProjectionScheduled = false
    @State private var monitorProjectionID = UUID()
    @State private var monitorIndexRefresh = CoalescedBackgroundRefreshController<MonitorIndexedSnapshot?>()
    @State private var monitorIndexUpdatedAt: Date?
    @State private var monitorIndexLoadedDay: Date?
    @State private var monitorModelUsage: [MonitorModelUsage]?
    @State private var monitorSessionUsage: [MonitorCodexSessionUsage]?
    @State private var recentMonitorSessionUsage: [MonitorCodexSessionUsage]?
    @State private var expandedModelIDs: Set<String> = []
    @State private var expandedSessionIDs: Set<String> = []
    @State private var expandedDeviceIDs: Set<String> = []
    @State private var sessionPageIndex = 0
    @State private var monitorModelPeriod: UsagePeriod?
    @State private var isLoadingMonitorModels = false
    @State private var monitorModelsLoadFailed = false
    @State private var monitorModelLoadID = UUID()
    @State private var isResetCreditsExpanded = false
    @State private var trendChartStyle: DashboardTrendChartStyle = .line
    @State private var lastOpenAIManualSwitchResult: OpenAIManualSwitchResult?
    @State private var pendingResetCredit: RateLimitResetCreditItem?
    @State private var isConsumingResetCredit = false
    @State private var isAligningQuota = false
    @State private var alignQuotaFeedback: OpenAIQuotaAlignmentFeedback?
    @State private var alignQuotaFeedbackClearTask: Task<Void, Never>?
    @State private var statusItemAvailableContentHeight: CGFloat?
    @State private var countdownTimerConnection: Cancellable?
    @State private var runningThreadTimerConnection: Cancellable?
    @State private var runningThreadRefreshController = CoalescedBackgroundRefreshController<OpenAIRunningThreadAttribution>()
    @AppStorage(MenuBarPopoverSizing.preferredHeightDefaultsKey) private var preferredMenuHeight = 0.0
    @AppStorage("codexbar.usage.rate-unit") private var usageRateUnitRaw = UsageRateUnit.perSecond.rawValue

    private let countdownTimer = Timer.publish(every: 10, on: .main, in: .common)
    private let runningThreadTimer = Timer.publish(
        every: OpenAIRunningThreadAttributionService.defaultRecentActivityWindow,
        on: .main,
        in: .common
    )
    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()
    private static let relativeChineseFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    private static let relativeEnglishFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var groupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.groupedAccounts(
            from: store.accounts,
            summary: self.runningThreadSummary,
            quotaSortSettings: self.store.config.openAI.quotaSort,
            preferredAccountOrder: self.store.config.openAI.preferredDisplayAccountOrder,
            highlightActiveAccount: self.store.config.openAI.accountUsageMode == .switchAccount
        )
    }

    private var runningThreadSummary: OpenAIRunningThreadAttribution.Summary {
        self.runningThreadAttribution.summary
    }

    private var openAIRuntimeRouteSnapshot: OpenAIRuntimeRouteSnapshot {
        self.store.openAIRuntimeRouteSnapshot(
            runningThreadAttribution: self.runningThreadAttribution,
            now: self.now
        )
    }

    private var switchTargetAccount: TokenAccount? {
        if let selectedAccountID = self.store.config.openAI.switchModeSelection?.accountId,
           let account = self.store.oauthAccount(accountID: selectedAccountID) {
            return account
        }
        return self.store.activeAccount()
    }

    private var latestRoutedAccount: TokenAccount? {
        guard let accountID = self.openAIRuntimeRouteSnapshot.latestRoutedAccountID else {
            return nil
        }
        return self.store.oauthAccount(accountID: accountID)
    }

    private var manualSwitchBanner: OpenAIStatusBannerPresentation? {
        guard let lastOpenAIManualSwitchResult else { return nil }
        return OpenAIAccountPresentation.manualSwitchBanner(
            result: lastOpenAIManualSwitchResult,
            targetAccount: self.store.oauthAccount(accountID: lastOpenAIManualSwitchResult.targetAccountID),
            preferences: self.preferences
        )
    }

    private var runtimeRouteBanner: OpenAIStatusBannerPresentation? {
        OpenAIAccountPresentation.runtimeRouteBanner(
            snapshot: self.openAIRuntimeRouteSnapshot,
            latestRoutedAccount: self.latestRoutedAccount,
            switchTargetAccount: self.switchTargetAccount,
            preferences: self.preferences
        )
    }

    private var resetCreditItems: [RateLimitResetCreditItem] {
        RateLimitResetCreditPresentation.items(from: self.store.accounts, now: self.now, preferences: self.preferences)
    }

    private var resetCreditBanner: OpenAIStatusBannerPresentation? {
        RateLimitResetCreditPresentation.banner(from: self.store.accounts, now: self.now, preferences: self.preferences)
    }

    private var resetCreditTotalAvailableCount: Int {
        // count 优先用接口的 available_count，但接口拿不到明细、或卡没带 expiresAt 时，
        // 以实际可展示的 available 卡数兜底，避免“count>0 但列表空白”被整体隐藏。
        store.accounts.reduce(0) { partial, account in
            let listed = account.availableRateLimitResetCredits(now: self.now).count
            return partial + max(account.rateLimitResetAvailableCount, listed)
        }
    }

    private var requestRouteSummary: (title: String, detail: String, model: String)? {
        guard self.store.config.openAI.remoteConnectionAccountID != nil ||
            self.store.config.openAI.hybridTargetSelection != nil else { return nil }
        do {
            let route = try CodexRouteResolver.resolve(config: self.store.config)
            return (
                "\(L.remoteConnectionAccountTitle): \(route.authAccount.label)",
                "\(L.requestTargetTitle): \(route.targetProvider.label) · \(route.targetAccount.label)",
                route.effectiveModel
            )
        } catch {
            return (
                error.localizedDescription,
                L.requestRouteSetupHint,
                self.store.activeModel
            )
        }
    }

    private var visibleGroupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.visibleGroups(
            from: groupedAccounts,
            maxAccounts: visibleOpenAIAccountLimit
        )
    }

    private var availableCount: Int {
        store.accounts.filter { $0.usageStatus == .ok }.count
    }

    private var openAIAvailabilityBadgeTitle: String? {
        OpenAIAccountPresentation.headerAvailabilityBadgeTitle(
            availableCount: self.availableCount,
            totalCount: self.store.accounts.count
        )
    }

    private var visibleOpenRouterProvider: CodexBarProvider? {
        guard let provider = store.openRouterProvider,
              provider.accounts.isEmpty == false else {
            return nil
        }
        return provider
    }

    var body: some View {
        mainMenuContent
        .frame(width: MenuBarStatusItemIdentity.popoverContentWidth)
        .preferredColorScheme(self.preferredColorScheme)
        .tint(MenuSurface.accent)
        .onAppear { self.applyDisplayPreferences() }
        .onChange(of: self.preferences.defaultUsageRange) { value in
            self.selectedUsagePeriod = UsagePeriod(rawValue: value) ?? .today
        }
        .onChange(of: self.preferences.defaultUsageMetric) { value in
            self.selectedUsageMetric = value == "cost" ? .cost : .tokens
        }
        .onChange(of: self.preferences.accountIdentityDisplay) { _ in
            self.syncResetCreditsPanelAfterItemsChange()
        }
        .onChange(of: self.preferences) { _ in
            if !self.preferences.visiblePages.contains(self.selectedPage.rawValue) { self.selectedPage = .limits }
            if self.selectedUsageScope != .all && !self.dashboardToolScopes.contains(self.selectedUsageScope) { self.selectedUsageScope = .all }
            self.requestStatusItemLayoutRefresh()
        }
        .onChange(of: self.preferences.disabledTools) { _ in self.refreshMonitorPageData() }
        .onChange(of: self.preferences.homeItemLimit) { _ in self.refreshMonitorPageData() }
        .onReceive(countdownTimer) { _ in
            let previousDay = Calendar.current.startOfDay(for: self.now)
            now = Date()
            if Calendar.current.startOfDay(for: self.now) != previousDay {
                self.loadMonitorModels(force: true)
                self.refreshMonitorPageData()
            }
            if isResetCreditsPanelPresented {
                showResetCreditsPanel()
            }
        }
        .onChange(of: self.resetCreditItems.map(\.id)) { _ in
            self.syncResetCreditsPanelAfterItemsChange()
        }
        .onReceive(runningThreadTimer) { _ in
            refreshRunningThreadAttribution()
        }
        .onReceive(store.$localCostSummary) { _ in
            guard isCostPanelPresented else { return }
            showCostPanel()
        }
        .onReceive(store.$localCostRefreshState) { _ in
            guard isCostPanelPresented else { return }
            showCostPanel()
        }
        .onReceive(toolUsageStore.$snapshots) { _ in
            DispatchQueue.main.async { self.refreshMonitorPageData() }
            guard isCostPanelPresented else { return }
            showCostPanel()
        }
        .onChange(of: self.selectedUsageScope) { _ in
            self.sessionPageIndex = 0
            self.projectNavigation.projectPageIndex = 0
            self.projectNavigation.sessionPageIndices = [:]
            self.refreshMonitorPageData()
            guard isCostPanelPresented else { return }
            showCostPanel()
        }
        .onChange(of: self.selectedUsagePeriod) { _ in
            self.sessionPageIndex = 0
            self.projectNavigation.projectPageIndex = 0
            self.projectNavigation.sessionPageIndices = [:]
            self.loadMonitorModels(force: true)
            self.refreshMonitorPageData()
            guard isCostPanelPresented else { return }
            showCostPanel()
        }
        .onChange(of: self.store.localCostSummary.updatedAt) { _ in
            self.loadRecordsIfNeeded(force: true)
            self.loadMonitorModels(force: true)
        }
        .onChange(of: self.selectedUsageMetric) { _ in
            guard isCostPanelPresented else { return }
            showCostPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidSucceed)) { _ in
            self.clearError()
            refreshRunningThreadAttribution()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidFail)) { notification in
            self.setGenericError(
                notification.userInfo?["message"] as? String ?? "OpenAI login failed."
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarStatusItemMenuWillOpen)) { _ in
            self.handleMenuPresentationOpened()
            self.loadRecordsIfNeeded(force: true)
            self.loadMonitorModels(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarStatusItemMenuDidOpen)) { _ in
            self.showLegacyProviderNoticeIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarStatusItemMenuDidClose)) { _ in
            self.handleMenuPresentationClosed()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarStatusItemAvailableContentHeightDidChange)) { notification in
            let height = notification.userInfo?["height"] as? CGFloat
            if self.statusItemAvailableContentHeight != height {
                self.statusItemAvailableContentHeight = height
            }
        }
        .onChange(of: self.errorBanner) { _ in
            self.requestStatusItemLayoutRefresh()
        }
        .onChange(of: self.lastOpenAIManualSwitchResult) { _ in
            self.requestStatusItemLayoutRefresh()
        }
    }

    private func applyDisplayPreferences() {
        self.selectedUsagePeriod = UsagePeriod(rawValue: self.preferences.defaultUsageRange) ?? .today
        self.selectedUsageMetric = self.preferences.defaultUsageMetric == "cost" ? .cost : .tokens
        if !self.preferences.visiblePages.contains(self.selectedPage.rawValue) { self.selectedPage = .limits }
        if self.selectedUsageScope != .all && !self.dashboardToolScopes.contains(self.selectedUsageScope) { self.selectedUsageScope = .all }
    }

    @ViewBuilder
    private var mainMenuContent: some View {
        menuContentStack
    }

    private var menuContentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.menuHeader

            ScrollViewReader { scroll in
                AdaptiveMenuScrollContainer(
                    maxHeight: MenuBarPopoverSizing.scrollBodyHeightLimit(
                        availableHeight: self.statusItemAvailableContentHeight,
                        preferredHeight: CGFloat(self.preferredMenuHeight)
                    )
                ) {
                    self.scrollableMenuBody.id("menu-content-top")
                }
                .onChange(of: self.menuScrollResetKey) { _ in
                    scroll.scrollTo("menu-content-top", anchor: .top)
                }
            }

            Spacer(minLength: 0)
            MenuBarHeightResizeHandle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, MenuBarPopoverSizing.topContentInset)
        .padding(.bottom, MenuBarPopoverSizing.bottomContentInset)
        .frame(height: MenuBarPopoverSizing.clampedHeight(
            desiredHeight: MenuBarPopoverSizing.defaultHeight,
            availableHeight: self.statusItemAvailableContentHeight,
            preferredHeight: CGFloat(self.preferredMenuHeight)
        ))
        .background(
            LinearGradient(
                colors: [MenuSurface.backgroundTop.opacity(self.preferences.backgroundOpacity), MenuSurface.backgroundBottom.opacity(self.preferences.backgroundOpacity)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var preferences: ApplicationPreferences { self.preferencesStore.preferences }

    private var preferredColorScheme: ColorScheme? {
        switch self.preferences.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var menuHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            self.menuHeaderSummary
            HStack(spacing: 8) {
                Group {
                    if self.preferences.showTokenRate {
                        Button {
                            self.usageRateUnitRaw = self.usageRateUnit.next.rawValue
                        } label: {
                            Text(self.usageRateLabel)
                                .font(MenuSurface.font(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(MenuSurface.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .buttonStyle(.plain)
                        .help(L.zh ? "点击切换平均 Token 速率单位" : "Switch average token rate unit")
                        .accessibilityIdentifier("codexbar.header.rate-unit-toggle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                self.headerPeriodPicker
                self.dashboardMetricButton
                .frame(width: 30, height: 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 6)
    }

    private var headerPageControls: some View {
        HStack(spacing: 3) {
            Group {
                if self.selectedPage == .limits {
                    self.addManagementMenu
                } else {
                    Color.clear
                }
            }
            .frame(width: 26, height: 28)
            Spacer(minLength: 0)
            self.pageSelectionMenu
            self.refreshToolbarButton
                .frame(width: 26, height: 28)
        }
        .frame(width: self.headerControlsWidth)
    }

    private var headerControlsWidth: CGFloat { L.zh ? 156 : 170 }

    private var pageSelectionMenu: some View {
        RouteSelectionMenu(
            title: self.selectedPage.title,
            accessibilityLabel: L.zh ? "页面切换" : "Switch page",
            items: self.preferences.visiblePages.compactMap(MenuPage.init(rawValue:)).map { page in
                RouteSelectionMenuItem(id: page.rawValue, title: page.title, isSelected: page == self.selectedPage, symbolName: page.symbol) {
                    self.selectPage(page)
                }
            },
            fontSize: 10,
            compact: true,
            fillsAvailableWidth: true,
            symbolName: self.selectedPage.symbol
        )
        .frame(width: L.zh ? 74 : 104)
        .accessibilityIdentifier("codexbar.page-selector")
        .help(L.zh ? "切换额度、统计与其他页面" : "Switch limits, statistics and other pages")
    }

    private var dashboardMetricButton: some View {
                Button {
                    self.selectedUsageMetric = self.selectedUsageMetric == .tokens ? .cost : .tokens
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(MenuSurface.font(size: 12, weight: .medium))
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                    .foregroundStyle(MenuSurface.muted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("codexbar.header.metric-toggle")
                .accessibilityValue(self.selectedUsageMetric == .tokens ? "Tokens" : (L.zh ? "费用" : "Cost"))
                .help(L.zh ? "切换 Token／用量价值估算（非订阅账单）" : "Switch tokens / estimated usage value (not a subscription bill)")
    }

    private var menuHeaderSummary: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 4) {
                if self.preferences.showAppIcon {
                    Button {
                        self.usageRateUnitRaw = self.usageRateUnit.next.rawValue
                    } label: {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(L.zh
                        ? "所选时间范围内全部 Token 的平均速率，非实时速度；点击切换 tok/s 与 tok/min"
                        : "Average total tokens over the selected period, not live speed; click to switch tok/s and tok/min")
                    .accessibilityLabel(L.zh ? "Codexbar 图标，切换平均 Token 速率单位" : "Codexbar icon, switch average token rate unit")
                    .accessibilityIdentifier("codexbar.rate-unit-toggle")
                }
                Text("codexbar")
                    .font(MenuSurface.font(size: 11, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            self.headerPageControls
            self.settingsToolbarButton
                .frame(width: 30, height: 32)
        }
    }

    private var headerPeriodPicker: some View {
        SlidingGlassSelection(
                values: UsagePeriod.primaryCases,
                selection: self.selectedUsagePeriod,
                onSelect: { self.selectUsagePeriod($0) },
                accessibilityIdentifier: { "codexbar.period.\($0.rawValue)" },
                spacing: 2, cornerRadius: 6
            ) { period, selected in
                Text(self.headerPeriodTitle(period))
                    .font(MenuSurface.font(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? MenuSurface.foreground : MenuSurface.muted)
                    .frame(minWidth: 36)
                    .padding(.vertical, 6)
                    .accessibilityLabel(period.title)
            }
            .frame(width: self.headerControlsWidth)
    }

    private func headerPeriodTitle(_ period: UsagePeriod) -> String {
        switch period {
        case .today: return L.zh ? "今天" : "DAY"
        case .thisWeek: return L.zh ? "本周" : "WEEK"
        case .thisMonth: return L.zh ? "本月" : "MONTH"
        case .allTime: return L.zh ? "总计" : "TOTAL"
        case .last7Days, .last30Days: return period.title
        }
    }

    private var usageRateUnit: UsageRateUnit {
        UsageRateUnit(rawValue: self.usageRateUnitRaw) ?? .perSecond
    }

    private var usageRateLabel: String {
        let aggregate = self.usageAggregate(for: self.overviewUsageScope)
        guard let rate = UsageRatePresentation.intervalAverage(
            aggregate: aggregate,
            period: self.displayedUsagePeriod,
            unit: self.usageRateUnit,
            now: self.now,
            calendar: .current
        ) else {
            return "— \(self.usageRateUnit.shortLabel)"
        }
        let value: String
        if rate >= 1_000 {
            value = self.compactTokens(Int(min(rate.rounded(), Double(Int.max))))
        } else if rate < 0.1 {
            value = "<0.1"
        } else if rate < 10 {
            value = String(format: "%.1f", rate)
        } else {
            value = String(format: "%.0f", rate)
        }
        return "\(value) \(self.usageRateUnit.shortLabel)"
    }

    private var activeOpenAIAccount: TokenAccount? {
        if let route = try? CodexRouteResolver.resolve(config: self.store.config),
           route.targetProvider.kind == .openAIOAuth {
            return self.store.accounts.first(where: { $0.accountId == route.targetAccount.id })
        }
        guard self.store.activeProvider?.kind == .openAIOAuth else { return nil }
        let selectedAccountID = self.store.activeProviderAccount?.id
        return self.store.accounts.first(where: { $0.accountId == selectedAccountID })
            ?? self.store.accounts.first(where: \.isActive)
    }

    @ViewBuilder
    private var activeOpenAIStatus: some View {
        if let account = self.activeOpenAIAccount {
            let usesReserve = ReserveModelPolicy.isReserve(self.requestRouteSummary?.model ?? self.store.activeModel)
            let quotaExhausted = usesReserve
                ? (account.lunaReserveRemainingPercent ?? 0) <= 0
                : account.quotaExhausted
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(account.isBanned ? Color.red : (account.tokenExpired || quotaExhausted ? Color.orange : MenuSurface.accent))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(account.isBanned
                            ? (L.zh ? "账号已停用" : "Account suspended")
                            : (account.tokenExpired
                                ? (L.zh ? "需要重新授权" : "Reauthorization required")
                                : (quotaExhausted
                                    ? (L.zh ? "额度已用尽" : "Quota exhausted")
                                    : (L.zh ? "账号可用" : "Account available"))))
                    Text(self.accountIdentity(account))
                        .font(MenuSurface.font(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(usesReserve ? "Reserve" : (L.zh ? "当前账号" : "Current"))
                        .font(MenuSurface.font(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 9) {
                    Text(self.store.config.openAI.usageDisplayMode.badgeTitle)
                        .font(MenuSurface.font(size: 9))
                        .foregroundStyle(.secondary)
                    ForEach(Array(account.usageWindowDisplays(mode: self.store.config.openAI.usageDisplayMode)
                        .filter { !usesReserve || $0.label == L.lunaReserve }.prefix(2).enumerated()), id: \.offset) { _, window in
                        Text("\(window.label) \(Int(window.displayPercent))%")
                            .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(window.remainingPercent <= 20 ? Color.orange : Color.primary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 4) {
                    if usesReserve, let reset = account.lunaReserveResetAt {
                        Text((L.zh ? "Reserve 重置 " : "Reserve resets ") + reset.formatted(date: .abbreviated, time: .shortened))
                    } else if account.primaryResetDescription.isEmpty == false {
                        Text((L.zh ? "重置 " : "Reset ") + account.primaryResetDescription)
                    }
                    if let checked = account.lastChecked {
                        Spacer(minLength: 0)
                        Text((L.zh ? "更新 " : "Updated ") + checked.formatted(date: .omitted, time: .shortened))
                    }
                }
                .font(MenuSurface.font(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var scrollableMenuBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.usageOverview
            if let pendingAvailability = self.updateCoordinator.pendingAvailability {
                self.updateAvailableBanner(availability: pendingAvailability)
            }
            switch self.selectedPage {
            case .limits:
                self.codexManagementContent
            case .home:
                self.homePageContent
            case .tools:
                self.toolsPageContent
            case .models:
                self.modelsPageContent
            case .projects:
                self.projectsPageContent
            case .sessions:
                self.sessionsPageContent
            case .devices:
                self.devicesPageContent
            case .trends:
                self.trendsPageContent
            }
            if let banner = self.errorBanner {
                HStack {
                    let isNotice = banner.source == .notice
                    Image(systemName: isNotice ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(isNotice ? MenuSurface.accent : .yellow)
                    Text(banner.message)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        self.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(MenuSurface.raised, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .padding(.bottom, 8)
    }

    private var visibleCodexSummary: LocalCostSummary {
        self.preferences.disabledTools.contains("codex") ? .empty : self.store.localCostSummary
    }

    private var visibleToolSnapshots: [ToolUsageClient: ToolUsageSnapshot] {
        self.toolUsageStore.displaySnapshots.filter { !self.preferences.disabledTools.contains($0.key.rawValue) }
    }

    private var menuScrollResetKey: String {
        "\(self.selectedPage.rawValue)/\(self.selectedUsageScope.id)/\(self.sessionPageIndex)/\(self.selectedPage == .projects ? self.projectNavigation.projectPageIndex : 0)"
    }

    private var monitorPresentation: MenuMonitorPresentation? { self.monitorDisplay.presentation }
    private var displayedUsagePeriod: UsagePeriod { self.monitorDisplay.displayedPeriod }
    private var displayedUsageScope: UsageScope { self.monitorDisplay.displayedScope }
    private var overviewUsageScope: UsageScope {
        self.selectedPage == .limits ? .all : self.displayedUsageScope
    }

    private func usageAggregate(for scope: UsageScope) -> UsageAggregate {
        self.monitorPresentation?.aggregates[scope] ?? .empty
    }

    private var monitorPageData: MonitorPageData {
        self.monitorPresentation?.page ?? .empty
    }

    private func selectUsagePeriod(_ period: UsagePeriod) {
        self.monitorDisplay.select(period: period, scope: self.selectedUsageScope)
        self.selectedUsagePeriod = period
    }

    private func refreshMonitorPageData() {
        self.monitorDisplay.select(period: self.selectedUsagePeriod, scope: self.selectedUsageScope)
        guard !self.monitorProjectionScheduled else { return }
        self.monitorProjectionScheduled = true
        DispatchQueue.main.async {
            self.monitorProjectionScheduled = false
            self.buildMonitorPageData()
        }
    }

    private func buildMonitorPageData() {
        let requestID = UUID()
        self.monitorProjectionID = requestID
        let codexEnabled = !self.preferences.disabledTools.contains("codex")
        // Publish one coherent period after its index is ready; keep the last complete frame while loading.
        guard !codexEnabled || (self.monitorModelPeriod == self.selectedUsagePeriod && !self.isLoadingMonitorModels) else { return }
        let summary = self.visibleCodexSummary
        let records = codexEnabled ? self.recordsSnapshot : nil
        let tools = self.visibleToolSnapshots
        let selectedToolSnapshot: ToolUsageSnapshot?
        if case .client(let client) = self.selectedUsageScope,
           self.preferences.disabledTools.contains(client.rawValue) {
            selectedToolSnapshot = self.toolUsageStore.displaySnapshots[client]
        } else {
            selectedToolSnapshot = nil
        }
        let period = self.selectedUsagePeriod
        let scope = self.selectedUsageScope
        let models = codexEnabled && self.monitorModelPeriod == period ? self.monitorModelUsage : nil
        let running = codexEnabled ? self.runningThreadAttribution : .empty
        let sessions = codexEnabled && self.monitorModelPeriod == period ? self.monitorSessionUsage : nil
        let recent = codexEnabled ? self.recentMonitorSessionUsage : nil
        let limit = self.preferences.homeItemLimit
        let calendar = Calendar.current
        self.monitorProjectionRefresh.requestRefresh(now: self.now, load: { now in
            MenuMonitorPresentation.build(costSummary: summary, records: records, toolSnapshots: tools,
                selectedToolSnapshot: selectedToolSnapshot,
                modelUsage: models, runningThreads: running, period: period, scope: scope,
                codexSessions: sessions, recentCodexSessions: recent, recentSessionLimit: limit,
                now: now, calendar: calendar)
        }, apply: { result in
            guard self.monitorProjectionID == requestID,
                  result.period == self.selectedUsagePeriod,
                  result.scope == self.selectedUsageScope else { return }
            self.monitorDisplay.publish(result)
        })
    }

    private var usageOverview: some View {
        let aggregate = self.usageAggregate(for: self.overviewUsageScope)
        return VStack(alignment: .leading, spacing: 4) {
            Text(self.heroValue(for: aggregate))
                .font(MenuSurface.font(size: 36, weight: .medium, design: .monospaced))
                .tracking(-2.2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(MenuSurface.foreground)
                .modifier(UsageNumberTransition(value: self.selectedUsageMetric == .tokens ? Double(aggregate.tokens) : aggregate.knownCostUSD))
                .accessibilityIdentifier("codexbar.usage.hero-value")

            Text(self.heroSubtitle(for: aggregate))
                .modifier(UsageNumberTransition(value: self.selectedUsageMetric == .cost ? Double(aggregate.tokens) : aggregate.knownCostUSD))
                .font(MenuSurface.font(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(MenuSurface.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let overviewStatus = self.overviewStatusText {
                Text(overviewStatus)
                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(MenuSurface.muted)
                    .padding(.top, 2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("codexbar.usage.period-summary")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var overviewStatusText: String? {
        let range: String
        if let start = self.displayedUsagePeriod.firstDay(now: self.now, calendar: .current) {
            range = start.formatted(.dateTime.month().day()) + " – " + self.now.formatted(.dateTime.month().day())
        } else {
            range = L.zh ? "全部历史" : "All history"
        }
        return [self.sourceSummaryText, range].compactMap { $0 }.joined(separator: " · ")
    }

    private var sourceSummaryText: String? {
        switch self.overviewUsageScope {
        case .all:
            let unavailable = ToolUsageClient.allCases.filter { !self.preferences.disabledTools.contains($0.rawValue) }.filter {
                self.toolUsageStore.displaySnapshots[$0]?.availability != .ready
            }.count
            if unavailable > 0 {
                return L.zh
                    ? "\(unavailable) 源未就绪"
                    : "\(unavailable) sources pending"
            }
            return L.zh ? "\(self.dashboardToolScopes.count) 源合计" : "\(self.dashboardToolScopes.count) sources combined"
        case .codex:
            return LocalCostSummaryPresentation.statusText(for: self.store.localCostRefreshState)
        case .client(let client):
            return self.shortToolStatus(self.toolUsageStore.displaySnapshots[client], client: client)
        }
    }

    private var inlineUsageDetails: some View {
        let aggregate = self.usageAggregate(for: self.displayedUsageScope)
        let entries = UsagePresentation.chartEntries(
            aggregate: aggregate,
            period: self.displayedUsagePeriod,
            now: self.now,
            calendar: .current
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text((L.zh ? "用量趋势" : "USAGE TREND").uppercased())
                    .font(MenuSurface.font(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(MenuSurface.foreground)
                Button {
                    self.trendChartStyle = self.trendChartStyle == .line ? .bar : .line
                } label: {
                    Image(systemName: self.trendChartStyle.toggleSymbol)
                        .font(MenuSurface.font(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MenuSurface.muted)
                .accessibilityIdentifier("codexbar.trend.chart-style")
                .help(L.zh ? "切换柱状图／折线图" : "Switch bar / line chart")
                Spacer()
                Text(self.displayedUsagePeriod.title)
                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(MenuSurface.muted)
            }
            .padding(.top, 4)
            .padding(.bottom, 9)
            DashboardTrendChart(
                entries: entries, metric: self.selectedUsageMetric,
                accent: MenuSurface.accent, muted: MenuSurface.muted,
                height: self.selectedPage == .trends ? 128 : 76,
                style: self.trendChartStyle
            )
            .contentShape(Rectangle())
            .onTapGesture { self.openUsageDashboard() }
            .help(L.zh ? "点击打开使用仪表盘" : "Click to open the usage dashboard")
            Button(action: self.openUsageDashboard) {
                Label(L.zh ? "打开使用仪表盘" : "Open usage dashboard", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(MenuSurface.font(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MenuSurface.accent)
            if self.displayedUsagePeriod == .allTime {
                Text(L.zh ? "上方是累计总量；图中只绘制最近 30 天" : "Total above is all-time; chart shows only the last 30 days")
                    .font(MenuSurface.font(size: 9, design: .monospaced))
                    .foregroundStyle(MenuSurface.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    private func heroValue(for aggregate: UsageAggregate) -> String {
        if self.selectedUsageMetric == .tokens {
            return aggregate.tokens.formatted()
        }
        if aggregate.costIsComplete == false && aggregate.knownCostUSD == 0 {
            return "—"
        }
        return (aggregate.costIsComplete ? "" : "≥") + self.currency(aggregate.knownCostUSD)
    }

    private func heroSubtitle(for aggregate: UsageAggregate) -> String {
        if self.selectedUsageMetric == .cost {
            return "\(aggregate.tokens.formatted()) tokens"
        }
        if aggregate.costIsComplete == false && aggregate.knownCostUSD == 0 {
            return L.zh ? "部分来源未提供费用" : "Cost unavailable for some sources"
        }
        let prefix = aggregate.costIsComplete ? "" : "≥"
        return prefix + self.currency(aggregate.knownCostUSD)
    }

    private var dashboardToolScopes: [UsageScope] {
        self.preferences.enabledTools.compactMap { id in
            id == "codex" ? .codex : ToolUsageClient(rawValue: id).map(UsageScope.client)
        }
    }

    private var dashboardQuotaAccount: TokenAccount? {
        self.activeOpenAIAccount ?? self.store.accounts.first
    }

    private var homePageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(self.preferences.visibleHomeModules, id: \.self) { module in
                switch module {
                case "limits": self.homeLimitsPreview
                case "tools": self.homeToolsPreview
                case "models": self.homeModelsPreview
                case "sessions": self.homeSessionsPreview
                case "activity": self.homeActivityPreview
                case "trends": self.homeTrendPreview
                case "devices": self.homeDevicesPreview
                default: EmptyView()
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func homeModule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7, content: content)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { MenuSurface.line.frame(height: 1) }
            .padding(.horizontal, 14)
    }

    private var homeLimitsPreview: some View {
        self.homeModule {
            self.sectionNavigationHeading(.limits)
            if let account = self.dashboardQuotaAccount {
                Label("Codex", systemImage: "circle.hexagongrid")
                    .font(MenuSurface.font(size: 12, weight: .medium, design: .monospaced))
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(account.usageWindowDisplays(mode: self.store.config.openAI.usageDisplayMode).prefix(2).enumerated()), id: \.element.id) { index, window in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(window.label).foregroundStyle(MenuSurface.muted)
                                Spacer(minLength: 1)
                                Text("\(Int(window.displayPercent))% " + self.store.config.openAI.usageDisplayMode.badgeTitle)
                            }
                            .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                            Text(self.quotaResetText(account: account, window: window, index: index))
                                .font(MenuSurface.font(size: 9, design: .monospaced))
                                .foregroundStyle(MenuSurface.muted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.leading, 18)
            } else {
                self.pageEmptyState(L.zh ? "暂无可用的账号额度" : "No account limits available")
            }
        }
    }

    private var homeModelsPreview: some View {
        self.homeModule {
            self.sectionNavigationHeading(.models)
            self.modelRows(limit: self.preferences.homeItemLimit, compact: true)
        }
    }

    private var homeSessionsPreview: some View {
        self.homeModule {
            self.sectionNavigationHeading(.sessions, trailing: (L.zh ? "近 30 天 · " : "30d · ") + "\(self.monitorPageData.recentSessions.filter { $0.isRunning == true }.count) " + (L.zh ? "个运行中" : "running"))
            self.sessionRows(compact: true)
        }
    }

    private var homeActivityPreview: some View {
        let history = self.monitorPresentation?.history ?? .empty
        return self.homeModule {
            DashboardActivityView(
                entries: history.dailyEntries, now: self.now, metric: self.selectedUsageMetric,
                accent: MenuSurface.accent, muted: MenuSurface.muted,
                showsTrendChart: false,
                showTrends: { self.selectPage(.trends) }
            )
        }
    }

    private var homeTrendPreview: some View {
        self.homeModule {
            self.sectionNavigationHeading(.trends, trailing: self.displayedUsagePeriod.title)
            DashboardTrendChart(
                entries: UsagePresentation.chartEntries(aggregate: self.usageAggregate(for: .all), period: self.displayedUsagePeriod, now: self.now, calendar: .current),
                metric: self.selectedUsageMetric, accent: MenuSurface.accent, muted: MenuSurface.muted, height: 70
            )
            .contentShape(Rectangle())
            .onTapGesture { self.openUsageDashboard() }
            .help(L.zh ? "点击打开使用仪表盘" : "Click to open the usage dashboard")
        }
    }

    private var homeToolsPreview: some View {
        let total = self.usageAggregate(for: .all).tokens
        return self.homeModule {
            self.sectionNavigationHeading(.tools)
            ForEach(self.dashboardToolScopes) { scope in
                Button {
                    self.selectedPage = .tools
                    self.selectedUsageScope = scope
                } label: {
                    self.compactUsageRow(title: scope.title, symbol: self.dashboardSymbol(for: scope), tokens: self.usageAggregate(for: scope).tokens, total: total, tint: self.dashboardTint(for: scope))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var homeDevicesPreview: some View {
        let enabledTools = Set(self.preferences.enabledTools)
        let devices = self.syncedDevices.map {
            DeviceUsageBreakdown.build(device: $0, period: self.displayedUsagePeriod,
                enabledToolIDs: enabledTools, now: self.now)
        }
        let total = devices.reduce(0.0) { $0 + Double($1.aggregate.tokens) }
        return self.homeModule {
            self.sectionNavigationHeading(.devices)
            ForEach(Array(devices.prefix(self.preferences.homeItemLimit))) { breakdown in
                Button {
                    self.expandedDeviceIDs.insert(breakdown.device.deviceID)
                    self.selectedPage = .devices
                } label: {
                    self.compactUsageRow(title: breakdown.device.deviceName, symbol: "desktopcomputer", tokens: breakdown.aggregate.tokens, total: Int(min(Double(Int.max - 1024), total)), tint: MenuSurface.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func quotaResetText(account: TokenAccount, window: UsageWindowDisplay, index: Int) -> String {
        if window.label == L.lunaReserve {
            guard let resetAt = account.lunaReserveResetAt else { return "" }
            return (L.zh ? "重置 " : "Reset ") + self.relativeActivity(resetAt)
        }
        return index == 0 ? account.primaryResetDescription : account.secondaryResetDescription
    }

    private var toolsPageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.usageScopeMenu.padding(.horizontal, 14)
            switch self.displayedUsageScope {
            case .all:
                self.toolsUsageList
            case .codex:
                VStack(alignment: .leading, spacing: 8) {
                    self.recentUsageRows(aggregate: self.usageAggregate(for: .codex))
                    self.toolBreakdownSections
                }
                .padding(.horizontal, 14)
            case .client(let client):
                self.externalToolDetail(client)
            }
        }
        .padding(.bottom, 12)
        .accessibilityIdentifier("codexbar.tools.detail.\(self.displayedUsageScope.id)")
    }

    private var toolsUsageList: some View {
        let maximum = max(self.dashboardToolScopes.map { self.usageAggregate(for: $0).tokens }.max() ?? 0, 1)
        return VStack(spacing: 0) {
            ForEach(self.dashboardToolScopes) { scope in
                let aggregate = self.usageAggregate(for: scope)
                Button { self.selectedUsageScope = scope } label: {
                    self.dashboardUsageRow(
                        title: scope.title,
                        symbol: self.dashboardSymbol(for: scope),
                        tokens: aggregate.tokens,
                        cost: self.dashboardCostLabel(aggregate),
                        maximum: maximum,
                        tint: self.dashboardTint(for: scope)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
    }

    private var modelsPageContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                self.usageScopeMenu
                Spacer()
                self.metricSortPicker
            }
            self.costEstimateExplanation
            self.modelRows(limit: Int.max, compact: false)
        }
        .padding(.horizontal, 14)
    }

    private var metricSortPicker: some View {
        HStack(spacing: 2) {
            ForEach(UsageMetric.allCases) { metric in
                Button { self.selectedUsageMetric = metric } label: {
                    Text(metric.title)
                        .font(MenuSurface.font(size: 9, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .foregroundStyle(self.selectedUsageMetric == metric ? MenuSurface.accent : MenuSurface.muted)
                        .background(self.selectedUsageMetric == metric ? MenuSurface.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var projectsPageContent: some View {
        let data = self.monitorPageData
        let grouped = self.monitorPresentation?.sessionsByProject ?? [:]
        return VStack(alignment: .leading, spacing: 7) {
            self.usageScopeMenu
            if !data.projectsAvailable {
                self.pageEmptyState(L.zh ? "项目记录暂不可用" : "Project records unavailable")
            } else if data.projects.isEmpty {
                self.pageEmptyState(L.zh ? "所选时间内暂无带项目路径的会话" : "No sessions with project paths in this period")
            } else {
                ProjectUsageList(projects: data.projects, sessionsByProject: grouped,
                                 navigation: self.projectNavigation) { project, maximum in
                    self.projectSummary(project, maximum: maximum)
                } details: { project in
                    self.projectToolDetails(project)
                } session: { session, maximum in
                    self.sessionRow(session, compact: true, maximum: maximum)
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func projectSummary(_ project: MonitorRunningProject, maximum: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            self.dashboardUsageRow(title: project.displayName, symbol: "folder", tokens: project.totalTokens,
                cost: self.knownCostLabel(project.knownCostUSD, complete: project.costIsComplete),
                maximum: maximum, tint: MenuSurface.accent)
            HStack {
                Text("\(project.sessionCount) " + (L.zh ? "个会话" : "sessions"))
                Spacer()
                if project.runningThreadCount > 0 {
                    Text("\(project.runningThreadCount) " + (L.zh ? "个运行中" : "running"))
                        .foregroundStyle(MenuSurface.accent)
                }
                Image(systemName: self.projectNavigation.expandedProjectPaths.contains(project.cwd) ? "chevron.up" : "chevron.down")
            }
            .font(MenuSurface.font(size: 9, design: .monospaced)).foregroundStyle(MenuSurface.muted)
        }
        .contentShape(Rectangle())
    }

    private func projectToolDetails(_ project: MonitorRunningProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.cwd).font(MenuSurface.font(size: 9, design: .monospaced)).foregroundStyle(MenuSurface.muted)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            HStack {
                Text(L.zh ? "工具用量" : "Tool usage")
                Spacer()
                Text(self.displayedUsagePeriod.title)
            }
            .font(MenuSurface.font(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(MenuSurface.muted)
            ForEach(project.toolBreakdown) { tool in
                let scope = self.scope(forSourceID: tool.sourceID)
                VStack(alignment: .leading, spacing: 3) {
                    self.compactUsageRow(title: scope.title, symbol: self.dashboardSymbol(for: scope),
                        tokens: tool.totalTokens, total: project.totalTokens, tint: self.dashboardTint(for: scope))
                    HStack {
                        Text("\(tool.sessionCount) " + (L.zh ? "个会话" : "sessions"))
                        Spacer()
                        Text(self.knownCostLabel(tool.knownCostUSD, complete: tool.costIsComplete))
                    }
                    .font(MenuSurface.font(size: 9, design: .monospaced)).foregroundStyle(MenuSurface.muted)
                }
            }
            MenuSurface.line.frame(height: 1)
        }
        .padding(.vertical, 7)
    }

    private var sessionsPageContent: some View {
        let count = self.monitorPageData.sessions.count
        let pageCount = max(1, (count + 29) / 30)
        let page = min(self.sessionPageIndex, pageCount - 1)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                self.usageScopeMenu
                Spacer()
                Text("\(count) " + (L.zh ? "个会话" : "sessions"))
                    .font(MenuSurface.font(size: 10, design: .monospaced)).foregroundStyle(MenuSurface.muted)
            }
            self.sessionRows(compact: false)
            if pageCount > 1 {
                HStack {
                    Button { self.sessionPageIndex = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0)
                    Spacer()
                    Text("\(page + 1) / \(pageCount)")
                    Spacer()
                    Button { self.sessionPageIndex = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(page == pageCount - 1)
                }
                .buttonStyle(.plain).font(MenuSurface.font(size: 10, design: .monospaced))
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
    }

    private var syncedDevices: [DeviceUsageSnapshot] {
        [self.deviceSync.localSnapshot].compactMap { $0 } + self.deviceSync.remoteSnapshots
    }

    private func deviceAggregate(_ snapshot: DeviceUsageSnapshot) -> UsageAggregate {
        DeviceUsageBreakdown.build(device: snapshot, period: self.displayedUsagePeriod,
            enabledToolIDs: Set(self.preferences.enabledTools), now: self.now).aggregate
    }

    private var devicesPageContent: some View {
        let enabledTools = Set(self.preferences.enabledTools)
        let devices = self.syncedDevices.map {
            DeviceUsageBreakdown.build(device: $0, period: self.displayedUsagePeriod,
                enabledToolIDs: enabledTools, now: self.now)
        }
        let maximum = max(devices.map(\.aggregate.tokens).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                self.sectionHeading(L.zh ? "设备用量" : "DEVICE USAGE", trailing: "\(devices.count)")
                Button { self.deviceSync.syncNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(self.deviceSync.configuration.mode == .local || self.deviceSync.isSyncing)
            }
            ForEach(devices) { breakdown in
                let device = breakdown.device
                let aggregate = breakdown.aggregate
                let expanded = self.expandedDeviceIDs.contains(device.deviceID)
                Button { self.toggleExpanded(device.deviceID, in: &self.expandedDeviceIDs) } label: {
                    HStack(spacing: 6) {
                        self.dashboardUsageRow(
                            title: device.deviceName + (device.deviceID == self.deviceSync.deviceID ? (L.zh ? " · 本机" : " · Local") : ""),
                            symbol: "desktopcomputer", tokens: aggregate.tokens,
                            cost: self.dashboardCostLabel(aggregate), maximum: maximum, tint: MenuSurface.accent
                        )
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("codexbar.device.\(device.deviceID)")
                Text((device.isStale(now: self.now) ? (L.zh ? "数据待更新 · " : "Stale · ") : "") + self.relativeActivity(device.generatedAt))
                    .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                if expanded { self.deviceUsageDetails(breakdown) }
            }
            if devices.isEmpty { self.pageEmptyState(L.zh ? "正在准备本机用量…" : "Preparing local usage…") }
            self.pageEmptyState(self.deviceSync.configuration.mode == .local
                ? (L.zh ? "在设置 → 多设备同步中连接其他设备。" : "Connect other devices in Settings → Device sync.")
                : self.deviceSync.statusMessage)
            self.pageEmptyState(L.zh ? "设备页只统计本地采集记录；Cursor 的账号用量在工具页显示，避免重复累计。" : "Device totals use local records. Cursor account usage stays in Tools to avoid double counting.")
        }
        .padding(.horizontal, 14)
    }

    private func deviceUsageDetails(_ breakdown: DeviceUsageBreakdown) -> some View {
        let device = breakdown.device
        return VStack(alignment: .leading, spacing: 7) {
            if breakdown.tools.isEmpty {
                self.pageEmptyState(L.zh ? "所选时间内暂无已启用工具的用量" : "No enabled-tool usage in this period")
            }
            ForEach(breakdown.tools) { tool in
                let scope = self.scope(forSourceID: tool.toolID)
                HStack(spacing: 6) {
                    if self.preferences.showToolIcons {
                        Image(systemName: self.dashboardSymbol(for: scope))
                            .frame(width: 13).foregroundStyle(self.dashboardTint(for: scope))
                    }
                    Text(scope.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(tool.totalTokens.formatted()).monospacedDigit()
                    Text("\(Int((tool.fraction * 100).rounded()))%")
                        .foregroundStyle(MenuSurface.muted).frame(width: 30, alignment: .trailing)
                }
                .font(MenuSurface.font(size: 10, design: .monospaced))
                self.detailValue(L.zh ? "费用" : "Cost", value: self.knownCostLabel(tool.knownCostUSD, complete: tool.costIsComplete))
                    .padding(.leading, 19)
            }
            Divider().overlay(MenuSurface.line)
            self.detailValue(L.zh ? "数据来源" : "Source", value: device.deviceID == self.deviceSync.deviceID
                ? (L.zh ? "本机采集" : "Local collectors") : self.deviceSync.configuration.mode.title)
            self.detailValue(L.zh ? "快照时间" : "Snapshot", value: device.generatedAt.formatted(date: .abbreviated, time: .standard))
            self.detailValue(L.zh ? "统计时区" : "Time zone", value: device.timeZoneIdentifier)
            self.detailValue(L.zh ? "活跃天数" : "Active days", value: "\(breakdown.activeDayCount)")
        }
        .font(MenuSurface.font(size: 9, design: .monospaced))
        .padding(.leading, 19)
        .padding(.bottom, 12)
    }

    private var trendsPageContent: some View {
        let trend = self.monitorPageData.trend
        return VStack(alignment: .leading, spacing: 7) {
            self.usageScopeMenu.padding(.horizontal, 14)
            self.inlineUsageDetails
            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    self.trendStatistic(L.zh ? "活跃日" : "ACTIVE DAYS", value: "\(trend.activeDayCount)")
                    self.trendStatistic(L.zh ? "连续活跃" : "CURRENT STREAK", value: "\(trend.currentStreakDays)")
                }
                HStack(spacing: 7) {
                    self.trendStatistic(L.zh ? "最长连续" : "LONGEST STREAK", value: "\(trend.longestStreakDays)")
                    self.trendStatistic(L.zh ? "单日峰值" : "PEAK DAY", value: self.compactTokens(trend.peakDay?.totalTokens ?? 0))
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 12)
    }

    private func openUsageDashboard() {
        UsageDashboardWindow.shared.show(codex: self.visibleCodexSummary,
            tools: self.visibleToolSnapshots, period: self.displayedUsagePeriod, scope: self.displayedUsageScope) {
                self.store.refreshLocalCostSummary(force: true, minimumInterval: 0, refreshSessionCache: false)
                self.toolUsageStore.refreshIfNeeded(force: true)
            }
    }

    private var usageScopeMenu: some View {
        RouteSelectionMenu(
            title: self.selectedUsageScope.title,
            accessibilityLabel: L.zh ? "工具范围" : "Tool scope",
            items: ([UsageScope.all] + self.dashboardToolScopes).map { scope in
                RouteSelectionMenuItem(id: scope.id, title: scope.title, isSelected: scope == self.selectedUsageScope) {
                    self.selectedUsageScope = scope
                }
            },
            fontSize: 11
        )
        .fixedSize()
        .padding(.vertical, 5)
    }

    private func trendStatistic(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MenuSurface.font(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(MenuSurface.muted)
            Text(value)
                .font(MenuSurface.font(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(MenuSurface.foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private func sectionNavigationHeading(_ page: MenuPage, trailing: String? = nil) -> some View {
        Button { self.selectPage(page) } label: {
            HStack {
                Text(page.title)
                    .font(MenuSurface.font(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(MenuSurface.foreground)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(MenuSurface.muted)
                }
                Image(systemName: page.symbol)
                    .font(MenuSurface.font(size: 10, weight: .medium))
                    .foregroundStyle(MenuSurface.muted)
            }
            .contentShape(Rectangle())
            .padding(.bottom, 2)
        }
        .buttonStyle(.plain)
    }

    private func pageEmptyState(_ message: String) -> some View {
        Text(message)
            .font(MenuSurface.font(size: 10))
            .foregroundStyle(MenuSurface.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func modelRows(limit: Int, compact: Bool) -> some View {
        let data = self.monitorPageData
        if let models = data.models {
            let sorted = compact || self.selectedUsageMetric == .tokens
                ? models.sorted { $0.totalTokens > $1.totalTokens }
                : models.sorted { $0.estimatedCostUSD > $1.estimatedCostUSD }
            let maximum = max(sorted.map { self.selectedUsageMetric == .tokens ? Double($0.totalTokens) : $0.estimatedCostUSD }.max() ?? 0, 1)
            let maximumTokens = max(sorted.map(\.totalTokens).max() ?? 0, 1)
            let totalTokens = max(self.usageAggregate(for: self.displayedUsageScope).tokens, 1)
            if sorted.isEmpty {
                self.pageEmptyState(L.zh ? "所选时间内暂无模型用量" : "No model usage in this period")
            }
            ForEach(Array(sorted.prefix(limit))) { model in
                let name = self.modelDisplayName(model.modelID)
                let scope = self.scope(forSourceID: model.sourceIDs.first ?? "codex")
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        self.toggleExpanded(model.id, in: &self.expandedModelIDs)
                    } label: {
                        if compact {
                            self.compactUsageRow(title: name, symbol: self.modelSymbol(model.modelID), tokens: model.totalTokens,
                                total: totalTokens, tint: self.dashboardTint(for: scope))
                        } else {
                            self.dashboardUsageRow(title: name, symbol: self.modelSymbol(model.modelID), tokens: model.totalTokens,
                                cost: self.knownCostLabel(model.estimatedCostUSD, complete: model.costIsComplete),
                                maximum: maximumTokens, tint: self.dashboardTint(for: scope),
                                barFraction: (self.selectedUsageMetric == .tokens ? Double(model.totalTokens) : model.estimatedCostUSD) / maximum)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L.zh ? "展开模型明细" : "Expand model details")
                    if self.expandedModelIDs.contains(model.id) {
                        VStack(alignment: .leading, spacing: 5) {
                            self.detailValue(
                                model.hasCompleteTokenBreakdown ? (L.zh ? "输入（含缓存）" : "Input including cache") : (L.zh ? "已知输入（含缓存）" : "Known input including cache"),
                                value: model.cacheEligibleInputTokens.formatted(.number.precision(.fractionLength(0)))
                            )
                            self.detailValue(L.zh ? "缓存读取" : "Cache read", value: model.cachedInputTokens.formatted())
                            self.detailValue(L.zh ? "缓存写入" : "Cache write", value: model.cacheWriteTokens.formatted())
                            self.detailValue(L.zh ? "输出" : "Output", value: model.outputTokens.formatted())
                            self.detailValue(
                                model.hasCompleteTokenBreakdown ? (L.zh ? "缓存命中率" : "Cache hit rate") : (L.zh ? "缓存命中率（已知输入）" : "Cache hit rate (known input)"),
                                value: model.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? (L.zh ? "暂无数据" : "Unavailable")
                            )
                            Text(L.zh ? "缓存读取 ÷ 输入（含缓存），不含输出 Token" : "Cache reads divided by input including cache; output tokens are excluded")
                                .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                            if !model.toolBreakdown.isEmpty {
                                MenuSurface.line.frame(height: 1).padding(.vertical, 4)
                                Text(L.zh ? "工具来源" : "Tool sources").foregroundStyle(MenuSurface.muted)
                                ForEach(model.toolBreakdown) { tool in
                                    let toolScope = self.scope(forSourceID: tool.sourceID)
                                    self.compactUsageRow(
                                        title: toolScope.title, symbol: self.dashboardSymbol(for: toolScope),
                                        tokens: tool.totalTokens, total: model.totalTokens,
                                        tint: self.dashboardTint(for: toolScope)
                                    )
                                    self.detailValue(L.zh ? "费用" : "Cost", value: self.knownCostLabel(tool.knownCostUSD, complete: tool.costIsComplete))
                                }
                            }
                        }
                        .font(MenuSurface.font(size: 10, design: .monospaced)).padding(.leading, 19).padding(.bottom, 10)
                    }
                }
            }
        } else {
            self.pageEmptyState(self.monitorModelsLoadFailed
                ? (L.zh ? "模型用量暂不可用" : "Model usage unavailable")
                : (L.zh ? "正在读取模型用量…" : "Loading model usage…"))
        }
    }

    @ViewBuilder
    private func sessionRows(compact: Bool) -> some View {
        let data = self.monitorPageData
        let all = compact ? data.recentSessions : data.sessions
        let page = min(self.sessionPageIndex, max(0, (all.count - 1) / 30))
        let rows = compact ? all : Array(all.dropFirst(page * 30).prefix(30))
        if rows.isEmpty {
            self.pageEmptyState(data.recordsAvailable
                ? (L.zh ? "所选时间内暂无会话" : "No sessions in this period")
                : (self.recordsLoadFailed ? (L.zh ? "会话记录暂不可用" : "Session records unavailable") : (L.zh ? "正在读取会话记录…" : "Loading sessions…")))
        } else {
            let maximum = max(all.map(\.totalTokens).max() ?? 0, 1)
            ForEach(rows) { session in
                self.sessionRow(session, compact: compact, maximum: maximum, recentWindow: compact)
            }
        }
        if data.recordWarningCount > 0 {
            Text("\(data.recordWarningCount) " + (L.zh ? "个记录文件读取失败" : "record files could not be read"))
                .font(MenuSurface.font(size: 9)).foregroundStyle(.orange)
        }
        if !compact && data.missingModelCount > 0 {
            Text(L.zh ? "部分记录未标注模型，已保留会话与 Token 用量" : "Some records do not name a model; sessions and token usage are included")
                .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted).padding(.vertical, 6)
        }
    }

    private func sessionRow(_ session: MonitorSessionSummary, compact: Bool, maximum: Int, recentWindow: Bool = false) -> some View {
        let scope = self.scope(forSourceID: session.sourceID)
        return VStack(alignment: .leading, spacing: 6) {
            Button { self.toggleExpanded(session.id, in: &self.expandedSessionIDs) } label: {
                HStack(alignment: .top, spacing: 7) {
                    if self.preferences.showToolIcons {
                        Image(systemName: self.dashboardSymbol(for: scope))
                            .foregroundStyle(self.dashboardTint(for: scope)).frame(width: 12).padding(.top, 2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: session.isRunning == true ? "arrow.triangle.2.circlepath" : session.isRunning == false ? "checkmark.circle" : "circle.fill")
                                .font(MenuSurface.font(size: session.isRunning == nil ? 4 : 9))
                                .foregroundStyle(session.isRunning == true ? MenuSurface.accent : MenuSurface.muted)
                            Text(session.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text(compact ? self.compactTokens(session.totalTokens) : session.totalTokens.formatted())
                        }
                        .font(MenuSurface.font(size: 11, weight: .medium, design: .monospaced))
                        HStack(spacing: 4) {
                            Text(session.modelIDs.isEmpty ? self.modelDisplayName("unknown") : session.modelIDs.count == 1 ? self.modelDisplayName(session.modelIDs[0]) : "\(session.modelIDs.count) " + (L.zh ? "个模型" : "models"))
                                .lineLimit(1).truncationMode(.middle)
                            Text("· " + self.relativeActivity(session.lastActivityAt)).lineLimit(1)
                            Spacer(minLength: 0)
                            if !compact {
                                Text(self.knownCostLabel(session.knownCostUSD, complete: session.costIsComplete))
                            }
                        }
                        .font(MenuSurface.font(size: 9, design: .monospaced)).foregroundStyle(MenuSurface.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let used = session.contextUsedTokens, let window = session.contextWindowTokens, window > 0 {
                let remaining = max(0, min(100, Int((1 - Double(used) / Double(window)) * 100)))
                HStack {
                    Text(L.zh ? "上下文剩余" : "Context remaining")
                    Spacer()
                    Text("\(remaining)%")
                }
                .font(MenuSurface.font(size: 9, design: .monospaced))
                .foregroundStyle(remaining <= 10 ? .orange : remaining <= 30 ? .yellow : MenuSurface.muted)
                .padding(.leading, 19)
            }
            if self.expandedSessionIDs.contains(session.id) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title).fixedSize(horizontal: false, vertical: true)
                    self.detailValue(L.zh ? "工具" : "Tool", value: scope.title)
                    self.detailValue(L.zh ? "模型" : "Models", value: session.modelIDs.map(self.modelDisplayName).joined(separator: ", "))
                    if let path = session.projectPath { Text(path).lineLimit(2).truncationMode(.middle) }
                    Text(session.sessionID).textSelection(.enabled).lineLimit(2)
                    self.detailValue(recentWindow ? (L.zh ? "近 30 天用量" : "Usage in 30 days") : (L.zh ? "所选周期用量" : "Usage in this period"), value: session.totalTokens.formatted())
                    self.detailValue(L.zh ? "费用" : "Cost", value: self.knownCostLabel(session.knownCostUSD, complete: session.costIsComplete))
                    self.detailValue(L.zh ? "首次用量" : "First usage", value: session.firstUsageAt.formatted(date: .abbreviated, time: .shortened))
                    self.detailValue(L.zh ? "最近活动" : "Last activity", value: session.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                    self.detailValue(L.zh ? "状态" : "Status", value: session.isRunning.map {
                        $0 ? (L.zh ? "运行中" : "Running") : (L.zh ? "已结束" : "Finished")
                    } ?? (L.zh ? "来源未提供" : "Not provided"))
                    if let used = session.contextUsedTokens, let capacity = session.contextWindowTokens {
                        self.detailValue(L.zh ? "上下文使用 / 容量" : "Context used / capacity", value: "\(used.formatted()) / \(capacity.formatted())")
                    }
                }
                .font(MenuSurface.font(size: 9, design: .monospaced)).foregroundStyle(MenuSurface.muted)
                .padding(.leading, 19).padding(.vertical, 5)
            }
            if !compact { self.toolProgress(tokens: session.totalTokens, maximum: maximum, tint: self.dashboardTint(for: scope)) }
        }
        .padding(.vertical, compact ? 4 : 10)
        .overlay(alignment: .bottom) { if !compact { MenuSurface.line.frame(height: 1) } }
    }

    private func detailValue(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(MenuSurface.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func toggleExpanded(_ id: String, in values: inout Set<String>) {
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
    }

    private func scope(forSourceID source: String) -> UsageScope {
        ToolUsageClient(rawValue: source).map(UsageScope.client) ?? .codex
    }

    private func knownCostLabel(_ value: Double, complete: Bool) -> String {
        if !complete && value == 0 { return L.zh ? "费用未知" : "Cost unknown" }
        return (complete ? "" : "≥") + self.currency(value)
    }

    private func modelDisplayName(_ id: String) -> String {
        self.preferences.modelAliases[id] ?? (id == "unknown" || id.isEmpty ? (L.zh ? "未知模型" : "Unknown model") : id)
    }

    private func modelSymbol(_ id: String) -> String {
        let model = id.lowercased()
        if model.contains("claude") { return "asterisk" }
        if model.contains("deepseek") { return "waveform.path" }
        if model.contains("gemini") { return "sparkles" }
        if model.contains("gpt") || model.hasPrefix("o3") || model.hasPrefix("o4") { return "circle.hexagongrid" }
        return "cube"
    }

    private func sectionHeading(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(MenuSurface.font(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(MenuSurface.foreground)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(MenuSurface.muted)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 9)
    }

    private func dashboardSymbol(for scope: UsageScope) -> String {
        switch scope {
        case .all: "square.stack.3d.up"
        case .codex: "circle.hexagongrid"
        case .client(let client): self.toolSymbol(for: client)
        }
    }

    private func dashboardTint(for scope: UsageScope) -> Color {
        if case .client(let client) = scope { return self.toolTint(for: client) }
        return MenuSurface.accent
    }

    private func dashboardCostLabel(_ aggregate: UsageAggregate) -> String {
        if aggregate.knownCostUSD == 0 && aggregate.costIsComplete == false {
            return L.zh ? "费用不可用" : "Cost unavailable"
        }
        return (aggregate.costIsComplete ? "" : "≥") + self.currency(aggregate.knownCostUSD)
    }

    private func compactUsageRow(title: String, symbol: String, tokens: Int, total: Int, tint: Color) -> some View {
        HStack(spacing: 7) {
            if self.preferences.showToolIcons {
                Image(systemName: symbol).font(MenuSurface.font(size: 10)).frame(width: 12).foregroundStyle(tint)
            }
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Text(self.compactTokens(tokens))
            Text("\(Int(min(100, Double(tokens) / Double(max(total, 1)) * 100).rounded()))%")
                .font(MenuSurface.font(size: 10, design: .monospaced))
                .foregroundStyle(MenuSurface.muted)
                .frame(width: 32, alignment: .trailing)
        }
        .font(MenuSurface.font(size: 11, weight: .medium, design: .monospaced))
        .padding(.vertical, 2)
    }

    private func dashboardUsageRow(title: String, symbol: String, tokens: Int, cost: String, maximum: Int, tint: Color, barFraction: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if self.preferences.showToolIcons {
                    Image(systemName: symbol).font(MenuSurface.font(size: 11)).frame(width: 12).foregroundStyle(tint)
                }
                Text(title)
                    .font(MenuSurface.font(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 3)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(tokens.formatted())
                        .font(MenuSurface.font(size: 12, weight: .semibold, design: .monospaced))
                    Text(cost)
                        .font(MenuSurface.font(size: 10, design: .monospaced))
                        .foregroundStyle(MenuSurface.muted)
                }
            }
            self.toolProgress(tokens: tokens, maximum: maximum, tint: tint, fraction: barFraction)
        }
        .foregroundStyle(MenuSurface.foreground)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { MenuSurface.line.frame(height: 1) }
    }

    private func relativeActivity(_ date: Date) -> String {
        let formatter = L.zh ? Self.relativeChineseFormatter : Self.relativeEnglishFormatter
        return formatter.localizedString(for: date, relativeTo: self.now)
    }

    private func quotaLine(_ window: UsageWindowDisplay, mode: CodexBarUsageDisplayMode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .foregroundStyle(MenuSurface.muted)
                Spacer()
                Text("\(Int(window.displayPercent))% " + mode.badgeTitle)
                    .foregroundStyle(MenuSurface.foreground)
            }
            .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(window.remainingPercent <= 20 ? Color.orange : MenuSurface.accent)
                        .frame(width: geometry.size.width * min(max(window.displayPercent / 100, 0), 1))
                }
            }
            .frame(height: 6)
        }
    }

    private func toolProgress(tokens: Int, maximum: Int, tint: Color, fraction suppliedFraction: Double? = nil) -> some View {
        let raw: CGFloat = suppliedFraction.map { CGFloat($0) } ?? (CGFloat(tokens) / CGFloat(max(maximum, 1)))
        let fraction = raw > 0 ? min(max(raw, 0.02), 1) : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.28))
                Capsule().fill(tint).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
    }

    private func toolSymbol(for client: ToolUsageClient) -> String {
        switch client {
        case .claudeCode: "asterisk"
        case .openCode: "terminal"
        case .cursor: "cursorarrow.rays"
        case .deepSeekHarness: "waveform.path"
        }
    }

    private func toolTint(for client: ToolUsageClient) -> Color {
        switch client {
        case .claudeCode: Color(red: 0.86, green: 0.53, blue: 0.39)
        case .openCode: Color(red: 0.68, green: 0.66, blue: 0.89)
        case .cursor: Color(red: 0.75, green: 0.81, blue: 0.82)
        case .deepSeekHarness: Color(red: 0.45, green: 0.64, blue: 0.95)
        }
    }

    private func shortToolStatus(_ snapshot: ToolUsageSnapshot?, client: ToolUsageClient? = nil) -> String {
        if (client ?? snapshot?.client) == .cursor,
           self.toolUsageStore.isRefreshing,
           (snapshot?.availability == .needsImport
                || snapshot?.availability == .noRecords
                || snapshot == nil) {
            return L.zh ? "正在同步 Cursor" : "Syncing Cursor"
        }
        switch snapshot?.availability {
        case .ready:
            if snapshot?.client == .cursor, snapshot?.evidence == .server {
                return L.zh ? "账号用量已同步" : "Account usage synced"
            }
            return L.zh ? "用量已读取" : "Usage collected"
        case .partial: return L.zh ? "部分记录未读取" : "Some records unreadable"
        case .needsImport: return L.zh ? "需导入" : "Import needed"
        case .failed: return L.zh ? "读取失败" : "Read failed"
        case .sourceMissing: return L.zh ? "未找到" : "Not found"
        case .noRecords, nil: return L.zh ? "暂无记录" : "No records"
        }
    }

    private var codexManagementContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(self.isManagementReordering
                     ? (L.zh ? "使用箭头调整软件顺序" : "Use arrows to reorder tools")
                     : (L.zh ? "AI 软件" : "AI TOOLS"))
                    .foregroundStyle(MenuSurface.muted)
                Spacer()
                Button {
                    self.isManagementReordering.toggle()
                    self.requestStatusItemLayoutRefresh()
                } label: {
                    Label(self.isManagementReordering ? (L.zh ? "完成" : "Done") : (L.zh ? "排序" : "Reorder"),
                          systemImage: self.isManagementReordering ? "checkmark" : "arrow.up.arrow.down")
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(MenuSurface.accent)
                .accessibilityIdentifier("codexbar.management.reorder")
            }
            .font(MenuSurface.font(size: 9, weight: .medium))
            .padding(.top, 7).padding(.bottom, 3)
            ForEach(self.preferences.toolOrder, id: \.self) { key in
                if key == "codex" {
                    self.codexManagementSection
                } else if let client = ToolUsageClient(rawValue: key) {
                    self.toolManagementSection(client)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var codexManagementSection: some View {
        let collapsed = self.preferences.isManagementToolCollapsed("codex")
        return VStack(alignment: .leading, spacing: 10) {
            self.managementSoftwareHeader("codex")
            if !self.isManagementReordering {
                HStack {
                    let providerCount = self.store.customProviders.count + (self.visibleOpenRouterProvider == nil ? 0 : 1)
                    Text(L.zh ? "\(self.store.accounts.count) 个账号 · \(providerCount) 个中转站"
                         : "\(self.store.accounts.count) accounts · \(providerCount) providers")
                        .foregroundStyle(MenuSurface.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { self.openAddProviderWindow(defaultPreset: .custom) } label: {
                        Label(L.zh ? "连接中转站" : "Connect provider", systemImage: "link")
                    }
                    .buttonStyle(.plain).foregroundStyle(MenuSurface.accent)
                    .accessibilityIdentifier("codexbar.management.codex.connect-provider")
                }
                .font(MenuSurface.font(size: 9, weight: .medium))
                self.codexAccountRouteCard
                    .accessibilityIdentifier("codexbar.management.codex.summary")
                if !collapsed {
                    self.codexFeatureContent
                        .accessibilityIdentifier("codexbar.management.codex.details")
                }
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { MenuSurface.line.frame(height: 1) }
        .accessibilityIdentifier("codexbar.management.tool.codex")
    }

    private var codexFeatureContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.openAIAccountsSection
            self.providersSection
        }
    }

    private func toolManagementSection(_ client: ToolUsageClient) -> some View {
        let enabled = !self.preferences.disabledTools.contains(client.rawValue)
        let collapsed = self.preferences.isManagementToolCollapsed(client.rawValue)
        let snapshot = enabled ? self.toolUsageStore.quota(for: client)
            : ToolQuotaSnapshot(client: client, status: .notConfigured, providerName: client.displayName,
                statusDetail: L.zh ? "已暂停额度与用量采集" : "Limits and usage collection is paused")
        return VStack(alignment: .leading, spacing: 10) {
            self.managementSoftwareHeader(client.rawValue)
            if !self.isManagementReordering {
                if !collapsed, let cursorAccounts = self.toolUsageStore.managedCursorAccounts,
                   let connections = self.toolUsageStore.managedConnections {
                    ManagedToolAccountsView(
                        client: client, cursorAccounts: cursorAccounts, connections: connections,
                        preferencesStore: self.preferencesStore, toolUsageStore: self.toolUsageStore,
                        importCursorCSV: client == .cursor ? { self.importCursorUsageCSV() } : nil,
                        showLocalUsage: { self.showToolUsage(client) }, isInline: true
                    )
                    .accessibilityIdentifier("codexbar.management.\(client.rawValue).details")
                } else {
                    ToolQuotaView(
                        snapshot: snapshot, symbol: self.toolSymbol(for: client), tint: self.toolTint(for: client),
                        mode: self.store.config.openAI.usageDisplayMode, expanded: false, toggle: {},
                        refresh: { self.toolUsageStore.refreshQuotasIfNeeded(force: true) },
                        showUsage: { self.showToolUsage(client) },
                        managementMode: true, isRefreshing: enabled && self.toolUsageStore.isRefreshingQuotas,
                        manage: { self.showToolManagement(client) }, canRefresh: enabled,
                        statusTitle: enabled ? nil : (L.zh ? "已暂停" : "Paused"),
                        showsHeader: false, compactManagementActions: true
                    )
                    if client == .deepSeekHarness,
                       self.toolUsageStore.managedConnections?.selectedProfile(for: client)?.providerKind == .dshSnapshot {
                        Text(L.zh ? "本地余额快照；可展开设置官方 API Key，实时查询余额。"
                             : "Local balance snapshot. Expand to set an official API key for live balance queries.")
                            .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if let updated = snapshot.refreshedAt {
                            Text((L.zh ? "更新于 " : "Updated ") + self.relativeActivity(updated))
                                .foregroundStyle(MenuSurface.muted).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { self.showToolUsage(client) } label: {
                            Label(L.zh ? "查看用量" : "View usage", systemImage: "arrow.right")
                        }
                        .buttonStyle(.plain).foregroundStyle(MenuSurface.accent)
                        .accessibilityIdentifier("codexbar.tool-quota.\(client.rawValue).usage")
                    }
                    .font(MenuSurface.font(size: 9))
                }
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { MenuSurface.line.frame(height: 1) }
        .accessibilityIdentifier("codexbar.management.tool.\(client.rawValue)")
    }

    private func managementSoftwareHeader(_ key: String) -> some View {
        let client = ToolUsageClient(rawValue: key)
        let title = client?.displayName ?? "Codex"
        let collapsed = self.preferences.isManagementToolCollapsed(key)
        let actionLabel: String = collapsed
            ? (L.zh ? "展开 \(title) 管理" : "Expand \(title) management")
            : (L.zh ? "收起 \(title) 管理" : "Collapse \(title) management")
        return HStack(spacing: 8) {
            if self.isManagementReordering {
                self.managementSoftwareHeaderLabel(key)
            } else {
                Button {
                    self.preferencesStore.toggleManagementToolCollapsed(key)
                    self.requestStatusItemLayoutRefresh()
                } label: {
                    self.managementSoftwareHeaderLabel(key)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(actionLabel)
                .accessibilityIdentifier("codexbar.management.\(key).header")
            }
            if self.isManagementReordering {
                self.managementMoveButton(key, offset: -1)
                self.managementMoveButton(key, offset: 1)
            } else {
                Menu { self.managementSoftwareActions(key) } label: {
                    Image(systemName: "ellipsis").font(MenuSurface.font(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).foregroundStyle(MenuSurface.muted)
                .accessibilityLabel(L.zh ? title + " 操作" : title + " actions")
                .accessibilityIdentifier("codexbar.management.\(key).actions")
            }
        }
    }

    private func managementSoftwareHeaderLabel(_ key: String) -> some View {
        let client = ToolUsageClient(rawValue: key)
        return HStack(spacing: 7) {
            if self.preferences.showToolIcons {
                Image(systemName: client.map(self.toolSymbol(for:)) ?? "circle.hexagongrid")
                    .foregroundStyle(client.map(self.toolTint(for:)) ?? MenuSurface.foreground)
                    .frame(width: 18)
            }
            Text(client?.displayName ?? "Codex")
                .font(MenuSurface.font(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(MenuSurface.foreground).lineLimit(1)
            Spacer(minLength: 2)
            Text(self.managementSoftwareStatus(key))
                .font(MenuSurface.font(size: 9, design: .monospaced))
                .foregroundStyle(MenuSurface.muted).lineLimit(1)
            if !self.isManagementReordering {
                Image(systemName: !self.preferences.isManagementToolCollapsed(key)
                      ? "chevron.down" : "chevron.right")
                    .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func managementMoveButton(_ key: String, offset: Int) -> some View {
        let index = self.preferences.toolOrder.firstIndex(of: key) ?? 0
        return Button { self.preferencesStore.moveManagementTool(key, by: offset) } label: {
            Image(systemName: offset < 0 ? "arrow.up" : "arrow.down")
                .font(MenuSurface.font(size: 11, weight: .semibold))
                .frame(width: 23, height: 23)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(MenuSurface.accent)
        .disabled(offset < 0 ? index == 0 : index == self.preferences.toolOrder.count - 1)
        .accessibilityLabel((offset < 0 ? (L.zh ? "上移 " : "Move up ") : (L.zh ? "下移 " : "Move down "))
                            + (ToolUsageClient(rawValue: key)?.displayName ?? "Codex"))
        .accessibilityIdentifier("codexbar.management.reorder.\(offset < 0 ? "up" : "down").\(key)")
    }

    private func managementSoftwareStatus(_ key: String) -> String {
        guard let client = ToolUsageClient(rawValue: key) else {
            return self.dashboardQuotaAccount?.planType.uppercased() ?? ""
        }
        if self.preferences.disabledTools.contains(key) { return L.zh ? "已暂停" : "Paused" }
        switch self.toolUsageStore.quota(for: client).status {
        case .ready: return ""
        case .loading: return L.zh ? "正在读取" : "Loading"
        case .notConfigured: return L.zh ? "未连接账号" : "Not connected"
        case .unsupported: return L.zh ? "服务未提供额度" : "No quota API"
        case .authenticationRequired: return L.zh ? "需要重新登录" : "Sign in again"
        case .failed: return L.zh ? "读取失败" : "Fetch failed"
        }
    }

    @ViewBuilder
    private func managementSoftwareActions(_ key: String) -> some View {
        if key == "codex" {
            Button(L.zh ? "添加 Codex 账号" : "Add Codex account") { self.startOAuthLogin() }
            Button(L.zh ? "连接第三方中转站" : "Connect third-party provider") {
                self.openAddProviderWindow(defaultPreset: .custom)
            }
            Button(L.zh ? "刷新账号额度" : "Refresh account limits") {
                Task { await self.refresh(origin: .manual, announceResult: true) }
            }.disabled(self.isRefreshing)
        } else if let client = ToolUsageClient(rawValue: key) {
            Button(L.zh ? "刷新额度" : "Refresh limits") {
                guard !self.preferences.disabledTools.contains(key), !self.toolUsageStore.isRefreshingQuotas else { return }
                self.toolUsageStore.refreshQuotasIfNeeded(force: true)
            }
            .disabled(self.preferences.disabledTools.contains(key) || self.toolUsageStore.isRefreshingQuotas)
            .accessibilityIdentifier("codexbar.tool-quota.\(key).refresh")
            Button(L.zh ? "查看用量" : "View usage") { self.showToolUsage(client) }
            Button(L.zh ? "管理账号与额度" : "Manage accounts and limits") { self.showToolManagement(client) }
                .accessibilityIdentifier("codexbar.tool-quota.\(key).manage")
            if client == .cursor {
                Button(L.zh ? "导入用量 CSV" : "Import usage CSV") { self.importCursorUsageCSV() }
                    .accessibilityIdentifier("codexbar.management.cursor.import")
            }
            Divider()
            Toggle(L.zh ? "读取额度与用量" : "Collect limits and usage", isOn: Binding(
                get: { !self.preferences.disabledTools.contains(key) },
                set: { enabled in
                    self.preferencesStore.update {
                        if enabled { $0.disabledTools.removeAll { $0 == key } }
                        else if !$0.disabledTools.contains(key) { $0.disabledTools.append(key) }
                    }
                }
            )).accessibilityIdentifier("codexbar.management.\(key).enabled")
        }
    }

    private func showToolUsage(_ client: ToolUsageClient) {
        self.selectedPage = .tools
        self.selectedUsageScope = .client(client)
        self.sessionPageIndex = 0
    }

    @ViewBuilder
    private var codexAccountRouteCard: some View {
        if self.activeOpenAIAccount != nil
            || self.requestRouteSummary != nil
            || (self.store.activeProvider != nil && self.store.activeProviderAccount != nil) {
            VStack(alignment: .leading, spacing: 10) {
                self.activeOpenAIStatus
                self.codexRouteControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var codexRouteControls: some View {
        if let requestRouteSummary {
            self.modelSelectionRow(currentModel: requestRouteSummary.model)
        } else if self.store.activeProvider != nil,
                  self.store.activeProviderAccount != nil {
            self.modelSelectionRow(currentModel: self.store.activeModel)
        }
    }

    private func externalToolDetail(_ client: ToolUsageClient) -> some View {
        let snapshot = self.toolUsageStore.displaySnapshots[client]
        let aggregate = self.usageAggregate(for: .client(client))
        return VStack(alignment: .leading, spacing: 0) {
            self.sectionHeading(client.displayName, trailing: self.shortToolStatus(snapshot, client: client))
            HStack(alignment: .top, spacing: 10) {
                if self.preferences.showToolIcons {
                    Image(systemName: self.toolSymbol(for: client))
                        .font(MenuSurface.font(size: 17, weight: .medium))
                        .foregroundStyle(self.toolTint(for: client))
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.toolSourceDescription(for: client, snapshot: snapshot))
                        .font(MenuSurface.font(size: 11, weight: .medium))
                        .foregroundStyle(MenuSurface.foreground)
                    if let detail = snapshot?.statusDetail, detail.isEmpty == false {
                        Text(detail)
                            .font(MenuSurface.font(size: 10))
                            .foregroundStyle(MenuSurface.muted)
                            .lineLimit(2)
                    }
                    if let refreshedAt = snapshot?.refreshedAt {
                        Text((L.zh ? "更新于 " : "Updated ") + refreshedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(MenuSurface.font(size: 10, design: .monospaced))
                            .foregroundStyle(MenuSurface.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            .overlay(alignment: .bottom) { MenuSurface.line.frame(height: 1) }

            if client == .cursor {
                Button(action: self.importCursorUsageCSV) {
                    Label(L.zh ? "导入 Cursor 用量 CSV" : "Import Cursor usage CSV", systemImage: "square.and.arrow.down")
                        .font(MenuSurface.font(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MenuSurface.accent)
                .padding(.vertical, 11)
            }

            self.costEstimateExplanation.padding(.vertical, 7)
            self.recentUsageRows(aggregate: aggregate)
            self.toolBreakdownSections
        }
        .padding(.horizontal, 17)
    }

    private var costEstimateExplanation: some View {
        Text(L.zh ? "费用为来源报告或按当前标准价估算的用量价值，不等于订阅账单。" : "Costs represent reported or estimated usage value at current standard rates, not subscription charges.")
            .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var toolBreakdownSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.scopedDetailHeading(.models)
            self.modelRows(limit: 5, compact: false)
            self.scopedDetailHeading(.projects)
            ForEach(Array(self.monitorPageData.projects.prefix(5))) { project in
                Button {
                    self.projectNavigation.expandedProjectPaths.insert(project.cwd)
                    self.projectNavigation.setProjectPage(0, totalProjects: self.monitorPageData.projects.count)
                    self.selectedPage = .projects
                } label: {
                    self.compactUsageRow(title: project.displayName, symbol: "folder", tokens: project.totalTokens,
                        total: self.usageAggregate(for: self.displayedUsageScope).tokens, tint: MenuSurface.accent)
                }
                .buttonStyle(.plain)
            }
            if self.monitorPageData.projects.isEmpty {
                self.pageEmptyState(L.zh ? "来源暂无项目明细" : "No project details provided")
            }
            self.scopedDetailHeading(.sessions)
            self.sessionRows(compact: true)
        }
        .padding(.top, 12)
    }

    private func scopedDetailHeading(_ page: MenuPage) -> some View {
        Button { self.selectedPage = page; self.sessionPageIndex = 0 } label: {
            HStack {
                Text(page.title).font(MenuSurface.font(size: 12, weight: .semibold))
                Spacer()
                Text(page == .sessions ? (L.zh ? "近 30 天" : "Last 30 days") : (L.zh ? "查看全部" : "View all"))
                    .font(MenuSurface.font(size: 9))
                Image(systemName: "chevron.right").font(MenuSurface.font(size: 9))
            }
            .foregroundStyle(MenuSurface.accent)
        }
        .buttonStyle(.plain)
    }

    private func toolSourceDescription(for client: ToolUsageClient, snapshot: ToolUsageSnapshot?) -> String {
        switch snapshot?.evidence {
        case .server: return L.zh ? "账号用量自动同步" : "Account usage synced"
        case .imported: return L.zh ? "已导入的用量记录" : "Imported usage records"
        case .estimated: return L.zh ? "本机估算用量" : "Locally estimated usage"
        case .reported: return L.zh ? "本机记录读取" : "Local usage records"
        case nil: return L.zh ? "等待用量来源" : "Waiting for usage source"
        }
    }

    private func recentUsageRows(aggregate: UsageAggregate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self.sectionHeading(L.zh ? "近期记录" : "RECENT ACTIVITY")
                .padding(.top, 14)
            if aggregate.dailyEntries.isEmpty {
                Text(L.zh ? "所选时间范围内暂无记录" : "No records in this period")
                    .font(MenuSurface.font(size: 11))
                    .foregroundStyle(MenuSurface.muted)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(aggregate.dailyEntries.suffix(7).reversed())) { entry in
                    HStack {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(MenuSurface.muted)
                        Spacer()
                        Text(self.recentUsageValue(for: entry))
                            .foregroundStyle(MenuSurface.foreground)
                    }
                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { MenuSurface.line.frame(height: 1) }
                }
            }
        }
    }

    private func recentUsageValue(for entry: UsageChartEntry) -> String {
        if self.selectedUsageMetric == .tokens {
            return "\(entry.tokens.formatted()) tokens"
        }
        if entry.costIsComplete == false && entry.knownCostUSD == 0 {
            return "—"
        }
        return (entry.costIsComplete ? "" : "≥") + self.currency(entry.knownCostUSD)
    }

    private func modelSelectionRow(currentModel: String) -> some View {
        HStack(spacing: 4) {
            self.compactSelectionMenu(
                title: ReserveModelPolicy.displayName(for: currentModel),
                accessibilityLabel: L.zh ? "模型" : "Model",
                options: self.store.routeModelOptions(currentModel: currentModel),
                currentValue: currentModel,
                titleForOption: ReserveModelPolicy.displayName(for:),
                fillsAvailableWidth: true
            ) { modelID in
                Task { await self.updateSelectedRouteModel(modelID) }
            }
            .frame(maxWidth: .infinity)
            .help(currentModel)

            let effectiveReasoningEffort = CodexBarGlobalSettings.compatibleReasoningEffort(
                self.store.config.global.reasoningEffort,
                for: currentModel,
                catalog: self.store.codexServiceTierCatalog
            )
            self.compactSelectionMenu(
                title: effectiveReasoningEffort,
                accessibilityLabel: L.zh ? "推理强度" : "Reasoning effort",
                options: CodexBarGlobalSettings.reasoningEffortOptions(
                    for: currentModel,
                    currentValue: effectiveReasoningEffort,
                    catalog: self.store.codexServiceTierCatalog
                ),
                currentValue: effectiveReasoningEffort
            ) { effort in
                Task { await self.updateSelectedReasoningEffort(effort) }
            }
            .layoutPriority(1)

            // 档位名单来自 Codex 的模型目录缓存，随后端能力自动变化。
            let effectiveServiceTier = CodexBarGlobalSettings.compatibleServiceTier(
                self.store.config.global.serviceTier,
                for: currentModel,
                catalog: self.store.codexServiceTierCatalog
            )
            self.compactSelectionMenu(
                title: effectiveServiceTier,
                accessibilityLabel: L.zh ? "服务档位" : "Service tier",
                options: self.store.serviceTierOptions(for: currentModel),
                currentValue: effectiveServiceTier
            ) { serviceTier in
                Task { await self.updateSelectedServiceTier(serviceTier) }
            }
            .layoutPriority(1)

            self.contextWindowMenu(currentModel: currentModel)
                .layoutPriority(1)
        }
        .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }

    private func contextWindowMenu(currentModel: String) -> some View {
        let catalogModel = self.store.codexServiceTierCatalog?.model(for: currentModel)
        let currentWindow = self.store.config.global.displayContextWindow(for: currentModel, catalog: self.store.codexServiceTierCatalog)
        let overrideWindow = self.store.config.global.contextWindowOverride(for: currentModel)
        let presetOptions = Array(Set(CodexBarGlobalSettings.presetContextWindows.filter { option in
            catalogModel?.maxContextWindow.map { option <= $0 } ?? true
        } + [catalogModel?.contextWindow, catalogModel?.maxContextWindow].compactMap { $0 })).sorted()
        var items = presetOptions.map { window in
            RouteSelectionMenuItem(
                id: String(window), title: self.formatContextWindow(window), isSelected: window == currentWindow
            ) {
                self.requestContextWindowUpdate(window, for: currentModel)
            }
        }
        items.append(.separator)
        items.append(RouteSelectionMenuItem(id: "custom", title: L.contextWindowCustomAction) {
            self.promptForCustomContextWindow(currentModel: currentModel)
        })
        if overrideWindow != nil {
            items.append(RouteSelectionMenuItem(id: "default", title: L.contextWindowUseModelDefaultAction) {
                Task { await self.updateSelectedContextWindow(nil, for: currentModel) }
            })
        }
        return RouteSelectionMenu(
            title: self.formatContextWindow(currentWindow),
            accessibilityLabel: L.zh ? "上下文窗口" : "Context window",
            items: items,
            compact: true
        )
        .fixedSize(horizontal: false, vertical: true)
        .help(L.contextWindowMenuHelp(currentModel))
    }

    private func compactSelectionMenu(
        title: String,
        accessibilityLabel: String,
        options: [String],
        currentValue: String,
        titleForOption: (String) -> String = { $0 },
        fillsAvailableWidth: Bool = false,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        RouteSelectionMenu(
            title: title,
            accessibilityLabel: accessibilityLabel,
            items: options.map { value in
                RouteSelectionMenuItem(id: value, title: titleForOption(value), isSelected: value == currentValue) {
                    onSelect(value)
                }
            },
            compact: true,
            fillsAvailableWidth: fillsAvailableWidth
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func selectPage(_ page: MenuPage) {
        self.selectedPage = page
        self.selectedUsageScope = .all
        self.sessionPageIndex = 0
    }

    private var refreshToolbarButton: some View {
        Button {
            Task { await self.refresh(origin: .manual, announceResult: true) }
        } label: {
            if self.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(MenuSurface.font(size: 12, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .frame(width: 26, height: 28)
        .foregroundStyle(MenuSurface.muted)
        .disabled(self.isRefreshing)
        .help(L.refreshUsage)
    }

    private var addManagementMenu: some View {
        Menu {
            Button {
                self.startOAuthLogin()
            } label: {
                Label(L.zh ? "添加 Codex 账号" : "Add Codex account", systemImage: "person.crop.circle.badge.plus")
            }
            Button {
                self.openAddProviderWindow()
            } label: {
                Label(L.zh ? "添加 Provider" : "Add provider", systemImage: "plus.circle")
            }
        } label: {
            Image(systemName: "plus")
                .font(MenuSurface.font(size: 13, weight: .semibold))
                .frame(width: 26, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(MenuSurface.muted)
        .accessibilityLabel(L.zh ? "添加账号或 Provider" : "Add account or provider")
        .accessibilityIdentifier("codexbar.login-openai.toolbar")
    }

    private var moreManagementMenu: some View {
        Menu {
            Button(L.exportOpenAICSVAction) { self.exportOpenAIAccountsCSV() }
            Button(L.importOpenAICSVAction) { self.importOpenAIAccountsCSV() }
            Divider()
            Button {
                switch L.languageOverride {
                case nil: L.languageOverride = true
                case true: L.languageOverride = false
                case false: L.languageOverride = nil
                }
                self.languageToggle.toggle()
            } label: {
                Text(L.zh ? "切换语言" : "Change language")
            }
            Divider()
            Button {
                AppLifecycleDiagnostics.shared.markTermination(reason: "quit_button")
                NSApplication.shared.terminate(nil)
            } label: {
                Label(L.zh ? "退出 Codexbar" : "Quit Codexbar", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(MenuSurface.font(size: 13, weight: .medium))
                .frame(width: 26, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(MenuSurface.muted)
        .accessibilityLabel(L.zh ? "更多操作" : "More actions")
        .accessibilityIdentifier(OpenAIAccountCSVToolbarUI.accessibilityIdentifier)
    }

    private var settingsToolbarButton: some View {
        Button(action: self.openSettingsWindow) {
            Image(systemName: "gearshape")
                .font(MenuSurface.font(size: 13, weight: .medium))
                .frame(width: 30, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(MenuSurface.muted)
        .help(L.settings)
        .accessibilityIdentifier("codexbar.header.settings")
    }

    private func updateAvailableBanner(availability: AppUpdateAvailability) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(MenuSurface.font(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L.menuUpdateAvailableTitle(availability.release.version))
                    .font(MenuSurface.font(size: 11, weight: .medium))
                Text(L.menuUpdateAvailableSubtitle(availability.currentVersion, availability.release.version))
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(L.menuUpdateAction) {
                Task { await self.updateCoordinator.handleToolbarAction() }
            }
            .disabled(self.updateCoordinator.isChecking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openAIAvailabilityBadge(title: String) -> some View {
        Text(title)
            .font(MenuSurface.font(size: 10))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(availableCount > 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
            .foregroundColor(availableCount > 0 ? .green : .red)
            .cornerRadius(4)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var openAIAccountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L.zh ? "CODEX 账号" : "CODEX ACCOUNTS")
                    .font(MenuSurface.font(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if let openAIAvailabilityBadgeTitle {
                    self.openAIAvailabilityBadge(title: openAIAvailabilityBadgeTitle)
                }

                Spacer(minLength: 8)

                self.moreManagementMenu

                Picker(
                    "",
                    selection: Binding(
                        get: { self.store.config.openAI.accountUsageMode },
                        set: { mode in
                            Task {
                                await self.setOpenAIAccountUsageMode(mode)
                            }
                        }
                    )
                ) {
                    ForEach(CodexBarOpenAIAccountUsageMode.allCases) { mode in
                        Text(mode.menuToggleTitle)
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("codexbar.openai-mode-picker")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)

            if let manualSwitchBanner {
                self.openAIStatusBanner(
                    manualSwitchBanner,
                    onAction: {
                        guard let result = self.lastOpenAIManualSwitchResult else { return }
                        Task {
                            await self.applyManualSwitchRecommendation(result)
                        }
                    },
                    onDismiss: {
                        self.lastOpenAIManualSwitchResult = nil
                    }
                )
            }

            if let resetCreditBanner {
                self.openAIStatusBanner(
                    resetCreditBanner,
                    onAction: {
                        if let soonest = RateLimitResetCreditPresentation.soonest(
                            from: self.store.accounts,
                            now: self.now,
                            preferences: self.preferences
                        ) {
                            self.beginResetCreditConfirmation(soonest)
                        }
                    }
                )
            }

            if let pendingResetCredit {
                self.resetCreditConfirmation(pendingResetCredit)
            } else if self.resetCreditItems.isEmpty == false {
                self.resetCreditsSection(self.resetCreditItems)
            } else if self.resetCreditTotalAvailableCount > 0 {
                // 有数量但拿不到（或无 expiresAt）可展示的卡：不能整个隐掉，提示用户存在但缺详情。
                self.resetCreditsMissingDetailNotice(count: self.resetCreditTotalAvailableCount)
            }

            if !self.store.accounts.isEmpty,
               self.store.config.openAI.showsQuotaWindowStart || runtimeRouteBanner?.actionTitle != nil {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if self.store.config.openAI.showsQuotaWindowStart {
                        if self.isAligningQuota {
                            ProgressView().controlSize(.mini)
                        }
                        Button {
                            Task { await self.alignQuotaWindows() }
                        } label: {
                            Text(self.alignQuotaRowTitle).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .font(MenuSurface.font(size: 10, weight: .medium))
                        .foregroundStyle(self.alignQuotaRowColor)
                        .disabled(self.isAligningQuota)
                        .help(L.alignQuotaHint)
                        .accessibilityIdentifier("codexbar.align-quota-button")
                    }
                    if let runtimeRouteBanner, let actionTitle = runtimeRouteBanner.actionTitle {
                        Button(actionTitle) {
                            self.clearStaleAggregateStickyIfNeeded()
                        }
                        .buttonStyle(.borderless)
                        .font(MenuSurface.font(size: 10, weight: .medium))
                        .foregroundColor(runtimeRouteBanner.tone == .warning ? .orange : .secondary)
                        .help(L.aggregateRuntimeClearStaleStickyHint)
                    }
                }
                .padding(.horizontal, 10)
            }

            if store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.zh ? "还没有 Codex 账号" : "No Codex account added")
                        .font(MenuSurface.font(size: 11, weight: .medium))
                    Text(L.zh ? "使用顶部加号添加 OpenAI OAuth 账号" : "Use the plus button above to add an OpenAI OAuth account")
                        .font(MenuSurface.font(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MenuSurface.raised)
                )
            } else {
                openAIAccountGroupsView(groupedAccounts)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var providersSection: some View {
        let openRouterProvider = self.visibleOpenRouterProvider
        let providerCount = store.customProviders.count + (openRouterProvider == nil ? 0 : 1)

        if providerCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isProvidersExpanded.toggle()
                    requestStatusItemLayoutRefresh()
                    DispatchQueue.main.async {
                        self.requestStatusItemLayoutRefresh()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(L.zh ? "第三方中转站" : "THIRD-PARTY PROVIDERS")
                            .font(MenuSurface.font(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)

                        Spacer()

                        Text("\(providerCount)")
                            .font(MenuSurface.font(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        Image(systemName: "chevron.right")
                            .font(MenuSurface.font(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isProvidersExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.12), value: isProvidersExpanded)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isProvidersExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.customProviders) { provider in
                            CompatibleProviderRowView(
                                provider: provider,
                                isActiveProvider: store.activeProvider?.id == provider.id,
                                activeAccountId: provider.activeAccountId
                            ) { account in
                                Task {
                                    await activateCompatibleProvider(
                                        providerID: provider.id,
                                        accountID: account.id
                                    )
                                }
                            } onAddAccount: {
                                openAddProviderAccountWindow(provider: provider)
                            } onDeleteAccount: { account in
                                deleteCompatibleAccount(providerID: provider.id, accountID: account.id)
                            } onDeleteProvider: {
                                deleteProvider(providerID: provider.id)
                            } onReviewCompatibility: {
                                _ = self.reviewLegacyProviderCompatibility(providerID: provider.id)
                            }
                        }

                        if let provider = openRouterProvider {
                            OpenRouterProviderRowView(
                                provider: provider,
                                isActiveProvider: store.activeProvider?.id == provider.id,
                                activeAccountId: provider.activeAccountId
                            ) { account in
                                Task {
                                    await activateOpenRouterProvider(accountID: account.id)
                                }
                            } onSelectModel: { modelID in
                                Task {
                                    await selectOpenRouterModel(modelID)
                                }
                            } onAddAccount: {
                                openAddOpenRouterAccountWindow(provider: provider)
                            } onEditModel: {
                                openEditOpenRouterWindow(provider: provider)
                            } onDeleteAccount: { account in
                                deleteOpenRouterAccount(accountID: account.id)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func openAIAccountGroupsView(_ groups: [OpenAIAccountGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    if let copyableEmail = OpenAIAccountPresentation.copyableAccountGroupEmail(group.email) {
                        Button {
                            self.copyOpenAIAccountGroupEmail(copyableEmail)
                        } label: {
                            self.openAIAccountGroupHeaderLabel(group)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    } else {
                        self.openAIAccountGroupHeaderLabel(group)
                    }

                    ForEach(group.accounts) { account in
                        let rowState = OpenAIAccountPresentation.rowState(
                            for: account,
                            summary: self.runningThreadSummary,
                            accountUsageMode: self.store.config.openAI.accountUsageMode
                        )
                        AccountRowView(
                            account: account,
                            accountLabel: account.displayIdentifier,
                            accountDetail: self.accountDetail(account, isSharedGroup: group.accounts.count > 1),
                            rowState: rowState,
                            isRefreshing: refreshingAccounts.contains(account.id),
                            usageDisplayMode: self.store.config.openAI.usageDisplayMode,
                            defaultManualActivationBehavior: self.store.config.openAI.manualActivationBehavior,
                            onActivate: { trigger in
                                Task { await activateAccount(account, trigger: trigger) }
                            },
                            onRefresh: { Task { await refreshAccount(account, announceResult: true) } },
                            onReauth: { reauthAccount(account) },
                            onDelete: { store.remove(account) },
                            showsQuotaDetails: true,
                            now: self.now
                        )
                    }
                }
            }
        }
    }

    private func openAIAccountGroupHeaderLabel(_ group: OpenAIAccountGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(group.representativeAccount.map(self.accountIdentity) ?? self.privacyLabel(group.email))
                .font(MenuSurface.font(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(MenuSurface.foreground.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if let copiedConfirmation = OpenAIAccountPresentation.accountGroupCopyConfirmationText(
                groupEmail: group.email,
                copiedEmail: self.copiedOpenAIAccountGroupEmail
            ) {
                Text(copiedConfirmation)
                    .font(MenuSurface.font(size: 9, weight: .medium))
                    .foregroundColor(.green)
                    .lineLimit(1)
            } else if let remark = group.headerQuotaRemark(now: now) {
                Text(remark)
                    .font(MenuSurface.font(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
    }

    private func resetCreditsSection(_ items: [RateLimitResetCreditItem]) -> some View {
        let collapsed = RateLimitResetCreditPresentation.collapsedItems(items)
        let canExpand = RateLimitResetCreditPresentation.canExpand(items)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L.resetCreditsSectionTitle)
                    .font(MenuSurface.font(size: 11, weight: .medium))
                Text(L.resetCreditCount(items.count))
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                if let soonest = items.first {
                    Button(L.resetCreditUseSoonest) {
                        self.beginResetCreditConfirmation(soonest)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(MenuSurface.font(size: 10, weight: .medium))
                }
                if canExpand {
                    Button {
                        self.isResetCreditsExpanded.toggle()
                        self.requestStatusItemLayoutRefresh()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(MenuSurface.font(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(self.isResetCreditsExpanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(L.resetCreditShowAllHint)
                }
            }

            ForEach(self.isResetCreditsExpanded ? items : collapsed) { item in
                ResetCreditItemRow(item: item, now: self.now) {
                    self.beginResetCreditConfirmation(item)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(MenuSurface.raised)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MenuSurface.line, lineWidth: 1))
    }

    private func resetCreditsMissingDetailNotice(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(MenuSurface.font(size: 10, weight: .semibold))
                .foregroundColor(.orange)
            Text(L.resetCreditMissingDetails(count))
                .font(MenuSurface.font(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(MenuSurface.raised)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MenuSurface.line, lineWidth: 1))
    }

    private func resetCreditConfirmation(_ item: RateLimitResetCreditItem) -> some View {
        var displayedItem = item
        if let account = self.store.oauthAccount(accountID: item.accountId) {
            displayedItem.accountLabel = self.accountIdentity(account)
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(L.resetCreditConfirm)
                .font(MenuSurface.font(size: 11, weight: .medium))
            Text(
                RateLimitResetCreditPresentation.confirmMessage(
                    for: displayedItem,
                    now: self.now
                )
            )
            .font(MenuSurface.font(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if item.hasMostlyUnusedWindows() {
                Text(L.resetCreditEmptyWindowWarning)
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(L.resetCreditCancel) {
                    self.pendingResetCredit = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(self.isConsumingResetCredit)

                Button(L.resetCreditConfirm) {
                    Task { await self.consumeResetCredit(item) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(self.isConsumingResetCredit)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(MenuSurface.raised)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 0.8)
        }
    }

    private func openAIStatusBanner(
        _ banner: OpenAIStatusBannerPresentation,
        onAction: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        let accentColor: Color = banner.tone == .warning ? .orange : MenuSurface.accent
        let iconName = banner.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(MenuSurface.font(size: 12, weight: .semibold))
                .foregroundColor(accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(MenuSurface.font(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Text(banner.message)
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = banner.actionTitle,
                   let onAction {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(MenuSurface.font(size: 10, weight: .medium))
                }
            }

            Spacer(minLength: 4)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(MenuSurface.font(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(MenuSurface.raised)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accentColor.opacity(0.16), lineWidth: 0.8)
        }
    }

    private func copyOpenAIAccountGroupEmail(_ email: String) {
        guard let copiedEmail = OpenAIAccountGroupEmailCopyAction.perform(email: email) else {
            return
        }

        self.copiedOpenAIAccountGroupEmail = copiedEmail
        self.pendingCopiedOpenAIAccountGroupEmailHide?.cancel()
        let hideWorkItem = DispatchWorkItem {
            self.copiedOpenAIAccountGroupEmail = nil
            self.pendingCopiedOpenAIAccountGroupEmailHide = nil
        }
        self.pendingCopiedOpenAIAccountGroupEmailHide = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hideWorkItem)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return L.justUpdated }
        if seconds < 3600 { return L.minutesAgo(seconds / 60) }
        return L.hoursAgo(seconds / 3600)
    }

    private func accountIdentity(_ account: TokenAccount) -> String {
        OpenAIAccountPresentation.identityLabel(for: account, preferences: self.preferences)
    }

    private func accountDetail(_ account: TokenAccount, isSharedGroup: Bool) -> String? {
        if let organization = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !organization.isEmpty, organization != self.accountIdentity(account),
           !(self.preferences.hideAccountEmail && organization.contains("@")) {
            return organization
        }
        guard isSharedGroup, !account.accountId.isEmpty, !account.accountId.contains("@") else { return nil }
        return "…" + account.accountId.suffix(6)
    }

    private func privacyLabel(_ value: String) -> String {
        guard self.preferences.hideAccountEmail, value.contains("@") else { return value }
        return L.zh ? "账户已隐藏" : "Account hidden"
    }

    private func currency(_ value: Double) -> String { MenuSurface.currency(value) }

    private func compactTokens(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 {
            return String(format: "%.2fB", number / 1_000_000_000)
        }
        if number >= 1_000_000 {
            return String(format: "%.2fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
    }

    private func formatContextWindow(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: value % 1_000_000 == 0 ? "%.0fM" : "%.2fM", Double(value) / 1_000_000)
        }
        if value >= 1_000, value % 1_000 == 0 {
            return "\(value / 1_000)k"
        }
        return "\(value)"
    }

    private func parseContextWindowInput(_ value: String) -> Int? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ",", with: "")
            .lowercased()
        guard normalized.isEmpty == false else { return nil }

        let multiplier: Double
        let numericPart: String
        if normalized.hasSuffix("k") {
            multiplier = 1_000
            numericPart = String(normalized.dropLast())
        } else if normalized.hasSuffix("m") {
            multiplier = 1_000_000
            numericPart = String(normalized.dropLast())
        } else {
            multiplier = 1
            numericPart = normalized
        }

        guard let number = Double(numericPart),
              number.isFinite,
              number > 0 else {
            return nil
        }
        let result = Int((number * multiplier).rounded())
        return CodexBarGlobalSettings.normalizedModelContextWindow(result)
    }

    private func promptForCustomContextWindow(currentModel: String) {
        let alert = NSAlert()
        alert.messageText = L.contextWindowCustomTitle
        alert.informativeText = L.contextWindowCustomMessage(currentModel)
        alert.addButton(withTitle: L.save)
        alert.addButton(withTitle: L.cancel)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = self.formatContextWindow(CodexBarGlobalSettings.defaultContextWindow(for: currentModel, catalog: self.store.codexServiceTierCatalog))
        input.stringValue = self.formatContextWindow(
            self.store.config.global.displayContextWindow(for: currentModel, catalog: self.store.codexServiceTierCatalog)
        )
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let contextWindow = self.parseContextWindowInput(input.stringValue) else {
            self.showInvalidContextWindowAlert()
            return
        }
        self.requestContextWindowUpdate(contextWindow, for: currentModel)
    }

    private func requestContextWindowUpdate(_ contextWindow: Int, for modelID: String) {
        if let maxWindow = self.store.codexServiceTierCatalog?.model(for: modelID)?.maxContextWindow,
           contextWindow > maxWindow {
            self.showInvalidContextWindowAlert()
            return
        }
        guard self.confirmLargeContextWindowIfNeeded(contextWindow, modelID: modelID) else { return }
        Task { await self.updateSelectedContextWindow(contextWindow, for: modelID) }
    }

    private func confirmLargeContextWindowIfNeeded(_ contextWindow: Int, modelID: String) -> Bool {
        let defaultWindow = CodexBarGlobalSettings.defaultContextWindow(for: modelID, catalog: self.store.codexServiceTierCatalog)
        guard contextWindow > defaultWindow else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.contextWindowLargeConfirmationTitle
        alert.informativeText = L.contextWindowLargeConfirmationMessage(
            modelID,
            self.formatContextWindow(contextWindow),
            self.formatContextWindow(defaultWindow)
        )
        alert.addButton(withTitle: L.contextWindowLargeConfirmationConfirm)
        alert.addButton(withTitle: L.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showInvalidContextWindowAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.contextWindowInvalidTitle
        alert.informativeText = L.contextWindowInvalidMessage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func shortDay(_ date: Date) -> String {
        Self.shortDayFormatter.string(from: date)
    }

    private func reportMeasuredMenuHeight(_ height: CGFloat) {
        let roundedHeight = height.rounded()
        NotificationCenter.default.post(
            name: .codexbarStatusItemMeasuredHeightDidChange,
            object: nil,
            userInfo: ["height": roundedHeight]
        )
    }

    private func requestStatusItemLayoutRefresh() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .codexbarRequestStatusItemLayoutRefresh,
                object: nil
            )
        }
    }

    private func resolveCostSummaryAnchor(_ view: NSView) {
        if self.costSummaryAnchorView !== view {
            self.costSummaryAnchorView = view
        }
        guard isCostPanelPresented else { return }
        showCostPanel()
    }

    private func setCostSummaryHover(_ hovering: Bool) {
        isCostSummaryHovered = hovering
        if hovering {
            presentCostPanel()
        } else {
            scheduleCostPanelHideIfNeeded()
        }
    }

    private func setCostPanelHover(_ hovering: Bool) {
        isCostPanelHovered = hovering
        if hovering {
            presentCostPanel()
        } else {
            scheduleCostPanelHideIfNeeded()
        }
    }

    private func presentCostPanel() {
        pendingCostHide?.cancel()
        pendingCostHide = nil
        isCostPanelPresented = true
        showCostPanel()
    }

    private func scheduleCostPanelHideIfNeeded() {
        pendingCostHide?.cancel()
        let work = DispatchWorkItem {
            if !isCostSummaryHovered && !isCostPanelHovered {
                isCostPanelPresented = false
                DetachedWindowPresenter.shared.close(id: costPanelID)
            }
        }
        pendingCostHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func showCostPanel() {
        guard let anchorView = costSummaryAnchorView,
              let window = anchorView.window else { return }

        let frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = window.convertToScreen(frameInWindow)
        let selectedUsage = UsagePresentation.aggregate(
            codex: store.localCostSummary,
            external: toolUsageStore.displaySnapshots,
            scope: self.selectedUsageScope,
            period: self.selectedUsagePeriod,
            now: self.now,
            calendar: .current
        )
        let chartEntries = UsagePresentation.chartEntries(
            aggregate: selectedUsage,
            period: self.selectedUsagePeriod,
            now: self.now,
            calendar: .current
        )
        let hasChartValues = self.selectedUsageMetric == .tokens
            ? chartEntries.contains { $0.tokens > 0 }
            : chartEntries.contains { $0.knownCostUSD > 0 }
        let panelSize = CGSize(
            width: CostDetailsPanelView.panelWidth,
            height: CostDetailsPanelView.panelHeight(hasHistory: hasChartValues)
        )
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorFrame) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let spacing: CGFloat = 12
        let margin: CGFloat = 8

        var originX = anchorFrame.maxX + spacing
        if originX + panelSize.width > visibleFrame.maxX - margin {
            originX = anchorFrame.minX - spacing - panelSize.width
        }
        originX = min(max(originX, visibleFrame.minX + margin), visibleFrame.maxX - panelSize.width - margin)

        var originY = anchorFrame.maxY - panelSize.height
        originY = min(max(originY, visibleFrame.minY + margin), visibleFrame.maxY - panelSize.height - margin)

        DetachedWindowPresenter.shared.showHoverPanel(
            id: costPanelID,
            size: panelSize,
            origin: CGPoint(x: originX, y: originY)
        ) {
            CostDetailsPanelView(
                summary: store.localCostSummary,
                externalUsage: toolUsageStore.displaySnapshots,
                refreshState: store.localCostRefreshState,
                scope: self.selectedUsageScope,
                period: self.selectedUsagePeriod,
                metric: self.selectedUsageMetric,
                currency: currency,
                compactTokens: compactTokens,
                shortDay: shortDay,
                now: now
            )
            .onHover { hovering in
                setCostPanelHover(hovering)
            }
        }
    }

    private func beginResetCreditConfirmation(_ item: RateLimitResetCreditItem) {
        self.closeResetCreditsPanel()
        self.pendingResetCredit = item
    }

    private func resolveResetCreditsAnchor(_ view: NSView) {
        if self.resetCreditsAnchorView !== view {
            self.resetCreditsAnchorView = view
        }
        guard self.isResetCreditsPanelPresented else { return }
        self.showResetCreditsPanel()
    }

    private func setResetCreditsHover(_ hovering: Bool) {
        self.isResetCreditsHovered = hovering
        if hovering {
            self.presentResetCreditsPanel()
        } else {
            self.scheduleResetCreditsPanelHideIfNeeded()
        }
    }

    private func setResetCreditsPanelHover(_ hovering: Bool) {
        self.isResetCreditsPanelHovered = hovering
        if hovering {
            self.presentResetCreditsPanel()
        } else {
            self.scheduleResetCreditsPanelHideIfNeeded()
        }
    }

    private func toggleResetCreditsPanelPinned() {
        if self.isResetCreditsPanelPinned {
            self.isResetCreditsPanelPinned = false
            if self.isResetCreditsHovered == false && self.isResetCreditsPanelHovered == false {
                self.closeResetCreditsPanel()
            }
            return
        }
        self.isResetCreditsPanelPinned = true
        self.presentResetCreditsPanel()
    }

    private func presentResetCreditsPanel() {
        guard RateLimitResetCreditPresentation.canExpand(self.resetCreditItems) else {
            self.closeResetCreditsPanel()
            return
        }
        self.pendingResetCreditsHide?.cancel()
        self.pendingResetCreditsHide = nil
        self.isResetCreditsPanelPresented = true
        self.showResetCreditsPanel()
    }

    private func scheduleResetCreditsPanelHideIfNeeded() {
        guard self.isResetCreditsPanelPinned == false else { return }
        self.pendingResetCreditsHide?.cancel()
        let work = DispatchWorkItem {
            if self.isResetCreditsPanelPinned == false,
               self.isResetCreditsHovered == false,
               self.isResetCreditsPanelHovered == false {
                self.closeResetCreditsPanel()
            }
        }
        self.pendingResetCreditsHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func closeResetCreditsPanel() {
        self.pendingResetCreditsHide?.cancel()
        self.pendingResetCreditsHide = nil
        self.isResetCreditsPanelPresented = false
        self.isResetCreditsHovered = false
        self.isResetCreditsPanelHovered = false
        self.isResetCreditsPanelPinned = false
        DetachedWindowPresenter.shared.close(id: self.resetCreditsPanelID)
    }

    private func syncResetCreditsPanelAfterItemsChange() {
        guard self.isResetCreditsPanelPresented else { return }
        if RateLimitResetCreditPresentation.canExpand(self.resetCreditItems) {
            self.showResetCreditsPanel()
        } else {
            self.closeResetCreditsPanel()
        }
    }

    private func showResetCreditsPanel() {
        guard self.isResetCreditsPanelPresented,
              RateLimitResetCreditPresentation.canExpand(self.resetCreditItems),
              let anchorView = self.resetCreditsAnchorView,
              let window = anchorView.window else { return }

        let items = self.resetCreditItems
        let frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = window.convertToScreen(frameInWindow)
        let panelSize = CGSize(
            width: ResetCreditsPanelView.panelWidth,
            height: ResetCreditsPanelView.panelHeight(itemCount: items.count)
        )
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorFrame) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let spacing: CGFloat = 12
        let margin: CGFloat = 8

        var originX = anchorFrame.maxX + spacing
        if originX + panelSize.width > visibleFrame.maxX - margin {
            originX = anchorFrame.minX - spacing - panelSize.width
        }
        originX = min(max(originX, visibleFrame.minX + margin), visibleFrame.maxX - panelSize.width - margin)

        var originY = anchorFrame.maxY - panelSize.height
        originY = min(max(originY, visibleFrame.minY + margin), visibleFrame.maxY - panelSize.height - margin)

        DetachedWindowPresenter.shared.showHoverPanel(
            id: self.resetCreditsPanelID,
            size: panelSize,
            origin: CGPoint(x: originX, y: originY)
        ) {
            ResetCreditsPanelView(
                items: items,
                now: self.now,
                onUse: { item in
                    self.beginResetCreditConfirmation(item)
                }
            )
            .onHover { hovering in
                self.setResetCreditsPanelHover(hovering)
            }
        }
    }

    private func activateAccount(
        _ account: TokenAccount,
        trigger: OpenAIManualActivationTrigger = .primaryTap
    ) async {
        do {
            let result = try await OpenAIManualActivationExecutor.execute(
                targetAccountID: account.accountId,
                targetMode: .switchAccount,
                configuredBehavior: self.store.config.openAI.manualActivationBehavior,
                trigger: trigger
            ) {
                try self.store.activate(
                    account,
                    reason: .manual,
                    automatic: false,
                    forced: false,
                    protectedByManualGrace: false
                )
            } launchNewInstance: {
                try self.store.activate(
                    account,
                    reason: .manual,
                    automatic: false,
                    forced: false,
                    protectedByManualGrace: false
                )
            }

            self.lastOpenAIManualSwitchResult = result
            self.refreshRunningThreadAttribution()
            self.clearError()
            Task { @MainActor in
                OpenAIUsagePollingService.shared.refreshNow()
            }
        } catch {
            self.lastOpenAIManualSwitchResult = nil
            self.setGenericError(error.localizedDescription)
        }
    }

    private func activateCompatibleProvider(providerID: String, accountID: String) async {
        guard self.reviewLegacyProviderCompatibility(providerID: providerID) else { return }
        let previousActiveProviderID = self.store.config.active.providerId
        let previousActiveAccountID = self.store.config.active.accountId

        do {
            try await CompatibleProviderUseExecutor.execute(
                configuredBehavior: self.store.config.openAI.manualActivationBehavior
            ) {
                try self.store.activateCustomProvider(
                    providerID: providerID,
                    accountID: accountID
                )
            } restorePreviousSelection: {
                try self.store.restoreActiveSelection(
                    activeProviderID: previousActiveProviderID,
                    activeAccountID: previousActiveAccountID
                )
            } launchNewInstance: {
                try self.store.activateCustomProvider(
                    providerID: providerID,
                    accountID: accountID
                )
            }

            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func activateOpenRouterProvider(accountID: String) async {
        let previousActiveProviderID = self.store.config.active.providerId
        let previousActiveAccountID = self.store.config.active.accountId

        do {
            try await CompatibleProviderUseExecutor.execute(
                configuredBehavior: self.store.config.openAI.manualActivationBehavior
            ) {
                try self.store.activateOpenRouterProvider(accountID: accountID)
            } restorePreviousSelection: {
                try self.store.restoreActiveSelection(
                    activeProviderID: previousActiveProviderID,
                    activeAccountID: previousActiveAccountID
                )
            } launchNewInstance: {
                try self.store.activateOpenRouterProvider(accountID: accountID)
            }

            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func selectOpenRouterModel(_ modelID: String) async {
        do {
            try self.store.updateOpenRouterSelectedModel(modelID)
            if let provider = self.store.openRouterProvider,
               self.store.activeProvider?.id != provider.id,
               let accountID = provider.activeAccountId {
                await self.activateOpenRouterProvider(accountID: accountID)
                return
            }
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func updateSelectedRouteModel(_ modelID: String) async {
        do {
            try self.store.updateRouteModel(modelID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func updateSelectedReasoningEffort(_ effort: String) async {
        do {
            try self.store.updateReasoningEffort(effort)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func updateSelectedServiceTier(_ serviceTier: String) async {
        do {
            try self.store.updateServiceTier(serviceTier)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func updateSelectedContextWindow(_ contextWindow: Int?, for modelID: String) async {
        do {
            try self.store.updateModelContextWindow(contextWindow, for: modelID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func setOpenAIAccountUsageMode(_ mode: CodexBarOpenAIAccountUsageMode) async {
        let previousMode = self.store.config.openAI.accountUsageMode
        let previousActiveProviderID = self.store.config.active.providerId
        let previousActiveAccountID = self.store.config.active.accountId

        do {
            _ = try await OpenAIAccountUsageModeTransitionExecutor.execute(
                configuredBehavior: self.store.config.openAI.manualActivationBehavior,
                targetMode: mode,
                currentMode: previousMode,
                applyMode: {
                    try self.store.updateOpenAIAccountUsageMode(mode)
                },
                rollbackMode: {
                    try self.store.restoreOpenAIAccountUsageMode(
                        previousMode,
                        activeProviderID: previousActiveProviderID,
                        activeAccountID: previousActiveAccountID
                    )
                },
                launchNewInstance: {
                    try self.store.updateOpenAIAccountUsageMode(mode)
                }
            )
            self.lastOpenAIManualSwitchResult = nil
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func applyManualSwitchRecommendation(
        _ result: OpenAIManualSwitchResult
    ) async {
        _ = result
    }

    private func clearStaleAggregateStickyIfNeeded() {
        let snapshot = self.openAIRuntimeRouteSnapshot
        guard self.store.clearStaleAggregateSticky(using: snapshot) else { return }
        self.clearError()
        self.refreshRunningThreadAttribution()
    }

    private func activeProviderSummaryTitle(
        activeProvider: CodexBarProvider,
        activeAccount: CodexBarProviderAccount
    ) -> String {
        if activeProvider.kind == .openAIOAuth &&
            self.store.config.openAI.accountUsageMode == .aggregateGateway {
            let routedAccount = self.store.aggregateRoutedAccount ??
                activeAccount.asTokenAccount(isActive: false)
            return OpenAIAccountPresentation.aggregateSummaryTitle(
                providerLabel: activeProvider.label,
                routedAccount: routedAccount,
                usageDisplayMode: self.store.config.openAI.usageDisplayMode
            )
        }
        return "\(activeProvider.label) · \(activeAccount.label)"
    }

    private func deleteCompatibleAccount(providerID: String, accountID: String) {
        do {
            try store.removeCustomProviderAccount(providerID: providerID, accountID: accountID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func deleteProvider(providerID: String) {
        do {
            try store.removeCustomProvider(providerID: providerID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func deleteOpenRouterAccount(accountID: String) {
        do {
            try store.removeOpenRouterProviderAccount(accountID: accountID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func startOAuthLogin() {
        self.requestCloseStatusItemMenu()
        OpenAILoginCoordinator.shared.start()
    }

    private func exportOpenAIAccountsCSV() {
        do {
            let snapshot = try self.oauthAccountService.exportAccountsForInterchange()
            guard snapshot.accounts.isEmpty == false else {
                self.setGenericError(L.noOpenAIAccountsToExport)
                return
            }

            guard let exportURL = self.openAIAccountCSVPanelService.requestExportURL() else {
                return
            }

            let exportText = try self.openAIAccountCSVService.makeCSV(
                from: snapshot.accounts,
                metadataByAccountID: snapshot.metadataByAccountID,
                proxiesJSON: snapshot.proxiesJSON
            )
            try exportText.write(to: exportURL, atomically: true, encoding: .utf8)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func importOpenAIAccountsCSV() {
        do {
            guard let importURL = self.openAIAccountCSVPanelService.requestImportURL() else {
                return
            }

            let importText = try String(contentsOf: importURL, encoding: .utf8)
            let parsed = try self.openAIAccountCSVService.parseCSV(importText)
            let result = try self.oauthAccountService.importAccounts(
                parsed.accounts,
                activeAccountID: parsed.activeAccountID,
                interopContext: parsed.interopContext
            )

            self.store.load()
            self.refreshRunningThreadAttribution()
            self.clearError()
            self.refreshImportedAccounts(accountIDs: result.importedAccountIDs)
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func importCursorUsageCSV() {
        let panel = NSOpenPanel()
        panel.title = L.zh ? "导入 Cursor 用量" : "Import Cursor Usage"
        panel.prompt = L.zh ? "导入" : "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK,
              let url = panel.url else { return }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let snapshot = try CursorUsageCSVImporter().parse(text)
            if CursorAccountStore.shared.selectedAccountID == nil {
                self.setGenericError(L.zh ? "请先在 Cursor 账号管理中连接并选择账号，再导入属于该账号的 CSV。"
                    : "Connect and select a Cursor account before importing its CSV.")
                return
            }
            self.toolUsageStore.updateImportedCursor(snapshot)
            self.showToolUsage(.cursor)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func openSettingsWindow() {
        self.requestCloseStatusItemMenu()
        CodexBarSettingsWindowPresenter.open(
            store: self.store
        )
    }

    private func showToolManagement(_ client: ToolUsageClient) {
        self.selectPage(.limits)
        self.preferencesStore.setManagementToolCollapsed(client.rawValue, collapsed: false)
        self.requestStatusItemLayoutRefresh()
    }

    private func openAddProviderWindow(defaultPreset: AddProviderPreset = .preset) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider",
            title: "Add Provider",
            size: CGSize(width: 520, height: 620)
        ) {
            AddProviderSheet(store: store, defaultPreset: defaultPreset) { result in
                guard self.confirmDeepSeekCompatibility(presetID: result.presetID, baseURL: result.baseURL) else { return }
                do {
                    if let openRouterSelection = result.openRouterSelection {
                        try store.addOpenRouterProvider(
                            apiKey: openRouterSelection.apiKey,
                            selectedModelID: openRouterSelection.selectedModelID,
                            pinnedModelIDs: openRouterSelection.pinnedModelIDs,
                            cachedModelCatalog: openRouterSelection.cachedModelCatalog,
                            fetchedAt: openRouterSelection.fetchedAt
                        )
                    } else {
                        try store.addCompatibleProvider(
                            label: result.label,
                            baseURL: result.baseURL,
                            accountLabel: result.accountLabel,
                            apiKey: result.apiKey,
                            wireAPI: result.wireAPI,
                            presetID: result.presetID,
                            model: result.model,
                            modelCatalog: result.modelCatalog
                        )
                    }
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-provider")
                    self.showProviderCompatibilityNoticeIfNeeded(wireAPI: result.wireAPI)
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider")
            }
        }
    }

    private func openAddProviderAccountWindow(provider: CodexBarProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider-account-\(provider.id)",
            title: "Add Account",
            size: CGSize(width: 400, height: 220)
        ) {
            AddProviderAccountSheet(provider: provider) { label, apiKey in
                guard self.confirmDeepSeekCompatibility(presetID: provider.presetID, baseURL: provider.baseURL ?? "") else { return }
                do {
                    try store.addCustomProviderAccount(providerID: provider.id, label: label, apiKey: apiKey)
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
                    self.showProviderCompatibilityNoticeIfNeeded(wireAPI: provider.wireAPI)
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
            }
        }
    }

    private func confirmDeepSeekCompatibility(presetID: String?, baseURL: String) -> Bool {
        guard CodexBarProviderCompatibility.isDeepSeek(presetID: presetID, baseURL: baseURL) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.providerDeepSeekCompatibilityTitle
        alert.informativeText = L.providerDeepSeekCompatibilityMessage
        alert.addButton(withTitle: L.providerSaveWithLimitations)
        alert.addButton(withTitle: L.providerReturnToEdit)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func reviewLegacyProviderCompatibility(providerID: String) -> Bool {
        guard let provider = self.store.customProviders.first(where: { $0.id == providerID }) else { return false }
        guard provider.usesChatCompletionsGateway else { return true }
        self.requestCloseStatusItemMenu()
        let alert = NSAlert()
        alert.alertStyle = .informational
        if let migration = CodexBarProviderResponsesMigration.proposal(for: provider) {
            alert.messageText = L.providerMigrationTitle
            alert.informativeText = L.providerMigrationMessage(
                provider.label, provider.baseURL ?? "", migration.baseURL,
                provider.compatibleEffectiveModelID ?? "—", migration.modelID
            )
            if CodexBarProviderCompatibility.isDeepSeek(presetID: provider.presetID, baseURL: provider.baseURL ?? "") {
                alert.informativeText += "\n\n" + L.providerDeepSeekCompatibilityMessage
            }
            alert.addButton(withTitle: L.providerMigrateToResponses)
            alert.addButton(withTitle: L.providerKeepCurrentConfiguration)
            alert.addButton(withTitle: L.cancel)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try self.store.migrateProviderToResponses(providerID: providerID)
                    self.clearError()
                    return true
                } catch {
                    self.setGenericError(error.localizedDescription)
                    return false
                }
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
        alert.messageText = L.providerChatModeTitle
        alert.informativeText = L.providerChatCompatibilityMessage + "\n\n" + L.providerLegacyNoticeMessage
        alert.addButton(withTitle: L.providerKeepCurrentConfiguration)
        alert.addButton(withTitle: L.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showLegacyProviderNoticeIfNeeded() {
        let noticeKey = "codexbar.legacyChatProviderNotice.v1"
        guard self.store.customProviders.contains(where: { $0.usesChatCompletionsGateway }),
              UserDefaults.standard.bool(forKey: noticeKey) == false else { return }
        UserDefaults.standard.set(true, forKey: noticeKey)
        DispatchQueue.main.async {
            self.requestCloseStatusItemMenu()
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L.providerLegacyNoticeTitle
            alert.informativeText = L.providerLegacyNoticeMessage
            alert.addButton(withTitle: L.providerChatCompatibilityDismiss)
            alert.runModal()
        }
    }

    private func showProviderCompatibilityNoticeIfNeeded(wireAPI: CodexBarWireAPI) {
        guard wireAPI == .chat else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.providerChatCompatibilityTitle
        alert.informativeText = L.providerChatCompatibilityMessage
        alert.addButton(withTitle: L.providerChatCompatibilityDismiss)
        alert.runModal()
    }

    private func openAddOpenRouterAccountWindow(provider: CodexBarProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-openrouter-account",
            title: "Add OpenRouter Account",
            size: CGSize(width: 520, height: 620)
        ) {
            AddOpenRouterAccountSheet(provider: provider, store: store) { selection in
                do {
                    try store.addOpenRouterProviderAccount(
                        apiKey: selection.apiKey,
                        selectedModelID: selection.selectedModelID,
                        pinnedModelIDs: selection.pinnedModelIDs,
                        cachedModelCatalog: selection.cachedModelCatalog,
                        fetchedAt: selection.fetchedAt
                    )
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-openrouter-account")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-openrouter-account")
            }
        }
    }

    private func openEditOpenRouterWindow(provider: CodexBarProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "edit-openrouter-model",
            title: "OpenRouter Models",
            size: CGSize(width: 480, height: 460)
        ) {
            EditOpenRouterModelSheet(
                provider: provider,
                store: store
            ) { message in
                self.setGenericError(message)
            } onClose: {
                DetachedWindowPresenter.shared.close(id: "edit-openrouter-model")
            }
        }
    }

    private func handleMenuPresentationOpened() {
        self.toolUsageStore.refreshIfNeeded()
        countdownTimerConnection?.cancel()
        countdownTimerConnection = countdownTimer.connect()
        runningThreadTimerConnection?.cancel()
        runningThreadTimerConnection = runningThreadTimer.connect()
        store.markActiveAccount()
        isProvidersExpanded = false
        refreshRunningThreadAttribution()
        triggerRefreshOnOpenIfNeeded()
        self.refreshMonitorPageData()
    }

    private func loadRecordsIfNeeded(force: Bool = false) {
        guard self.isLoadingRecords == false, force || self.recordsSnapshot == nil else { return }
        let requestID = UUID()
        self.recordsLoadID = requestID
        self.isLoadingRecords = true
        self.recordsLoadFailed = false
        let service = RecordsSnapshotService()
        Task {
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try await service.loadCached()
                }.value
                guard self.recordsLoadID == requestID else { return }
                self.recordsSnapshot = snapshot
                self.refreshMonitorPageData()
            } catch {
                guard self.recordsLoadID == requestID else { return }
                self.recordsLoadFailed = true
            }
            guard self.recordsLoadID == requestID else { return }
            self.isLoadingRecords = false
        }
    }

    private func loadMonitorModels(force: Bool = false) {
        let period = self.selectedUsagePeriod
        let updatedAt = self.store.localCostSummary.updatedAt
        let day = Calendar.current.startOfDay(for: self.now)
        if self.monitorModelPeriod == period,
           self.monitorIndexUpdatedAt == updatedAt,
           self.monitorIndexLoadedDay == day,
           self.monitorModelUsage != nil || self.isLoadingMonitorModels { return }
        if self.monitorModelPeriod != period {
            self.monitorModelUsage = nil
            self.monitorSessionUsage = nil
        }
        self.monitorModelPeriod = period
        self.monitorIndexUpdatedAt = updatedAt
        self.monitorIndexLoadedDay = day
        let requestID = UUID()
        self.monitorModelLoadID = requestID
        self.monitorModelsLoadFailed = false
        self.isLoadingMonitorModels = true
        let databaseURL = SessionLogStore.shared.costUsageIndexURL
        let modelPricingOverrides = self.store.config.modelPricing
        self.monitorIndexRefresh.requestRefresh(now: self.now, load: { loadedAt in
                guard let index = try? LocalCostIndexStore(databaseURL: databaseURL) else { return nil }
                let metadata = CodexSessionMetadataStore().load()
                guard let models = try? index.modelUsage(period: period, now: loadedAt, modelPricingOverrides: modelPricingOverrides),
                      let sessions = try? index.sessionUsage(period: period, now: loadedAt, modelPricingOverrides: modelPricingOverrides, metadataBySessionID: metadata) else { return nil }
                let recent: [MonitorCodexSessionUsage]
                if period == .last30Days {
                    recent = sessions
                } else {
                    guard let rows = try? index.sessionUsage(period: .last30Days, now: loadedAt,
                        modelPricingOverrides: modelPricingOverrides, metadataBySessionID: metadata) else { return nil }
                    recent = rows
                }
                return MonitorIndexedSnapshot(models: models, sessions: sessions, recentSessions: recent)
        }, apply: { result in
            guard self.monitorModelPeriod == period, self.monitorModelLoadID == requestID else { return }
            if let result {
                self.monitorModelUsage = result.models
                self.monitorSessionUsage = result.sessions
                self.recentMonitorSessionUsage = result.recentSessions
            }
            self.monitorModelsLoadFailed = result == nil
            self.isLoadingMonitorModels = false
            self.refreshMonitorPageData()
        })
    }

    private func handleMenuPresentationClosed() {
        runningThreadRefreshController.reset()
        countdownTimerConnection?.cancel()
        countdownTimerConnection = nil
        runningThreadTimerConnection?.cancel()
        runningThreadTimerConnection = nil
        openRefreshGate.resetForClose()
        pendingCostHide?.cancel()
        pendingCostHide = nil
        pendingResetCreditsHide?.cancel()
        pendingResetCreditsHide = nil
        pendingCopiedOpenAIAccountGroupEmailHide?.cancel()
        pendingCopiedOpenAIAccountGroupEmailHide = nil
        copiedOpenAIAccountGroupEmail = nil
        isCostPanelPresented = false
        isCostSummaryHovered = false
        isCostPanelHovered = false
        isResetCreditsPanelPresented = false
        isResetCreditsHovered = false
        isResetCreditsPanelHovered = false
        isResetCreditsPanelPinned = false
        pendingResetCredit = nil
        isConsumingResetCredit = false
        self.clearAlignQuotaFeedback()
        DetachedWindowPresenter.shared.close(id: costPanelID)
        DetachedWindowPresenter.shared.close(id: resetCreditsPanelID)
    }

    private func triggerRefreshOnOpenIfNeeded() {
        self.store.reloadCodexServiceTierCatalog()
        guard openRefreshGate.shouldTriggerRefresh(isRefreshing: isRefreshing) else { return }
        Task { await refresh(origin: .menuOpen, force: true, announceResult: false) }
    }

    private func refresh(
        origin: MenuBarRefreshOrigin,
        force: Bool = true,
        announceResult: Bool = false
    ) async {
        self.toolUsageStore.refreshIfNeeded(force: origin == .manual)
        let shouldRefreshOAuth = force || store.hasStaleOAuthUsageSnapshot(maxAge: usageRefreshInterval)
        let shouldRefreshLocalCost = force || store.localCostSummary.updatedAt == nil

        guard shouldRefreshOAuth || shouldRefreshLocalCost else {
            return
        }

        var didRequestLocalCostRefresh = false
        if shouldRefreshLocalCost {
            now = Date()
            didRequestLocalCostRefresh = true
            store.refreshLocalCostSummary(
                force: true,
                minimumInterval: 0,
                refreshSessionCache: origin.refreshesSessionCache
            )
            refreshRunningThreadAttribution()
        }

        if shouldRefreshOAuth == false {
            return
        }

        guard store.beginAllUsageRefresh() else { return }
        isRefreshing = true
        defer {
            store.endAllUsageRefresh()
            isRefreshing = false
        }
        let outcomes = await WhamService.shared.refreshAll(store: store)
        store.load()
        now = Date()
        if didRequestLocalCostRefresh == false {
            store.refreshLocalCostSummary(
                force: true,
                minimumInterval: usageRefreshInterval,
                refreshSessionCache: origin.refreshesSessionCache
            )
        }
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(from: outcomes)
        )
    }

    private func consumeResetCredit(_ item: RateLimitResetCreditItem) async {
        guard let account = self.store.oauthAccount(accountID: item.accountId) else {
            self.pendingResetCredit = nil
            return
        }

        self.isConsumingResetCredit = true
        defer { self.isConsumingResetCredit = false }

        do {
            let result = try await WhamService.shared.consumeResetCredit(
                account: account,
                creditId: item.creditId
            )
            switch result.code {
            case .reset:
                self.pendingResetCredit = nil
                self.setNotice(L.resetCreditUsed(result.windowsReset))
                // 用卡成功后必须刷新该账号额度；这次刷新哪怕失败/被跳过也要有可见反馈，
                // 不能静默。announceResult: true 会把刷新失败展示出来。
                await self.refreshAccount(account, announceResult: true)
            case .alreadyRedeemed:
                self.pendingResetCredit = nil
                self.setNotice(L.resetCreditAlreadyRedeemed)
                await self.refreshAccount(account, announceResult: true)
            case .nothingToReset:
                self.setGenericError(L.resetCreditNothingToReset)
            case .noCredit:
                self.pendingResetCredit = nil
                await self.refreshAccount(account, announceResult: false)
                self.setGenericError(L.resetCreditNoCredit)
            case .unknown:
                self.setGenericError(L.resetCreditConsumeFailed)
            }
        } catch {
            self.setGenericError(L.resetCreditConsumeFailed)
        }
    }

    private func refreshAccount(_ account: TokenAccount, announceResult: Bool) async {
        refreshingAccounts.insert(account.id)
        defer { refreshingAccounts.remove(account.id) }

        let outcome = await self.refreshOneRetryingIfSkipped(account)
        store.load()
        now = Date()
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(for: account, outcome: outcome)
        )
    }

    /// 同一账号同一时间只允许一次刷新在跑；如果这次请求撞上了别的刷新（比如打开菜单触发的
    /// 全量刷新还没跑完），`refreshOne` 会直接返回 `.skipped`，什么都不做。
    /// 对于用户主动触发的刷新（点刷新按钮、用完重置卡后自动刷新），不能就此放弃——
    /// 短暂等一下、等占用释放后再补一次真正的刷新，避免界面看起来“没反应”。
    private func refreshOneRetryingIfSkipped(
        _ account: TokenAccount,
        maxAttempts: Int = 5,
        retryDelayNanoseconds: UInt64 = 500_000_000
    ) async -> WhamRefreshOutcome {
        var attempt = 0
        while true {
            let currentAccount = self.store.oauthAccount(accountID: account.accountId) ?? account
            let outcome = await WhamService.shared.refreshOne(account: currentAccount, store: store)
            guard outcome == .skipped else { return outcome }
            attempt += 1
            guard attempt < maxAttempts else { return outcome }
            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
    }

    private func alignQuotaWindows() async {
        guard self.store.config.openAI.showsQuotaWindowStart,
              self.isAligningQuota == false else { return }
        self.isAligningQuota = true
        self.clearAlignQuotaFeedback()
        defer { self.isAligningQuota = false }

        let report = await OpenAIQuotaAlignmentService.shared.align(
            accounts: self.store.accounts,
            defaultModel: self.store.config.global.defaultModel,
            isEnabled: self.store.config.openAI.showsQuotaWindowStart,
            proxyRouting: OpenAIQuotaAlignmentProxyRouting(config: self.store.config),
            shouldContinue: {
                self.store.config.openAI.showsQuotaWindowStart
            },
            refreshAccount: { account in
                self.refreshingAccounts.insert(account.id)
                defer { self.refreshingAccounts.remove(account.id) }
                let outcome = await self.refreshOneRetryingIfSkipped(account)
                self.store.load()
                self.now = Date()
                guard outcome == .updated else { return nil }
                return self.store.oauthAccount(accountID: account.accountId)
            }
        )
        self.refreshRunningThreadAttribution()

        if report.wasAlreadyRunning || report.wasDisabled {
            return
        }

        if let feedback = OpenAIQuotaAlignmentFeedback.from(report) {
            self.presentAlignQuotaFeedback(feedback)
        }
    }

    private var alignQuotaRowTitle: String {
        if self.isAligningQuota {
            return L.alignQuotaAction
        }
        return self.alignQuotaFeedback?.message ?? L.alignQuotaAction
    }

    private var alignQuotaRowColor: Color {
        if self.isAligningQuota {
            return .secondary
        }
        if self.alignQuotaFeedback?.isError == true {
            return .orange
        }
        if self.alignQuotaFeedback?.isSuccess == true {
            return .green
        }
        return .secondary
    }

    private func presentAlignQuotaFeedback(_ feedback: OpenAIQuotaAlignmentFeedback) {
        self.alignQuotaFeedbackClearTask?.cancel()
        self.alignQuotaFeedback = feedback
        self.alignQuotaFeedbackClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard Task.isCancelled == false else { return }
            self.alignQuotaFeedback = nil
        }
    }

    private func clearAlignQuotaFeedback() {
        self.alignQuotaFeedbackClearTask?.cancel()
        self.alignQuotaFeedbackClearTask = nil
        self.alignQuotaFeedback = nil
    }

    private func reauthAccount(_: TokenAccount) {
        self.startOAuthLogin()
    }

    private func requestCloseStatusItemMenu() {
        NotificationCenter.default.post(name: .codexbarRequestCloseStatusItemMenu, object: nil)
    }

    private func refreshFailureMessage(from outcomes: [WhamRefreshOutcome]) -> String? {
        let failures = outcomes.compactMap(\.errorMessage)
        guard failures.isEmpty == false else { return nil }
        if outcomes.contains(.updated) || outcomes.contains(.skipped) {
            return failures.first
        }
        return failures.first ?? "Refresh failed."
    }

    private func refreshFailureMessage(for account: TokenAccount, outcome: WhamRefreshOutcome) -> String? {
        guard let message = outcome.errorMessage else { return nil }
        let label = self.accountIdentity(account)
        return "\(label): \(message)"
    }

    private func clearError() {
        self.errorBanner = nil
    }

    private func setGenericError(_ message: String?) {
        guard let message else {
            self.clearError()
            return
        }
        self.errorBanner = MenuBarErrorBannerState(message: message, source: .generic)
    }

    private func setNotice(_ message: String?) {
        guard let message else {
            self.clearError()
            return
        }
        self.errorBanner = MenuBarErrorBannerState(message: message, source: .notice)
    }

    private func applyRefreshFeedback(announceResult: Bool, message: String?) {
        self.errorBanner = MenuBarRefreshErrorResolver.nextBanner(
            current: self.errorBanner,
            announceResult: announceResult,
            refreshMessage: message
        )
    }

    private func refreshImportedAccounts(accountIDs: [String]) {
        let importedAccountIDs = Set(accountIDs)
        guard importedAccountIDs.isEmpty == false else { return }

        let importedAccounts = self.store.accounts.filter { importedAccountIDs.contains($0.accountId) }
        guard importedAccounts.isEmpty == false else { return }

        Task {
            await withTaskGroup(of: Void.self) { group in
                for account in importedAccounts {
                    group.addTask {
                        _ = await WhamService.shared.refreshOne(account: account, store: self.store)
                    }
                }
            }
        }
    }

    private func refreshRunningThreadAttribution() {
        let now = Date()
        let service = self.runningThreadAttributionService

        self.runningThreadRefreshController.requestRefresh(now: now) { refreshDate in
            service.load(now: refreshDate)
        } apply: { attribution in
            if self.runningThreadAttribution != attribution {
                self.now = Date()
                self.runningThreadAttribution = attribution
                self.refreshMonitorPageData()
            }
        }
    }
}

private enum AddProviderPreset: String, CaseIterable, Identifiable {
    case preset
    case custom

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .preset:
            return L.addProviderPresetTab
        case .custom:
            return "Custom"
        }
    }
}

private struct AddProviderResult {
    let preset: AddProviderPreset
    let label: String
    let baseURL: String
    let accountLabel: String
    let apiKey: String
    let wireAPI: CodexBarWireAPI
    let presetID: String?
    let model: String?
    let modelCatalog: [CodexBarOpenRouterModel]
    let openRouterSelection: OpenRouterSelectionPayload?
}

private struct OpenRouterSelectionPayload: Equatable {
    let apiKey: String
    let selectedModelID: String
    let pinnedModelIDs: [String]
    let cachedModelCatalog: [CodexBarOpenRouterModel]
    let fetchedAt: Date?
}

private func normalizedOpenRouterModelID(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func orderedPinnedOpenRouterModelIDs(
    selectedModelIDs: Set<String>,
    cachedModels: [CodexBarOpenRouterModel],
    manualModelID: String
) -> [String] {
    let normalizedManualModelID = normalizedOpenRouterModelID(manualModelID)
    let orderedFromCatalog = cachedModels.map(\.id).filter { selectedModelIDs.contains($0) }
    let remaining = selectedModelIDs.subtracting(orderedFromCatalog).sorted()
    var ordered = orderedFromCatalog + remaining
    if let normalizedManualModelID,
       ordered.contains(normalizedManualModelID) == false {
        ordered.append(normalizedManualModelID)
    }
    return ordered
}

private func makeOpenRouterSelectionPayload(
    apiKey: String,
    selectedModelIDs: Set<String>,
    manualModelID: String,
    cachedModels: [CodexBarOpenRouterModel],
    fetchedAt: Date?
) -> OpenRouterSelectionPayload? {
    guard let normalizedAPIKey = normalizedOpenRouterModelID(apiKey) else {
        return nil
    }

    let orderedPinnedModelIDs = orderedPinnedOpenRouterModelIDs(
        selectedModelIDs: selectedModelIDs,
        cachedModels: cachedModels,
        manualModelID: manualModelID
    )
    guard let selectedModelID = normalizedOpenRouterModelID(manualModelID) ?? orderedPinnedModelIDs.first else {
        return nil
    }

    return OpenRouterSelectionPayload(
        apiKey: normalizedAPIKey,
        selectedModelID: selectedModelID,
        pinnedModelIDs: orderedPinnedModelIDs,
        cachedModelCatalog: cachedModels,
        fetchedAt: fetchedAt
    )
}

private struct OpenRouterModelPickerSection: View {
    @ObservedObject var store: TokenStore
    @Binding var apiKey: String
    @Binding var selectedModelIDs: Set<String>
    @Binding var manualModelID: String
    @Binding var cachedModels: [CodexBarOpenRouterModel]
    @Binding var fetchedAt: Date?

    let refreshAction: (String) async throws -> OpenRouterModelCatalogSnapshot
    let helperText: String

    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var note: String?

    private var filteredModels: [CodexBarOpenRouterModel] {
        let trimmedSearch = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSearch.isEmpty == false else { return self.cachedModels }
        return self.cachedModels.filter { model in
            model.id.localizedCaseInsensitiveContains(trimmedSearch) ||
                model.name.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    private var statusText: String {
        if let fetchedAt {
            return "\(cachedModels.count) cached models · updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        if cachedModels.isEmpty == false {
            return "\(cachedModels.count) cached models"
        }
        return "No cached models yet"
    }

    private var selectedCountText: String {
        "\(self.selectedModelIDs.count) selected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(self.statusText)
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                Button(isRefreshing ? "Refreshing..." : "Refresh Models") {
                    Task {
                        await self.refreshModels()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if cachedModels.isEmpty == false {
                HStack(spacing: 8) {
                    TextField("Search Models", text: $searchText)
                    Text(self.selectedCountText)
                        .font(MenuSurface.font(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }

                List {
                    ForEach(self.filteredModels) { model in
                        Toggle(isOn: self.bindingForModel(model.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .font(MenuSurface.font(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(model.id)
                                    .font(MenuSurface.font(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 2)
                        }
                        .toggleStyle(.checkbox)
                    }

                    if self.filteredModels.isEmpty {
                        Text("No models match the current search.")
                            .font(MenuSurface.font(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220, maxHeight: 260)
            }

            TextField("Manual model ID fallback (optional)", text: $manualModelID)
            Text(helperText)
                .font(MenuSurface.font(size: 10))
                .foregroundColor(.secondary)

            if let note {
                Text(note)
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func toggleModel(_ modelID: String) {
        if self.selectedModelIDs.contains(modelID) {
            self.selectedModelIDs.remove(modelID)
        } else {
            self.selectedModelIDs.insert(modelID)
        }
    }

    private func bindingForModel(_ modelID: String) -> Binding<Bool> {
        Binding(
            get: { self.selectedModelIDs.contains(modelID) },
            set: { isSelected in
                if isSelected {
                    self.selectedModelIDs.insert(modelID)
                } else {
                    self.selectedModelIDs.remove(modelID)
                }
            }
        )
    }

    private func refreshModels() async {
        self.isRefreshing = true
        self.note = nil
        defer {
            self.isRefreshing = false
        }

        do {
            let snapshot = try await self.refreshAction(self.apiKey)
            self.cachedModels = snapshot.models
            self.fetchedAt = snapshot.fetchedAt
            self.note = "Refreshed \(snapshot.models.count) models. Checked models will be available directly after saving."
        } catch {
            self.note = "Refresh failed. Keeping the current selection and cached models."
        }
    }
}

private struct AddProviderSheet: View {
    @ObservedObject var store: TokenStore

    @State private var preset: AddProviderPreset
    @State private var label = ""
    @State private var baseURL = ""
    @State private var accountLabel = ""
    @State private var apiKey = ""
    @State private var customWireAPI: CodexBarWireAPI = .responses
    @State private var customModel = ""
    @State private var selectedPresetID: String
    @State private var presetModelID = ""
    @State private var openRouterSelectedModelIDs: Set<String>
    @State private var openRouterManualModelID: String
    @State private var openRouterCachedModels: [CodexBarOpenRouterModel]
    @State private var openRouterFetchedAt: Date?

    let onSave: (AddProviderResult) -> Void
    let onCancel: () -> Void

    init(
        store: TokenStore,
        defaultPreset: AddProviderPreset = .preset,
        onSave: @escaping (AddProviderResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let existingProvider = store.openRouterProvider
        self._preset = State(initialValue: defaultPreset)
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        let firstPreset = CodexBarProviderPresetCatalog.all.first
        self._selectedPresetID = State(initialValue: firstPreset?.id ?? "")
        self._presetModelID = State(initialValue: firstPreset?.defaultModelID ?? "")
        self._openRouterSelectedModelIDs = State(initialValue: Set(existingProvider?.pinnedModelIDs ?? []))
        self._openRouterManualModelID = State(initialValue: existingProvider?.openRouterEffectiveModelID ?? "")
        self._openRouterCachedModels = State(initialValue: existingProvider?.cachedModelCatalog ?? [])
        self._openRouterFetchedAt = State(initialValue: existingProvider?.modelCatalogFetchedAt)
    }

    private var selectedPreset: CodexBarProviderPreset? {
        CodexBarProviderPresetCatalog.preset(id: self.selectedPresetID)
    }

    private var selectedPresetIsOpenRouter: Bool {
        self.selectedPreset?.kind == .openRouter
    }

    private var canSave: Bool {
        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { return false }

        switch self.preset {
        case .preset:
            if self.selectedPresetIsOpenRouter {
                return self.openRouterSelectionPayload != nil
            }
            return self.selectedPreset != nil &&
                self.presetModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .custom:
            let hasBasics = self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if self.customWireAPI == .chat {
                return hasBasics && self.customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            return hasBasics
        }
    }

    private var openRouterSelectionPayload: OpenRouterSelectionPayload? {
        makeOpenRouterSelectionPayload(
            apiKey: self.apiKey,
            selectedModelIDs: self.openRouterSelectedModelIDs,
            manualModelID: self.openRouterManualModelID,
            cachedModels: self.openRouterCachedModels,
            fetchedAt: self.openRouterFetchedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Provider")
                .font(.headline)

            Picker("Preset", selection: $preset) {
                ForEach(AddProviderPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            switch preset {
            case .preset:
                presetSection
            case .custom:
                customSection
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(self.makeResult())
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: self.preset == .custom ? 380 : 460)
        .onChange(of: selectedPresetID) { _ in
            self.presetModelID = self.selectedPreset?.defaultModelID ?? ""
        }
    }

    @ViewBuilder private var presetSection: some View {
        HStack {
            Text(L.addProviderPresetVendor)
            Spacer()
            RouteSelectionMenu(
                title: self.selectedPreset?.displayName ?? L.addProviderPresetVendor,
                accessibilityLabel: L.addProviderPresetVendor,
                items: CodexBarProviderPresetGroup.allCases.flatMap { group in
                    CodexBarProviderPresetCatalog.all.filter { $0.group == group }.map { preset in
                        RouteSelectionMenuItem(id: preset.id, title: "\(group.title) · \(preset.displayName)", isSelected: self.selectedPresetID == preset.id) {
                            self.selectedPresetID = preset.id
                        }
                    }
                },
                fontSize: 12
            )
            .frame(maxWidth: 270)
        }

        if self.selectedPresetIsOpenRouter {
            OpenRouterModelPickerSection(
                store: self.store,
                apiKey: $apiKey,
                selectedModelIDs: $openRouterSelectedModelIDs,
                manualModelID: $openRouterManualModelID,
                cachedModels: $openRouterCachedModels,
                fetchedAt: $openRouterFetchedAt,
                refreshAction: { apiKey in
                    try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
                },
                helperText: "Pick one or more models here. The first checked model becomes the current model by default, and all checked models will appear in the OpenRouter section for direct switching."
            )
        } else {
            HStack(spacing: 8) {
                TextField(L.addProviderModel, text: $presetModelID)
                if let models = selectedPreset?.defaultModels, models.isEmpty == false {
                    RouteSelectionMenu(
                        title: L.addProviderModel,
                        accessibilityLabel: L.addProviderModel,
                        items: models.map { model in
                            RouteSelectionMenuItem(id: model.id, title: model.name, isSelected: self.presetModelID == model.id) {
                                self.presetModelID = model.id
                            }
                        },
                        fontSize: 12
                    )
                    .fixedSize()
                }
            }
        }

        TextField("Account label", text: $accountLabel)
        SecureField("API key", text: $apiKey)

        if let note = selectedPreset?.note {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var customSection: some View {
        TextField("Provider name", text: $label)
        TextField("Base URL", text: $baseURL)
        Picker(L.addProviderWireAPI, selection: $customWireAPI) {
            ForEach(CodexBarWireAPI.allCases) { wire in
                Text(wire.title).tag(wire)
            }
        }
        .pickerStyle(.segmented)
        if customWireAPI == .chat {
            TextField(L.addProviderModel, text: $customModel)
            Text(L.addProviderWireAPIChatHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        TextField("Account label", text: $accountLabel)
        SecureField("API key", text: $apiKey)
    }

    private func makeResult() -> AddProviderResult {
        switch preset {
        case .preset:
            let selected = self.selectedPreset
            if selected?.kind == .openRouter {
                return AddProviderResult(
                    preset: .preset,
                    label: "OpenRouter",
                    baseURL: "",
                    accountLabel: accountLabel,
                    apiKey: apiKey,
                    wireAPI: .responses,
                    presetID: selected?.id,
                    model: nil,
                    modelCatalog: [],
                    openRouterSelection: self.openRouterSelectionPayload
                )
            }
            return AddProviderResult(
                preset: .preset,
                label: selected?.displayName ?? self.selectedPresetID,
                baseURL: selected?.baseURL ?? "",
                accountLabel: accountLabel,
                apiKey: apiKey,
                wireAPI: selected?.wireAPI ?? .chat,
                presetID: selected?.id,
                model: presetModelID,
                modelCatalog: selected?.defaultModels ?? [],
                openRouterSelection: nil
            )
        case .custom:
            return AddProviderResult(
                preset: .custom,
                label: label,
                baseURL: baseURL,
                accountLabel: accountLabel,
                apiKey: apiKey,
                wireAPI: customWireAPI,
                presetID: nil,
                model: customWireAPI == .chat ? customModel : nil,
                modelCatalog: [],
                openRouterSelection: nil
            )
        }
    }
}

private struct AddProviderAccountSheet: View {
    let provider: CodexBarProvider
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var label = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account · \(provider.label)")
                .font(.headline)

            TextField("Account label", text: $label)
            SecureField("API key", text: $apiKey)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(label, apiKey)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct AddOpenRouterAccountSheet: View {
    let provider: CodexBarProvider
    @ObservedObject var store: TokenStore
    let onSave: (OpenRouterSelectionPayload) -> Void
    let onCancel: () -> Void

    @State private var apiKey = ""
    @State private var selectedModelIDs: Set<String>
    @State private var manualModelID: String
    @State private var cachedModels: [CodexBarOpenRouterModel]
    @State private var fetchedAt: Date?

    init(
        provider: CodexBarProvider,
        store: TokenStore,
        onSave: @escaping (OpenRouterSelectionPayload) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        self._selectedModelIDs = State(initialValue: Set(provider.pinnedModelIDs))
        self._manualModelID = State(initialValue: provider.openRouterEffectiveModelID ?? "")
        self._cachedModels = State(initialValue: provider.cachedModelCatalog)
        self._fetchedAt = State(initialValue: provider.modelCatalogFetchedAt)
    }

    private var canSave: Bool {
        self.selectionPayload != nil
    }

    private var selectionPayload: OpenRouterSelectionPayload? {
        makeOpenRouterSelectionPayload(
            apiKey: self.apiKey,
            selectedModelIDs: self.selectedModelIDs,
            manualModelID: self.manualModelID,
            cachedModels: self.cachedModels,
            fetchedAt: self.fetchedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account · \(provider.label)")
                .font(.headline)

            SecureField("API key", text: $apiKey)
            OpenRouterModelPickerSection(
                store: self.store,
                apiKey: $apiKey,
                selectedModelIDs: $selectedModelIDs,
                manualModelID: $manualModelID,
                cachedModels: $cachedModels,
                fetchedAt: $fetchedAt,
                refreshAction: { apiKey in
                    try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
                },
                helperText: "Account labels are auto-generated for OpenRouter. Pick the models here; after saving, these checked models will appear directly in the OpenRouter section."
            )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    if let selectionPayload {
                        onSave(selectionPayload)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

private struct EditOpenRouterModelSheet: View {
    let provider: CodexBarProvider
    @ObservedObject var store: TokenStore
    let onError: (String?) -> Void
    let onClose: () -> Void

    @State private var manualModelID: String
    @State private var selectedModelIDs: Set<String>
    @State private var cachedModels: [CodexBarOpenRouterModel]
    @State private var fetchedAt: Date?

    init(
        provider: CodexBarProvider,
        store: TokenStore,
        onError: @escaping (String?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.provider = provider
        self.store = store
        self.onError = onError
        self.onClose = onClose
        self._manualModelID = State(initialValue: provider.openRouterEffectiveModelID ?? "")
        self._selectedModelIDs = State(initialValue: Set(provider.pinnedModelIDs))
        self._cachedModels = State(initialValue: provider.cachedModelCatalog)
        self._fetchedAt = State(initialValue: provider.modelCatalogFetchedAt)
    }

    private var canSave: Bool {
        self.selectionPayload != nil
    }

    private var currentProvider: CodexBarProvider {
        self.store.openRouterProvider ?? self.provider
    }

    private var selectionPayload: OpenRouterSelectionPayload? {
        makeOpenRouterSelectionPayload(
            apiKey: self.currentProvider.activeAccount?.apiKey ?? "",
            selectedModelIDs: self.selectedModelIDs,
            manualModelID: self.manualModelID,
            cachedModels: self.cachedModels,
            fetchedAt: self.fetchedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenRouter Models")
                .font(.headline)

            Text("Checked models will stay visible in the OpenRouter section. The current model defaults to the first checked model unless you enter a manual fallback below.")
                .font(MenuSurface.font(size: 10))
                .foregroundColor(.secondary)

            OpenRouterModelPickerSection(
                store: self.store,
                apiKey: .constant(self.currentProvider.activeAccount?.apiKey ?? ""),
                selectedModelIDs: $selectedModelIDs,
                manualModelID: $manualModelID,
                cachedModels: $cachedModels,
                fetchedAt: $fetchedAt,
                refreshAction: { _ in
                    try await self.store.refreshOpenRouterModelCatalog()
                    let refreshedProvider = self.store.openRouterProvider ?? self.currentProvider
                    return OpenRouterModelCatalogSnapshot(
                        models: refreshedProvider.cachedModelCatalog,
                        fetchedAt: refreshedProvider.modelCatalogFetchedAt ?? Date()
                    )
                },
                helperText: "You can still enter an exact OpenRouter model ID manually. Checked models become your direct-use list in the main menu."
            )

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Save") {
                    guard let selectionPayload else {
                        self.onError("请选择至少一个模型，或输入一个手动模型 ID")
                        return
                    }
                    do {
                        try self.store.updateOpenRouterModelSelection(
                            selectedModelID: selectionPayload.selectedModelID,
                            pinnedModelIDs: selectionPayload.pinnedModelIDs,
                            cachedModelCatalog: selectionPayload.cachedModelCatalog,
                            fetchedAt: selectionPayload.fetchedAt
                        )
                        self.onError(nil)
                        self.onClose()
                    } catch {
                        self.onError(error.localizedDescription)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

private struct OpenRouterProviderRowView: View {
    let provider: CodexBarProvider
    let isActiveProvider: Bool
    let activeAccountId: String?
    let onActivate: (CodexBarProviderAccount) -> Void
    let onSelectModel: (String) -> Void
    let onAddAccount: () -> Void
    let onEditModel: () -> Void
    let onDeleteAccount: (CodexBarProviderAccount) -> Void

    private var orderedPinnedModelIDs: [String] {
        orderedPinnedOpenRouterModelIDs(
            selectedModelIDs: Set(self.provider.pinnedModelIDs),
            cachedModels: self.provider.cachedModelCatalog,
            manualModelID: self.provider.openRouterEffectiveModelID ?? ""
        )
    }

    private func displayName(for modelID: String) -> String {
        self.provider.cachedModelCatalog.first(where: { $0.id == modelID })?.name ?? modelID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActiveProvider ? MenuSurface.accent : Color.white.opacity(0.36))
                    .frame(width: 7, height: 7)

                Text(provider.label)
                    .font(MenuSurface.font(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(isActiveProvider ? MenuSurface.accent : .white)

                Text(provider.openRouterEffectiveModelID ?? "No model selected")
                    .font(MenuSurface.font(size: 9, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(provider.openRouterEffectiveModelID == nil ? .orange : .secondary)
                    .cornerRadius(3)

                Spacer()

                Button(action: onAddAccount) {
                    Image(systemName: "plus")
                        .font(MenuSurface.font(size: 10))
                }
                .buttonStyle(.borderless)

                Button(action: onEditModel) {
                    Image(systemName: "pencil")
                        .font(MenuSurface.font(size: 10))
                }
                .buttonStyle(.borderless)
            }

            Text(
                provider.modelCatalogFetchedAt.map {
                    "\(provider.cachedModelCatalog.count) cached models · \($0.formatted(date: .abbreviated, time: .shortened))"
                } ?? (
                    provider.cachedModelCatalog.isEmpty
                        ? "No cached models. Refresh the catalog or enter a model ID manually."
                        : "\(provider.cachedModelCatalog.count) cached models"
                )
            )
            .font(MenuSurface.font(size: 9))
            .foregroundColor(.secondary)
            .padding(.leading, 14)

            if self.orderedPinnedModelIDs.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(self.orderedPinnedModelIDs, id: \.self) { modelID in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(self.displayName(for: modelID))
                                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.primary)
                                Text(modelID)
                                    .font(MenuSurface.font(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if modelID == self.provider.openRouterEffectiveModelID {
                                Text("Current")
                                    .font(MenuSurface.font(size: 9, weight: .semibold))
                                    .foregroundColor(MenuSurface.accent)
                            } else {
                                Button(L.zh ? "使用" : "Use") {
                                    self.onSelectModel(modelID)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .font(MenuSurface.font(size: 9, weight: .medium))
                                .tint(MenuSurface.accent)
                            }
                        }
                        .padding(.leading, 14)
                    }
                }
            } else if self.provider.openRouterEffectiveModelID == nil {
                HStack(spacing: 8) {
                    Text("No model configured yet.")
                        .font(MenuSurface.font(size: 10, weight: .medium))
                        .foregroundColor(.orange)

                    Spacer()

                    Button("Set Model") {
                        self.onEditModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .font(MenuSurface.font(size: 9, weight: .semibold))
                }
                .padding(.leading, 14)
            }

            ForEach(provider.accounts) { account in
                Rectangle()
                    .fill(MenuSurface.line)
                    .frame(height: 1)
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(MenuSurface.font(size: 11, weight: account.id == activeAccountId ? .semibold : .regular, design: .monospaced))

                    if account.id == activeAccountId {
                        Image(systemName: "checkmark")
                            .font(MenuSurface.font(size: 9, weight: .semibold))
                            .foregroundColor(MenuSurface.accent)
                    }

                    Spacer()

                    Text(account.maskedAPIKey)
                        .font(MenuSurface.font(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if account.id != activeAccountId || isActiveProvider == false {
                        Button(L.zh ? "使用" : "Use") {
                            onActivate(account)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(MenuSurface.font(size: 10, weight: .medium))
                        .tint(MenuSurface.accent)
                        .disabled(provider.openRouterEffectiveModelID == nil)
                    }

                    Button {
                        onDeleteAccount(account)
                    } label: {
                        Image(systemName: "trash")
                            .font(MenuSurface.font(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(MenuSurface.raised.opacity(isActiveProvider ? 1 : 0.78))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActiveProvider ? MenuSurface.accent.opacity(0.55) : MenuSurface.line, lineWidth: 1))
    }
}
