import AppKit
import Combine
import SwiftUI

private final class ThinOverlayScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        min(6, super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle))
    }
}

private final class ActivityAwareScrollView: NSScrollView {
    var onUserScrollActivity: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        self.onUserScrollActivity?()
        super.scrollWheel(with: event)
    }
}

private enum AdaptiveScrollHeightLimit {
    case fixed(CGFloat)
    case measured(AnyView)
}

enum MenuBarErrorSource: Equatable {
    case generic
    case refresh
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

private struct AdaptiveMenuScrollContainer<Content: View>: NSViewRepresentable {
    let heightLimit: AdaptiveScrollHeightLimit
    let initialHeight: CGFloat
    let onMeasuredHeightChange: ((CGFloat) -> Void)?
    let content: Content

    init(
        maxHeight: CGFloat,
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.heightLimit = .fixed(maxHeight)
        self.initialHeight = maxHeight
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.content = content()
    }

    init<MeasurementContent: View>(
        initialHeight: CGFloat,
        measuredHeight: @escaping () -> MeasurementContent,
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.heightLimit = .measured(AnyView(measuredHeight()))
        self.initialHeight = initialHeight
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.content = content()
    }

    func makeNSView(context: Context) -> AdaptiveMenuScrollHost {
        AdaptiveMenuScrollHost(
            rootView: AnyView(content),
            heightLimit: heightLimit,
            initialHeight: initialHeight,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    func updateNSView(_ nsView: AdaptiveMenuScrollHost, context: Context) {
        nsView.update(
            rootView: AnyView(content),
            heightLimit: heightLimit,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }
}

private struct AdaptiveMenuHeightReportingContainer<Content: View>: NSViewRepresentable {
    let onMeasuredHeightChange: ((CGFloat) -> Void)?
    let content: Content

    init(
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.content = content()
    }

    func makeNSView(context: Context) -> AdaptiveMenuHeightReportingHost {
        AdaptiveMenuHeightReportingHost(
            rootView: AnyView(content),
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    func updateNSView(_ nsView: AdaptiveMenuHeightReportingHost, context: Context) {
        nsView.update(
            rootView: AnyView(content),
            onMeasuredHeightChange: onMeasuredHeightChange
        )
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

private final class AdaptiveMenuHeightReportingHost: NSView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    private var measuredHeight: CGFloat = 1
    private var lastReportedHeight: CGFloat?
    private var isMeasuring = false
    private var lastMeasuredWidth: CGFloat = 0
    private var onMeasuredHeightChange: ((CGFloat) -> Void)?

    init(
        rootView: AnyView,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        super.init(frame: .zero)
        self.hostingView.rootView = rootView
        self.addSubview(self.hostingView)
        self.scheduleMeasurement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let width = max(self.bounds.width, 1)
        self.hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(self.measuredHeight, self.bounds.height, 1)
        )

        guard abs(self.lastMeasuredWidth - width) > 1 else { return }
        self.lastMeasuredWidth = width
        self.scheduleMeasurement()
    }

    func update(
        rootView: AnyView,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.hostingView.rootView = rootView
        self.scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        DispatchQueue.main.async { [weak self] in
            self?.recalculateLayout()
        }
    }

    private func recalculateLayout() {
        guard self.isMeasuring == false else { return }
        self.isMeasuring = true
        defer { self.isMeasuring = false }

        let width = max(self.bounds.width, 1)
        self.hostingView.setFrameSize(
            NSSize(width: width, height: max(self.hostingView.frame.height, self.measuredHeight, 1))
        )

        let fittingHeight = max(self.hostingView.fittingSize.height, 1)
        self.hostingView.setFrameSize(NSSize(width: width, height: fittingHeight))

        if abs((self.lastReportedHeight ?? 0) - fittingHeight) > 1 {
            self.lastReportedHeight = fittingHeight
            self.onMeasuredHeightChange?(fittingHeight)
        }

        guard abs(self.measuredHeight - fittingHeight) > 1 else { return }
        self.measuredHeight = fittingHeight
        self.invalidateIntrinsicContentSize()
        self.superview?.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }
}

private final class AdaptiveMenuScrollHost: NSView {
    private let scrollView = ActivityAwareScrollView()
    private let displayHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let measuringHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let limitHostingView = NSHostingView(rootView: AnyView(EmptyView()))

    private var heightLimit: AdaptiveScrollHeightLimit
    private var measuredHeight: CGFloat
    private var lastReportedHeight: CGFloat?
    private var isMeasuring = false
    private var lastMeasuredWidth: CGFloat = 0
    private var hideScrollerWorkItem: DispatchWorkItem?
    private var onMeasuredHeightChange: ((CGFloat) -> Void)?

    private let idleScrollerAlpha: CGFloat = 0
    private let visibleScrollerAlpha: CGFloat = 0.95
    private let scrollerHideDelay: TimeInterval = 0.9

    init(
        rootView: AnyView,
        heightLimit: AdaptiveScrollHeightLimit,
        initialHeight: CGFloat,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.heightLimit = heightLimit
        self.measuredHeight = max(initialHeight, 1)
        self.onMeasuredHeightChange = onMeasuredHeightChange
        super.init(frame: .zero)

        self.scrollView.drawsBackground = false
        self.scrollView.borderType = .noBorder
        self.scrollView.autohidesScrollers = true
        self.scrollView.scrollerStyle = .overlay
        self.scrollView.verticalScroller = ThinOverlayScroller()
        self.scrollView.verticalScroller?.controlSize = .mini
        self.scrollView.verticalScroller?.alphaValue = self.idleScrollerAlpha
        self.scrollView.hasVerticalScroller = false
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.documentView = self.displayHostingView
        self.scrollView.autoresizingMask = [.width, .height]
        self.scrollView.onUserScrollActivity = { [weak self] in
            self?.showScrollerTemporarily()
        }

        self.addSubview(self.scrollView)
        self.update(
            rootView: rootView,
            heightLimit: heightLimit,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.hideScrollerWorkItem?.cancel()
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        self.scrollView.frame = self.bounds

        let width = max(self.bounds.width, 1)
        guard abs(self.lastMeasuredWidth - width) > 1 else { return }
        self.lastMeasuredWidth = width
        self.scheduleMeasurement()
    }

    func update(
        rootView: AnyView,
        heightLimit: AdaptiveScrollHeightLimit,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.heightLimit = heightLimit
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.displayHostingView.rootView = rootView
        self.measuringHostingView.rootView = rootView
        if case let .measured(limitView) = heightLimit {
            self.limitHostingView.rootView = limitView
        } else {
            self.limitHostingView.rootView = AnyView(EmptyView())
        }
        self.scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        DispatchQueue.main.async { [weak self] in
            self?.recalculateLayout()
        }
    }

    private func recalculateLayout() {
        guard self.isMeasuring == false else { return }
        self.isMeasuring = true
        defer { self.isMeasuring = false }

        let width = max(self.bounds.width, 1)
        self.measuringHostingView.setFrameSize(NSSize(width: width, height: max(self.measuringHostingView.frame.height, 1)))

        let fittingHeight = max(self.measuringHostingView.fittingSize.height, 1)
        let limitHeight = self.resolveHeightLimit(for: width)
        let targetHeight = min(limitHeight, fittingHeight)
        let needsScroller = fittingHeight > limitHeight + 1

        self.displayHostingView.setFrameSize(NSSize(width: width, height: fittingHeight))
        self.scrollView.hasVerticalScroller = needsScroller
        if needsScroller {
            self.hideScrollerImmediately()
        } else {
            self.hideScrollerWorkItem?.cancel()
            self.scrollView.verticalScroller?.alphaValue = self.idleScrollerAlpha
        }

        if abs((self.lastReportedHeight ?? 0) - targetHeight) > 1 {
            self.lastReportedHeight = targetHeight
            self.onMeasuredHeightChange?(targetHeight)
        }

        guard abs(self.measuredHeight - targetHeight) > 1 else { return }
        self.measuredHeight = targetHeight
        self.invalidateIntrinsicContentSize()
        self.superview?.invalidateIntrinsicContentSize()
    }

    private func resolveHeightLimit(for width: CGFloat) -> CGFloat {
        switch self.heightLimit {
        case let .fixed(maxHeight):
            return max(maxHeight, 1)
        case .measured:
            self.limitHostingView.setFrameSize(NSSize(width: width, height: max(self.limitHostingView.frame.height, 1)))
            return max(self.limitHostingView.fittingSize.height, 1)
        }
    }

    private func showScrollerTemporarily() {
        guard self.scrollView.hasVerticalScroller else { return }
        self.hideScrollerWorkItem?.cancel()
        self.animateScroller(to: self.visibleScrollerAlpha)

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideScrollerImmediately()
        }
        self.hideScrollerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + self.scrollerHideDelay, execute: workItem)
    }

    private func hideScrollerImmediately() {
        guard self.scrollView.hasVerticalScroller else { return }
        self.hideScrollerWorkItem?.cancel()
        self.animateScroller(to: self.idleScrollerAlpha)
    }

    private func animateScroller(to alpha: CGFloat) {
        guard let scroller = self.scrollView.verticalScroller else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scroller.animator().alphaValue = alpha
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var oauth: OAuthManager
    @EnvironmentObject var updateCoordinator: UpdateCoordinator

    private let costPanelID = "cost-details-hover-panel"
    private let usageRefreshInterval = OpenAIUsagePollingService.defaultRefreshInterval
    private let visibleOpenAIAccountLimit = 5
    private let openAIAccountsInitialHeight: CGFloat = 260
    private let runningThreadAttributionService = OpenAIRunningThreadAttributionService()
    private let oauthAccountService = CodexBarOAuthAccountService()
    private let openAIAccountCSVService = OpenAIAccountCSVService()
    private let openAIAccountCSVPanelService = OpenAIAccountCSVPanelService()
    private let codexAppPathPanelService = CodexAppPathPanelService.shared
    private let codexDesktopLaunchProbeService = CodexDesktopLaunchProbeService()

    @State private var isRefreshing = false
    @State private var errorBanner: MenuBarErrorBannerState?
    @State private var now = Date()
    @State private var runningThreadAttribution = OpenAIRunningThreadAttribution.empty
    @State private var refreshingAccounts: Set<String> = []
    @State private var copiedOpenAIAccountGroupEmail: String?
    @State private var languageToggle = false
    @State private var isCostSummaryHovered = false
    @State private var isCostPanelHovered = false
    @State private var isCostPanelPresented = false
    @State private var openRefreshGate = MenuBarOpenRefreshGate()
    @State private var pendingCostHide: DispatchWorkItem?
    @State private var pendingCopiedOpenAIAccountGroupEmailHide: DispatchWorkItem?
    @State private var costSummaryAnchorView: NSView?
    @State private var isProvidersExpanded = false
    @State private var lastOpenAIManualSwitchResult: OpenAIManualSwitchResult?
    @State private var countdownTimerConnection: Cancellable?
    @State private var runningThreadTimerConnection: Cancellable?
    @State private var runningThreadRefreshController = CoalescedBackgroundRefreshController<OpenAIRunningThreadAttribution>()

    private let countdownTimer = Timer.publish(every: 10, on: .main, in: .common)
    private let runningThreadTimer = Timer.publish(
        every: OpenAIRunningThreadAttributionService.defaultRecentActivityWindow,
        on: .main,
        in: .common
    )
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()
    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
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
            targetAccount: self.store.oauthAccount(accountID: lastOpenAIManualSwitchResult.targetAccountID)
        )
    }

    private var runtimeRouteBanner: OpenAIStatusBannerPresentation? {
        OpenAIAccountPresentation.runtimeRouteBanner(
            snapshot: self.openAIRuntimeRouteSnapshot,
            latestRoutedAccount: self.latestRoutedAccount,
            switchTargetAccount: self.switchTargetAccount
        )
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

    private var isCompletelyEmpty: Bool {
        store.accounts.isEmpty &&
        store.customProviders.isEmpty &&
        self.visibleOpenRouterProvider == nil
    }

    var body: some View {
        mainMenuContent
        .frame(width: MenuBarStatusItemIdentity.popoverContentWidth)
        .onReceive(countdownTimer) { _ in
            now = Date()
        }
        .onReceive(runningThreadTimer) { _ in
            refreshRunningThreadAttribution()
        }
        .onReceive(store.$localCostSummary) { _ in
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarStatusItemMenuDidClose)) { _ in
            self.handleMenuPresentationClosed()
        }
        .onChange(of: self.errorBanner) { _ in
            self.requestStatusItemLayoutRefresh()
        }
        .onChange(of: self.lastOpenAIManualSwitchResult) { _ in
            self.requestStatusItemLayoutRefresh()
        }
    }

    @ViewBuilder
    private var mainMenuContent: some View {
        AdaptiveMenuHeightReportingContainer(onMeasuredHeightChange: self.reportMeasuredMenuHeight) {
            menuContentStack
        }
    }

    private var menuContentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("codexbar")
                    .font(.system(size: 13, weight: .semibold))

                if let active = store.activeProvider {
                    Text(active.label)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                }

                Spacer()

                Button {
                    Task { await refresh(announceResult: true) }
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .help(L.refreshUsage)
                .foregroundColor(isRefreshing ? .accentColor : .secondary)
                .disabled(isRefreshing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let activeProvider = store.activeProvider,
               let activeAccount = store.activeProviderAccount {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(self.activeProviderSummaryTitle(activeProvider: activeProvider, activeAccount: activeAccount))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)

                        Spacer(minLength: 0)
                    }

                    Text("Model: \(store.activeModel)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if let pendingAvailability = self.updateCoordinator.pendingAvailability {
                Divider()
                self.updateAvailableBanner(availability: pendingAvailability)
            }

            Divider()

            if isCompletelyEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(L.noAccounts)
                        .foregroundColor(.secondary)
                    Text("Add an OpenAI account, a custom provider, or OpenRouter.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        CostSummaryRowView(
                            summary: store.localCostSummary,
                            currency: currency,
                            compactTokens: compactTokens
                        )
                    }
                    .background(
                        ViewReferenceReader { view in
                            resolveCostSummaryAnchor(view)
                        }
                    )
                    .onHover { hovering in
                        setCostSummaryHover(hovering)
                    }

                    openAIAccountsSection

                    providersSection

                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            if let error = self.errorBanner?.message {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(error)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()

            HStack(spacing: 8) {
                if let lastUpdate = store.accounts.compactMap({ $0.lastChecked }).max() {
                    Text(relativeTime(lastUpdate))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else if let provider = store.activeProvider {
                    Text(provider.hostLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Menu {
                    Button(L.exportOpenAICSVAction) {
                        exportOpenAIAccountsCSV()
                    }
                    Button(L.importOpenAICSVAction) {
                        importOpenAIAccountsCSV()
                    }
                } label: {
                    Image(systemName: OpenAIAccountCSVToolbarUI.symbolName)
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(L.openAICSVToolbar)
                .accessibilityIdentifier(OpenAIAccountCSVToolbarUI.accessibilityIdentifier)
                .help(L.openAICSVToolbar)

                Button {
                    startOAuthLogin()
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("login toolbar button")
                .accessibilityIdentifier("codexbar.login-openai.toolbar")

                Button {
                    openAddProviderWindow()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)

                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(L.settings)

                Button {
                    switch L.languageOverride {
                    case nil: L.languageOverride = true
                    case true: L.languageOverride = false
                    case false: L.languageOverride = nil
                    }
                    languageToggle.toggle()
                } label: {
                    let label = languageToggle ? L.languageOverride : L.languageOverride
                    Text(label == nil ? "AUTO" : (label == true ? "中" : "EN"))
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)

                Button {
                    AppLifecycleDiagnostics.shared.markTermination(reason: "quit_button")
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, MenuBarPopoverSizing.topContentInset)
        .padding(.bottom, MenuBarPopoverSizing.bottomContentInset)
    }

    private func updateAvailableBanner(availability: AppUpdateAvailability) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L.menuUpdateAvailableTitle(availability.release.version))
                    .font(.system(size: 11, weight: .medium))
                Text(L.menuUpdateAvailableSubtitle(availability.currentVersion, availability.release.version))
                    .font(.system(size: 10))
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
            .font(.system(size: 10))
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
                Text("OpenAI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if let openAIAvailabilityBadgeTitle {
                    self.openAIAvailabilityBadge(title: openAIAvailabilityBadgeTitle)
                }

                Spacer(minLength: 8)

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
            .padding(.leading, 4)
            .padding(.trailing, 8)

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

            if let runtimeRouteBanner,
               let actionTitle = runtimeRouteBanner.actionTitle {
                HStack(spacing: 0) {
                    Spacer()

                    Button(actionTitle) {
                        self.clearStaleAggregateStickyIfNeeded()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(runtimeRouteBanner.tone == .warning ? .orange : .secondary)
                    .help(L.aggregateRuntimeClearStaleStickyHint)
                }
                .padding(.horizontal, 10)
            }

            if store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No OpenAI account added.")
                        .font(.system(size: 11, weight: .medium))
                    Text("Use the toolbar plus button to add OpenAI OAuth accounts.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )
            } else {
                AdaptiveMenuScrollContainer(
                    initialHeight: openAIAccountsInitialHeight,
                    measuredHeight: {
                        openAIAccountGroupsView(visibleGroupedAccounts)
                    },
                    onMeasuredHeightChange: nil
                ) {
                    openAIAccountGroupsView(groupedAccounts)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                } label: {
                    HStack(spacing: 6) {
                        Text("Providers")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        Spacer()

                        Text("\(providerCount)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        Image(systemName: isProvidersExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isProvidersExpanded {
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

    @ViewBuilder
    private func openAIAccountGroupsView(_ groups: [OpenAIAccountGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
                            rowState: rowState,
                            isRefreshing: refreshingAccounts.contains(account.id),
                            usageDisplayMode: self.store.config.openAI.usageDisplayMode,
                            defaultManualActivationBehavior: self.store.config.openAI.manualActivationBehavior
                        ) { trigger in
                            Task {
                                await activateAccount(
                                    account,
                                    trigger: trigger
                                )
                            }
                        } onRefresh: {
                            Task { await refreshAccount(account, announceResult: true) }
                        } onReauth: {
                            reauthAccount(account)
                        } onDelete: {
                            store.remove(account)
                        }
                    }
                }
            }
        }
    }

    private func openAIAccountGroupHeaderLabel(_ group: OpenAIAccountGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(group.email)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if let copiedConfirmation = OpenAIAccountPresentation.accountGroupCopyConfirmationText(
                groupEmail: group.email,
                copiedEmail: self.copiedOpenAIAccountGroupEmail
            ) {
                Text(copiedConfirmation)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green)
                    .lineLimit(1)
            } else if let remark = group.headerQuotaRemark(now: now) {
                Text(remark)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }

    private func openAIStatusBanner(
        _ banner: OpenAIStatusBannerPresentation,
        onAction: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        let accentColor: Color = banner.tone == .warning ? .orange : .accentColor
        let iconName = banner.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Text(banner.message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = banner.actionTitle,
                   let onAction {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                }
            }

            Spacer(minLength: 4)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.08))
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

    private func currency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

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

    private func shortDay(_ date: Date) -> String {
        Self.shortDayFormatter.string(from: date)
    }

    private func reportMeasuredMenuHeight(_ height: CGFloat) {
        NotificationCenter.default.post(
            name: .codexbarStatusItemMeasuredHeightDidChange,
            object: nil,
            userInfo: ["height": height]
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
        let panelSize = CGSize(
            width: CostDetailsPanelView.panelWidth,
            height: CostDetailsPanelView.panelHeight(hasHistory: !store.localCostSummary.dailyEntries.isEmpty)
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
                currency: currency,
                compactTokens: compactTokens,
                shortDay: shortDay
            )
            .onHover { hovering in
                setCostPanelHover(hovering)
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
                try await self.switchAccountAndLaunchNewInstance(
                    account,
                    reason: .manual,
                    automatic: false,
                    forced: false
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
                _ = try await self.codexDesktopLaunchProbeService.launchNewInstance()
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
                _ = try await self.codexDesktopLaunchProbeService.launchNewInstance()
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
                    _ = try await self.codexDesktopLaunchProbeService.launchNewInstance()
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
        guard result.immediateEffectRecommendation == .launchNewInstance,
              let account = self.store.oauthAccount(accountID: result.targetAccountID) else {
            return
        }
        await self.activateAccount(
            account,
            trigger: .contextOverride(.launchNewInstance)
        )
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

    private func openSettingsWindow() {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "openai-settings",
            title: L.settingsWindowTitle,
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            SettingsWindowView(
                store: self.store,
                codexAppPathPanelService: self.codexAppPathPanelService
            ) {
                DetachedWindowPresenter.shared.close(id: "openai-settings")
            }
        }
    }

    private func openAddProviderWindow(defaultPreset: AddProviderPreset = .custom) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider",
            title: "Add Provider",
            size: CGSize(width: 520, height: 620)
        ) {
            AddProviderSheet(store: store, defaultPreset: defaultPreset) { preset, label, baseURL, accountLabel, apiKey, openRouterSelection in
                do {
                    switch preset {
                    case .custom:
                        try store.addCustomProvider(label: label, baseURL: baseURL, accountLabel: accountLabel, apiKey: apiKey)
                    case .openRouter:
                        guard let openRouterSelection else {
                            throw TokenStoreError.invalidInput
                        }
                        try store.addOpenRouterProvider(
                            apiKey: openRouterSelection.apiKey,
                            selectedModelID: openRouterSelection.selectedModelID,
                            pinnedModelIDs: openRouterSelection.pinnedModelIDs,
                            cachedModelCatalog: openRouterSelection.cachedModelCatalog,
                            fetchedAt: openRouterSelection.fetchedAt
                        )
                    }
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-provider")
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
                do {
                    try store.addCustomProviderAccount(providerID: provider.id, label: label, apiKey: apiKey)
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
            }
        }
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
        countdownTimerConnection?.cancel()
        countdownTimerConnection = countdownTimer.connect()
        runningThreadTimerConnection?.cancel()
        runningThreadTimerConnection = runningThreadTimer.connect()
        store.load()
        store.markActiveAccount()
        isProvidersExpanded = false
        refreshRunningThreadAttribution()
        triggerRefreshOnOpenIfNeeded()
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
        pendingCopiedOpenAIAccountGroupEmailHide?.cancel()
        pendingCopiedOpenAIAccountGroupEmailHide = nil
        copiedOpenAIAccountGroupEmail = nil
        isCostPanelPresented = false
        isCostSummaryHovered = false
        isCostPanelHovered = false
        DetachedWindowPresenter.shared.close(id: costPanelID)
    }

    private func triggerRefreshOnOpenIfNeeded() {
        guard openRefreshGate.shouldTriggerRefresh(isRefreshing: isRefreshing) else { return }
        Task { await refresh(force: true, announceResult: false) }
    }

    private func refresh(force: Bool = true, announceResult: Bool = false) async {
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
                refreshSessionCache: true
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
                refreshSessionCache: true
            )
        }
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(from: outcomes)
        )
    }

    private func refreshAccount(_ account: TokenAccount, announceResult: Bool) async {
        refreshingAccounts.insert(account.id)
        let outcome = await WhamService.shared.refreshOne(account: account, store: store)
        refreshingAccounts.remove(account.id)
        store.load()
        now = Date()
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(for: account, outcome: outcome)
        )
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
        let label = account.email.isEmpty ? account.accountId : account.email
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

    private func switchAccountAndLaunchNewInstance(
        _ account: TokenAccount,
        reason: AutoRoutingSwitchReason,
        automatic: Bool,
        forced: Bool
    ) async throws {
        let previousActiveAccount = self.store.activeAccount()

        do {
            try self.store.activate(
                account,
                reason: reason,
                automatic: automatic,
                forced: forced,
                protectedByManualGrace: false
            )

            _ = try await self.codexDesktopLaunchProbeService.launchNewInstance()
        } catch {
            if let previousActiveAccount,
               previousActiveAccount.accountId != account.accountId {
                try? self.store.activate(previousActiveAccount)
            }
            throw error
        }
    }

    private func refreshRunningThreadAttribution() {
        let now = Date()
        let service = self.runningThreadAttributionService

        self.runningThreadRefreshController.requestRefresh(now: now) { refreshDate in
            service.load(now: refreshDate)
        } apply: { attribution in
            self.runningThreadAttribution = attribution
        }
    }
}

private enum AddProviderPreset: String, CaseIterable, Identifiable {
    case custom
    case openRouter

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .custom:
            return "Custom"
        case .openRouter:
            return "OpenRouter"
        }
    }
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
                    .font(.system(size: 10))
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
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }

                List {
                    ForEach(self.filteredModels) { model in
                        Toggle(isOn: self.bindingForModel(model.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(model.id)
                                    .font(.system(size: 9))
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
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220, maxHeight: 260)
            }

            TextField("Manual model ID fallback (optional)", text: $manualModelID)
            Text(helperText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            if let note {
                Text(note)
                    .font(.system(size: 10))
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
    @State private var openRouterSelectedModelIDs: Set<String>
    @State private var openRouterManualModelID: String
    @State private var openRouterCachedModels: [CodexBarOpenRouterModel]
    @State private var openRouterFetchedAt: Date?

    let onSave: (AddProviderPreset, String, String, String, String, OpenRouterSelectionPayload?) -> Void
    let onCancel: () -> Void

    init(
        store: TokenStore,
        defaultPreset: AddProviderPreset = .custom,
        onSave: @escaping (AddProviderPreset, String, String, String, String, OpenRouterSelectionPayload?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let existingProvider = store.openRouterProvider
        self._preset = State(initialValue: defaultPreset)
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        self._openRouterSelectedModelIDs = State(initialValue: Set(existingProvider?.pinnedModelIDs ?? []))
        self._openRouterManualModelID = State(initialValue: existingProvider?.openRouterEffectiveModelID ?? "")
        self._openRouterCachedModels = State(initialValue: existingProvider?.cachedModelCatalog ?? [])
        self._openRouterFetchedAt = State(initialValue: existingProvider?.modelCatalogFetchedAt)
        if defaultPreset == .openRouter {
            self._label = State(initialValue: "OpenRouter")
        }
    }

    private var isOpenRouter: Bool {
        self.preset == .openRouter
    }

    private var canSave: Bool {
        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { return false }

        if self.isOpenRouter {
            return self.openRouterSelectionPayload != nil
        }

        return self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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

            if isOpenRouter {
                SecureField("API key", text: $apiKey)
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
                TextField("Provider name", text: $label)
                TextField("Base URL", text: $baseURL)
                TextField("Account label", text: $accountLabel)
                SecureField("API key", text: $apiKey)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(
                        preset,
                        label,
                        baseURL,
                        accountLabel,
                        apiKey,
                        self.isOpenRouter ? self.openRouterSelectionPayload : nil
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: self.isOpenRouter ? 460 : 360)
        .onChange(of: preset) { newValue in
            if newValue == .openRouter {
                self.label = "OpenRouter"
                self.baseURL = ""
            }
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
                .font(.system(size: 10))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActiveProvider ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)

                Text(provider.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActiveProvider ? .accentColor : .primary)

                Text(provider.openRouterEffectiveModelID ?? "No model selected")
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundColor(provider.openRouterEffectiveModelID == nil ? .orange : .secondary)
                    .cornerRadius(3)

                Spacer()

                Button(action: onAddAccount) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)

                Button(action: onEditModel) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
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
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .padding(.leading, 14)

            if self.orderedPinnedModelIDs.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(self.orderedPinnedModelIDs, id: \.self) { modelID in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(self.displayName(for: modelID))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(modelID)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if modelID == self.provider.openRouterEffectiveModelID {
                                Text("Current")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            } else {
                                Button("Use") {
                                    self.onSelectModel(modelID)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .font(.system(size: 9, weight: .medium))
                            }
                        }
                        .padding(.leading, 14)
                    }
                }
            } else if self.provider.openRouterEffectiveModelID == nil {
                HStack(spacing: 8) {
                    Text("No model configured yet.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)

                    Spacer()

                    Button("Set Model") {
                        self.onEditModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .font(.system(size: 9, weight: .semibold))
                }
                .padding(.leading, 14)
            }

            ForEach(provider.accounts) { account in
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(.system(size: 11, weight: account.id == activeAccountId ? .semibold : .regular))

                    if account.id == activeAccountId {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }

                    Spacer()

                    Text(account.maskedAPIKey)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if account.id != activeAccountId || isActiveProvider == false {
                        Button("Use") {
                            onActivate(account)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                        .disabled(provider.openRouterEffectiveModelID == nil)
                    }

                    Button {
                        onDeleteAccount(account)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActiveProvider ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
        )
    }
}
