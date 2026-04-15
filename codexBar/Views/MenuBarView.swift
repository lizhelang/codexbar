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

private struct AdaptiveMenuScrollContainer<Content: View>: NSViewRepresentable {
    let heightLimit: AdaptiveScrollHeightLimit
    let initialHeight: CGFloat
    let content: Content

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.heightLimit = .fixed(maxHeight)
        self.initialHeight = maxHeight
        self.content = content()
    }

    init<MeasurementContent: View>(
        initialHeight: CGFloat,
        measuredHeight: @escaping () -> MeasurementContent,
        @ViewBuilder content: () -> Content
    ) {
        self.heightLimit = .measured(AnyView(measuredHeight()))
        self.initialHeight = initialHeight
        self.content = content()
    }

    func makeNSView(context: Context) -> AdaptiveMenuScrollHost {
        AdaptiveMenuScrollHost(rootView: AnyView(content), heightLimit: heightLimit, initialHeight: initialHeight)
    }

    func updateNSView(_ nsView: AdaptiveMenuScrollHost, context: Context) {
        nsView.update(rootView: AnyView(content), heightLimit: heightLimit)
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

private final class AdaptiveMenuScrollHost: NSView {
    private let scrollView = ActivityAwareScrollView()
    private let displayHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let measuringHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let limitHostingView = NSHostingView(rootView: AnyView(EmptyView()))

    private var heightLimit: AdaptiveScrollHeightLimit
    private var measuredHeight: CGFloat
    private var isMeasuring = false
    private var lastMeasuredWidth: CGFloat = 0
    private var hideScrollerWorkItem: DispatchWorkItem?

    private let idleScrollerAlpha: CGFloat = 0
    private let visibleScrollerAlpha: CGFloat = 0.95
    private let scrollerHideDelay: TimeInterval = 0.9

    init(rootView: AnyView, heightLimit: AdaptiveScrollHeightLimit, initialHeight: CGFloat) {
        self.heightLimit = heightLimit
        self.measuredHeight = max(initialHeight, 1)
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
        self.update(rootView: rootView, heightLimit: heightLimit)
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

    func update(rootView: AnyView, heightLimit: AdaptiveScrollHeightLimit) {
        self.heightLimit = heightLimit
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
    @State private var showError: String?
    @State private var now = Date()
    @State private var runningThreadAttribution = OpenAIRunningThreadAttribution.empty
    @State private var runningThreadAttributionRefreshSequence = 0
    @State private var refreshingAccounts: Set<String> = []
    @State private var copiedOpenAIAccountGroupEmail: String?
    @State private var languageToggle = false
    @State private var isCostSummaryHovered = false
    @State private var isCostPanelHovered = false
    @State private var isCostPanelPresented = false
    @State private var didTriggerOpenRefresh = false
    @State private var pendingCostHide: DispatchWorkItem?
    @State private var pendingCopiedOpenAIAccountGroupEmailHide: DispatchWorkItem?
    @State private var costSummaryAnchorView: NSView?
    @State private var isProvidersExpanded = false
    @State private var countdownTimerConnection: Cancellable?
    @State private var runningThreadTimerConnection: Cancellable?

    private let countdownTimer = Timer.publish(every: 10, on: .main, in: .common)
    private let runningThreadTimer = Timer.publish(every: 1, on: .main, in: .common)
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

    private var visibleGroupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.visibleGroups(
            from: groupedAccounts,
            maxAccounts: visibleOpenAIAccountLimit
        )
    }

    private var availableCount: Int {
        store.accounts.filter { $0.usageStatus == .ok }.count
    }

    private var isCompletelyEmpty: Bool {
        store.accounts.isEmpty && store.customProviders.isEmpty
    }

    private var maxMenuHeight: CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? 900
        return max(260, visibleHeight - 40)
    }

    var body: some View {
        mainMenuContent
        .frame(width: 300)
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
            showError = nil
            refreshRunningThreadAttribution()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidFail)) { notification in
            showError = notification.userInfo?["message"] as? String ?? "OpenAI login failed."
        }
        .onAppear {
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
        .onDisappear {
            runningThreadAttributionRefreshSequence += 1
            countdownTimerConnection?.cancel()
            countdownTimerConnection = nil
            runningThreadTimerConnection?.cancel()
            runningThreadTimerConnection = nil
            didTriggerOpenRefresh = false
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
    }

    @ViewBuilder
    private var mainMenuContent: some View {
        AdaptiveMenuScrollContainer(maxHeight: maxMenuHeight) {
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

                if !store.accounts.isEmpty {
                    Text(L.available(availableCount, store.accounts.count))
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(availableCount > 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                        .foregroundColor(availableCount > 0 ? .green : .red)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.activeProviderSummaryTitle(activeProvider: activeProvider, activeAccount: activeAccount))
                        .font(.system(size: 11, weight: .medium))
                    Text("Model: \(store.activeModel)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
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
                    Text("Add an OpenAI account or create a custom provider.")
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

            if let error = showError {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        showError = nil
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
                    CodexBarInterprocess.postTerminatePrimary()
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

    @ViewBuilder
    private var openAIAccountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("OpenAI Accounts")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

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
                    }
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
        if !store.customProviders.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isProvidersExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Providers")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        Spacer()

                        Text("\(store.customProviders.count)")
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
                            activateCompatibleProvider(providerID: provider.id, accountID: account.id)
                        } onAddAccount: {
                            openAddProviderAccountWindow(provider: provider)
                        } onDeleteAccount: { account in
                            deleteCompatibleAccount(providerID: provider.id, accountID: account.id)
                        } onDeleteProvider: {
                            deleteProvider(providerID: provider.id)
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
            _ = try await OpenAIManualActivationExecutor.execute(
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
                    forced: false,
                    closeExistingCodexApps: false
                )
            }

            self.store.refreshLocalCostSummary()
            self.refreshRunningThreadAttribution()
            self.showError = nil
            Task { @MainActor in
                OpenAIUsagePollingService.shared.refreshNow()
            }
        } catch {
            self.showError = error.localizedDescription
        }
    }

    private func activateCompatibleProvider(providerID: String, accountID: String) {
        do {
            try store.activateCustomProvider(providerID: providerID, accountID: accountID)
            store.refreshLocalCostSummary()
            showError = nil
        } catch {
            showError = error.localizedDescription
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
            self.showError = nil
        } catch {
            self.showError = error.localizedDescription
        }
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
            showError = nil
        } catch {
            showError = error.localizedDescription
        }
    }

    private func deleteProvider(providerID: String) {
        do {
            try store.removeCustomProvider(providerID: providerID)
            showError = nil
        } catch {
            showError = error.localizedDescription
        }
    }

    private func startOAuthLogin() {
        OpenAILoginCoordinator.shared.start()
    }

    private func exportOpenAIAccountsCSV() {
        do {
            let accounts = try self.oauthAccountService.exportAccounts()
            guard accounts.isEmpty == false else {
                self.showError = L.noOpenAIAccountsToExport
                return
            }

            guard let exportURL = self.openAIAccountCSVPanelService.requestExportURL() else {
                return
            }

            let csv = self.openAIAccountCSVService.makeCSV(from: accounts)
            try csv.write(to: exportURL, atomically: true, encoding: .utf8)
            self.showError = nil
        } catch {
            self.showError = error.localizedDescription
        }
    }

    private func importOpenAIAccountsCSV() {
        do {
            guard let importURL = self.openAIAccountCSVPanelService.requestImportURL() else {
                return
            }

            let csvText = try String(contentsOf: importURL, encoding: .utf8)
            let parsed = try self.openAIAccountCSVService.parseCSV(csvText)
            let result = try self.oauthAccountService.importAccounts(
                parsed.accounts,
                activeAccountID: parsed.activeAccountID
            )

            self.store.load()
            self.store.refreshLocalCostSummary()
            self.refreshRunningThreadAttribution()
            self.showError = nil
            self.refreshImportedAccounts(accountIDs: result.importedAccountIDs)
        } catch {
            self.showError = error.localizedDescription
        }
    }

    private func openSettingsWindow() {
        DetachedWindowPresenter.shared.show(
            id: "openai-settings",
            title: L.settingsWindowTitle,
            size: CGSize(width: 820, height: 620)
        ) {
            SettingsWindowView(
                store: self.store,
                codexAppPathPanelService: self.codexAppPathPanelService
            ) {
                DetachedWindowPresenter.shared.close(id: "openai-settings")
            }
        }
    }

    private func openAddProviderWindow() {
        DetachedWindowPresenter.shared.show(
            id: "add-provider",
            title: "Add Provider",
            size: CGSize(width: 420, height: 320)
        ) {
            AddProviderSheet { label, baseURL, accountLabel, apiKey in
                do {
                    try store.addCustomProvider(label: label, baseURL: baseURL, accountLabel: accountLabel, apiKey: apiKey)
                    showError = nil
                    DetachedWindowPresenter.shared.close(id: "add-provider")
                } catch {
                    showError = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider")
            }
        }
    }

    private func openAddProviderAccountWindow(provider: CodexBarProvider) {
        DetachedWindowPresenter.shared.show(
            id: "add-provider-account-\(provider.id)",
            title: "Add Account",
            size: CGSize(width: 400, height: 220)
        ) {
            AddProviderAccountSheet(provider: provider) { label, apiKey in
                do {
                    try store.addCustomProviderAccount(providerID: provider.id, label: label, apiKey: apiKey)
                    showError = nil
                    DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
                } catch {
                    showError = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
            }
        }
    }

    private func triggerRefreshOnOpenIfNeeded() {
        guard didTriggerOpenRefresh == false else { return }
        didTriggerOpenRefresh = true
        guard isRefreshing == false else { return }
        Task { await refresh(force: true, announceResult: false) }
    }

    private func refresh(force: Bool = true, announceResult: Bool = false) async {
        guard force || store.hasStaleOAuthUsageSnapshot(maxAge: usageRefreshInterval) else {
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
        store.refreshLocalCostSummary()
        refreshRunningThreadAttribution()
        if announceResult, let message = self.refreshFailureMessage(from: outcomes) {
            showError = message
        }
    }

    private func refreshAccount(_ account: TokenAccount, announceResult: Bool) async {
        refreshingAccounts.insert(account.id)
        let outcome = await WhamService.shared.refreshOne(account: account, store: store)
        refreshingAccounts.remove(account.id)
        store.load()
        now = Date()
        refreshRunningThreadAttribution()
        if announceResult, let message = self.refreshFailureMessage(for: account, outcome: outcome) {
            showError = message
        }
    }

    private func reauthAccount(_: TokenAccount) {
        self.startOAuthLogin()
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
        forced: Bool,
        closeExistingCodexApps: Bool
    ) async throws {
        let previousActiveAccount = self.store.activeAccount()
        let existingCodexPIDs = Set(
            closeExistingCodexApps
                ? self.codexDesktopLaunchProbeService.runningCodexApplications().map(\.processIdentifier)
                : []
        )

        do {
            try self.store.activate(
                account,
                reason: reason,
                automatic: automatic,
                forced: forced,
                protectedByManualGrace: false
            )

            let launchedApplication = try await self.codexDesktopLaunchProbeService.launchNewInstance()
            if closeExistingCodexApps {
                var priorPIDs = existingCodexPIDs
                if let launchedPID = launchedApplication?.processIdentifier {
                    priorPIDs.remove(launchedPID)
                }
                self.codexDesktopLaunchProbeService.terminateApplications(
                    withProcessIdentifiers: priorPIDs
                )
            }
        } catch {
            if let previousActiveAccount,
               previousActiveAccount.accountId != account.accountId {
                try? self.store.activate(previousActiveAccount)
            }
            throw error
        }
    }

    private func refreshRunningThreadAttribution() {
        // Runtime sqlite scans stay off-main so the menu keeps responding while
        // polling short-window thread activity from Codex App / CLI / subagents.
        self.runningThreadAttributionRefreshSequence += 1
        let sequence = self.runningThreadAttributionRefreshSequence
        let now = Date()
        let service = self.runningThreadAttributionService

        DispatchQueue.global(qos: .utility).async {
            let attribution = service.load(now: now)

            DispatchQueue.main.async {
                guard sequence == self.runningThreadAttributionRefreshSequence else { return }
                self.runningThreadAttribution = attribution
            }
        }
    }
}

private struct AddProviderSheet: View {
    @State private var label = ""
    @State private var baseURL = ""
    @State private var accountLabel = ""
    @State private var apiKey = ""

    let onSave: (String, String, String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Provider")
                .font(.headline)

            TextField("Provider name", text: $label)
            TextField("Base URL", text: $baseURL)
            TextField("Account label", text: $accountLabel)
            SecureField("API key", text: $apiKey)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(label, baseURL, accountLabel, apiKey)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
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
