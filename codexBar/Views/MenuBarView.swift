import AppKit
import Combine
import SwiftUI
import UserNotifications

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

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView)
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

    private let costPanelID = "cost-details-hover-panel"
    private let usageRefreshInterval = OpenAIUsagePollingService.defaultRefreshInterval
    private let visibleOpenAIAccountLimit = 5
    private let openAIAccountsInitialHeight: CGFloat = 260

    @State private var isRefreshing = false
    @State private var showError: String?
    @State private var showSuccess: String?
    @State private var now = Date()
    @State private var refreshingAccounts: Set<String> = []
    @State private var languageToggle = false
    @State private var isCostSummaryHovered = false
    @State private var isCostPanelHovered = false
    @State private var isCostPanelPresented = false
    @State private var didTriggerOpenRefresh = false
    @State private var pendingCostHide: DispatchWorkItem?
    @State private var costSummaryAnchorView: NSView?
    @State private var isProvidersExpanded = false
    @State private var countdownTimerConnection: Cancellable?

    private let countdownTimer = Timer.publish(every: 10, on: .main, in: .common)
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
        OpenAIAccountListLayout.groupedAccounts(from: store.accounts)
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
        .onReceive(countdownTimer) { _ in now = Date() }
        .onReceive(store.$localCostSummary) { _ in
            guard isCostPanelPresented else { return }
            showCostPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidSucceed)) { notification in
            showError = nil
            showSuccess = notification.userInfo?["message"] as? String ?? "Saved OpenAI account."
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidFail)) { notification in
            showSuccess = nil
            showError = notification.userInfo?["message"] as? String ?? "OpenAI login failed."
        }
        .onAppear {
            countdownTimerConnection?.cancel()
            countdownTimerConnection = countdownTimer.connect()
            store.markActiveAccount()
            isProvidersExpanded = false
            triggerRefreshOnOpenIfNeeded()
        }
        .onDisappear {
            countdownTimerConnection?.cancel()
            countdownTimerConnection = nil
            didTriggerOpenRefresh = false
            pendingCostHide?.cancel()
            pendingCostHide = nil
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
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let activeProvider = store.activeProvider,
               let activeAccount = store.activeProviderAccount {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(activeProvider.label) · \(activeAccount.label)")
                        .font(.system(size: 11, weight: .medium))
                    Text("Model: \(store.activeModel)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Changes apply to new sessions.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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

                    if !store.customProviders.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    isProvidersExpanded.toggle()
                                }
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
                                .padding(.leading, 4)
                                .padding(.trailing, 12)
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

                    openAIAccountsSection

                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            if let success = showSuccess {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
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

                Button {
                    startOAuthLogin()
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Login OpenAI Toolbar Button")
                .accessibilityIdentifier("codexbar.login-openai.toolbar")

                Button {
                    openAddProviderWindow()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)

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
    }

    @ViewBuilder
    private var openAIAccountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OpenAI Accounts")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)

                Spacer()

                Button("Login OpenAI") {
                    startOAuthLogin()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .font(.system(size: 10, weight: .medium))
                .accessibilityLabel("Login OpenAI Header Button")
                .accessibilityIdentifier("codexbar.login-openai.header")
            }

            if store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No OpenAI account added.")
                        .font(.system(size: 11, weight: .medium))
                    Text("Login to track quota and switch OpenAI OAuth accounts.")
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
    }

    @ViewBuilder
    private func openAIAccountGroupsView(_ groups: [OpenAIAccountGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.email)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 4)

                    ForEach(group.accounts) { account in
                        AccountRowView(
                            account: account,
                            isActive: account.isActive,
                            now: now,
                            isRefreshing: refreshingAccounts.contains(account.id)
                        ) {
                            activateAccount(account)
                        } onRefresh: {
                            Task { await refreshAccount(account) }
                        } onReauth: {
                            reauthAccount(account)
                        } onDelete: {
                            store.remove(account)
                        }
                    }
                }
            }
        }
        .padding(.trailing, 4)
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
        guard self.costSummaryAnchorView !== view else { return }
        self.costSummaryAnchorView = view
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

    private func activateAccount(_ account: TokenAccount) {
        do {
            try store.activate(account)
            store.refreshLocalCostSummary()
            showSuccess = "Updated Codex configuration. Changes apply to new sessions."
            Task { @MainActor in
                OpenAIUsagePollingService.shared.refreshNow()
            }
        } catch {
            showError = error.localizedDescription
        }
    }

    private func activateCompatibleProvider(providerID: String, accountID: String) {
        do {
            try store.activateCustomProvider(providerID: providerID, accountID: accountID)
            store.refreshLocalCostSummary()
            showSuccess = "Updated Codex configuration. Changes apply to new sessions."
        } catch {
            showError = error.localizedDescription
        }
    }

    private func deleteCompatibleAccount(providerID: String, accountID: String) {
        do {
            try store.removeCustomProviderAccount(providerID: providerID, accountID: accountID)
            showSuccess = "Removed provider account."
        } catch {
            showError = error.localizedDescription
        }
    }

    private func deleteProvider(providerID: String) {
        do {
            try store.removeCustomProvider(providerID: providerID)
            showSuccess = "Removed provider."
        } catch {
            showError = error.localizedDescription
        }
    }

    private func startOAuthLogin() {
        OpenAILoginCoordinator.shared.start()
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
                    showSuccess = "Updated Codex configuration. Changes apply to new sessions."
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
                    showSuccess = "Saved provider account."
                    DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
                } catch {
                    showError = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
            }
        }
    }

    private func autoSwitchIfNeeded() {
        guard let active = store.accounts.first(where: { $0.isActive }) else { return }

        let primary5hRemaining = 100.0 - active.primaryUsedPercent
        let secondary7dRemaining = 100.0 - active.secondaryUsedPercent
        let shouldSwitch = primary5hRemaining <= 10.0 || secondary7dRemaining <= 3.0
        guard shouldSwitch else { return }

        let candidates = store.accounts.filter {
            !$0.isSuspended && !$0.tokenExpired && $0.accountId != active.accountId
        }.sorted(by: OpenAIAccountListLayout.accountPrecedes)

        guard let best = candidates.first else {
            sendNotification(title: L.autoSwitchTitle, body: L.autoSwitchNoCandidates)
            return
        }

        do {
            try store.activate(best)
            sendAutoSwitchNotification(from: active, to: best)
        } catch {}
    }

    private func sendAutoSwitchNotification(from old: TokenAccount, to new: TokenAccount) {
        sendNotification(
            title: L.autoSwitchTitle,
            body: L.autoSwitchBody(old.organizationName ?? old.email, new.organizationName ?? new.email)
        )
    }

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "codexbar-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private func triggerRefreshOnOpenIfNeeded() {
        guard didTriggerOpenRefresh == false else { return }
        didTriggerOpenRefresh = true
        guard isRefreshing == false else { return }
        Task { await refresh(force: false) }
    }

    private func refresh(force: Bool = true) async {
        guard force || store.hasStaleOAuthUsageSnapshot(maxAge: usageRefreshInterval) else {
            store.refreshLocalCostSummary()
            return
        }

        guard store.beginAllUsageRefresh() else { return }
        isRefreshing = true
        defer {
            store.endAllUsageRefresh()
            isRefreshing = false
        }
        await WhamService.shared.refreshAll(store: store)
        store.refreshLocalCostSummary()
    }

    private func refreshAccount(_ account: TokenAccount) async {
        refreshingAccounts.insert(account.id)
        await WhamService.shared.refreshOne(account: account, store: store)
        refreshingAccounts.remove(account.id)
    }

    private func reauthAccount(_ account: TokenAccount) {
        oauth.startOAuth { result in
            switch result {
            case .success(let completion):
                store.load()
                Task { await WhamService.shared.refreshOne(account: completion.account, store: store) }
                showSuccess = completion.active
                    ? "Updated Codex configuration. Changes apply to new sessions."
                    : "Saved OpenAI account."
            case .failure(let error):
                showError = error.localizedDescription
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
