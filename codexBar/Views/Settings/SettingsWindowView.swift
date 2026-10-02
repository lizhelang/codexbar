import AppKit
import Combine
import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject private var store: TokenStore
    @ObservedObject private var updateCoordinator: UpdateCoordinator
    @ObservedObject private var preferences = ApplicationPreferencesStore.shared
    private let onClose: () -> Void

    @StateObject private var coordinator: SettingsWindowCoordinator
    @State private var expandedPage: SettingsPage?

    @MainActor
    init(
        store: TokenStore,
        updateCoordinator: UpdateCoordinator? = nil,
        onClose: @escaping () -> Void
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._updateCoordinator = ObservedObject(wrappedValue: updateCoordinator ?? .shared)
        self.onClose = onClose
        self._coordinator = StateObject(
            wrappedValue: SettingsWindowCoordinator(
                config: store.config,
                accounts: store.accounts,
                historicalModels: store.historicalModels
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(height: 1)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        self.settingsGroup(L.zh ? "账户设置" : "ACCOUNT SETTINGS", pages: SettingsPage.accountPages)
                        self.settingsGroup(L.zh ? "应用设置" : "APPLICATION SETTINGS", pages: SettingsPage.applicationPages)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: self.coordinator.selectedPage) { page in
                    self.expandedPage = page
                }
                .onChange(of: self.expandedPage) { page in
                    guard let page else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        scrollProxy.scrollTo(page, anchor: .top)
                    }
                }
            }

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                if let validationMessage = self.coordinator.validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Text(L.zh ? "账户、额度及模型价格需保存；其余设置即时生效" : "Save account, quota and pricing edits; other preferences apply immediately")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SettingsPalette.muted)

                    Spacer()

                    Button(L.cancel) {
                        self.coordinator.cancelAndClose(onClose: self.onClose)
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)

                    Button(L.save) {
                        self.coordinator.saveAndClose(
                            using: self.store,
                            onClose: self.onClose
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(SettingsPalette.mint)
                    .foregroundStyle(SettingsPalette.canvas)
                    .disabled(self.coordinator.hasChanges == false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(SettingsPalette.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsPalette.canvas)
        .preferredColorScheme(self.preferences.preferences.theme == .system ? nil : (self.preferences.preferences.theme == .dark ? .dark : .light))
        .tint(SettingsPalette.mint)
        .onReceive(self.store.$config.dropFirst()) { config in
            self.coordinator.reconcileExternalState(
                config: config,
                accounts: self.store.accounts,
                historicalModels: self.store.historicalModels
            )
        }
        .onReceive(self.store.$accounts.dropFirst()) { accounts in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: accounts,
                historicalModels: self.store.historicalModels
            )
        }
        .onReceive(self.store.$historicalModels.dropFirst()) { historicalModels in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: self.store.accounts,
                historicalModels: historicalModels
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(L.settingsWindowTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SettingsPalette.foreground)
                Text(L.zh ? "账户与应用偏好" : "Accounts and application preferences")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(SettingsPalette.muted)
            }

            Spacer(minLength: 8)

            Text("CODEXBAR")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(SettingsPalette.muted)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func settingsGroup(_ title: String, pages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(SettingsPalette.muted)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(pages) { page in
                    self.accordionSection(for: page)
                        .id(page)
                    if page != pages.last {
                        SettingsPalette.divider.frame(height: 1)
                    }
                }
            }
            .background(SettingsPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SettingsPalette.divider, lineWidth: 1)
            }
        }
    }

    private func accordionSection(for page: SettingsPage) -> some View {
        let isExpanded = self.expandedPage == page

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        self.expandedPage = nil
                    } else {
                        self.expandedPage = page
                        SettingsSidebarSelectionAdapter.apply(page, to: self.coordinator)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: page.iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isExpanded ? SettingsPalette.mint : SettingsPalette.muted)
                        .frame(width: 22)

                    Text(page.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsPalette.foreground)

                    Spacer(minLength: 6)

                    Text(self.summary(for: page))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SettingsPalette.muted)
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPalette.muted)
                        .frame(width: 12)
                }
                .padding(.horizontal, 20)
                .frame(height: 54)
                .contentShape(Rectangle())
                .background(isExpanded ? SettingsPalette.cardRaised : SettingsPalette.card)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? [.isSelected] : [])

            if isExpanded {
                Rectangle()
                    .fill(SettingsPalette.divider)
                    .frame(height: 1)

                self.content(for: page)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
                    .background(SettingsPalette.content)
            }

        }
    }

    private func summary(for page: SettingsPage) -> String {
        switch page {
        case .accounts:
            return L.zh ? "\(self.store.accounts.count) 个账户" : "\(self.store.accounts.count) accounts"
        case .general:
            return L.zh ? "启动 · 更新 · 语言" : "Startup · Updates · Language"
        case .main:
            return L.zh ? "页面 · 模块 · 排序" : "Pages · Modules · Order"
        case .window:
            return L.zh ? "高度 · 行为" : "Height · Behavior"
        case .appearance:
            return L.zh ? "主题 · 显示" : "Theme · Display"
        case .tools:
            return L.zh ? "采集 · 导出 · 模型价格" : "Collection · Export · Pricing"
        case .usage:
            return L.zh ? "刷新 · 隐私 · 余量" : "Refresh · Privacy · Quota"
        case .subscriptions:
            return L.zh ? "套餐 · 费用 · 续订" : "Plans · Costs · Renewal"
        case .sync:
            return L.zh ? "本机 · 共享 · Hub" : "Local · Shared · Hub"
        }
    }

    @ViewBuilder
    private func content(for page: SettingsPage) -> some View {
        switch page {
        case .accounts:
            SettingsAccountsPage(
                store: self.store,
                coordinator: self.coordinator
            )
        case .general:
            SettingsGeneralPage(updateCoordinator: self.updateCoordinator)
        case .main:
            SettingsMainPage()
        case .window:
            SettingsPanelPage()
        case .appearance:
            SettingsAppearancePage(coordinator: self.coordinator)
        case .tools:
            SettingsToolsPage(coordinator: self.coordinator)
        case .usage:
            VStack(alignment: .leading, spacing: 0) {
                SettingsQuotaPreferencesPage()
                SettingsUsagePage(coordinator: self.coordinator)
            }
        case .subscriptions:
            SettingsSubscriptionsPage()
        case .sync:
            SettingsDeviceSyncPage()
        }
    }

}

@MainActor
enum SettingsSidebarSelectionAdapter {
    static func binding(for coordinator: SettingsWindowCoordinator) -> Binding<SettingsPage?> {
        Binding(
            get: { coordinator.selectedPage },
            set: { selection in
                self.apply(selection, to: coordinator)
            }
        )
    }

    static func apply(_ selection: SettingsPage?, to coordinator: SettingsWindowCoordinator) {
        guard let selection else { return }
        coordinator.selectedPage = selection
    }
}

@MainActor
enum SettingsPalette {
    private static var isDark: Bool {
        switch ApplicationPreferencesStore.shared.preferences.theme {
        case .dark: return true
        case .light: return false
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
    static var canvas: Color { self.isDark ? Color(red: 47.0 / 255, green: 52.0 / 255, blue: 55.0 / 255) : Color(white: 0.95) }
    static var card: Color { self.isDark ? Color(red: 52.0 / 255, green: 57.0 / 255, blue: 60.0 / 255) : .white }
    static var cardRaised: Color { self.isDark ? Color(red: 57.0 / 255, green: 62.0 / 255, blue: 65.0 / 255) : Color(white: 0.98) }
    static var content: Color { self.isDark ? Color(red: 48.0 / 255, green: 52.0 / 255, blue: 54.0 / 255) : .white }
    static var divider: Color { self.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.09) }
    static var mint: Color {
        switch ApplicationPreferencesStore.shared.preferences.accentColor {
        case .teal: return self.isDark ? Color(red: 182.0 / 255, green: 229.0 / 255, blue: 214.0 / 255) : Color(red: 0.12, green: 0.5, blue: 0.45)
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        }
    }
    static var foreground: Color { self.isDark ? Color(red: 236.0 / 255, green: 244.0 / 255, blue: 240.0 / 255) : Color(red: 0.13, green: 0.16, blue: 0.18) }
    static var muted: Color { self.isDark ? Color(red: 163.0 / 255, green: 169.0 / 255, blue: 172.0 / 255) : Color(red: 0.4, green: 0.43, blue: 0.47) }
}

struct SettingsContentCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) {
                SettingsPalette.divider
                    .frame(height: 1)
            }
    }
}

private struct SettingsAccountsPage: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var coordinator: SettingsWindowCoordinator

    private var quotaReservePercent: Binding<Int> {
        Binding(
            get: { self.coordinator.draft.reserveActiveAccountQuotaPercent },
            set: {
                self.coordinator.update(
                    \.reserveActiveAccountQuotaPercent,
                    to: CodexBarOpenAISettings.normalizedReserveActiveAccountQuotaPercent($0),
                    field: .reserveActiveAccountQuotaPercent
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.zh ? "Codex 账户与请求目标" : "Codex accounts and request targets")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(SettingsPalette.muted)
                .padding(.bottom, 6)

            SettingsAccountUsageModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountUsageMode },
                    set: { self.coordinator.update(\.accountUsageMode, to: $0, field: .accountUsageMode) }
                )
            )
            .modifier(SettingsContentCard())

            if self.coordinator.draft.accountUsageMode == .aggregateGateway {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L.reserveActiveAccountQuotaTitle, isOn: Binding(
                        get: { self.coordinator.draft.reserveActiveAccountQuota },
                        set: { self.coordinator.update(\.reserveActiveAccountQuota, to: $0, field: .reserveActiveAccountQuota) }
                    ))
                    .accessibilityIdentifier("codexbar.reserve-active-quota-toggle")
                    Stepper(value: self.quotaReservePercent, in: 1...100) {
                        HStack(spacing: 6) {
                            Text(L.reserveActiveAccountQuotaPercentTitle)
                            Spacer()
                            TextField("", value: self.quotaReservePercent, format: .number)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 48)
                                .accessibilityLabel(L.reserveActiveAccountQuotaPercentTitle)
                                .accessibilityIdentifier("codexbar.reserve-active-quota-percent-input")
                            Text("%")
                        }
                    }
                    .accessibilityIdentifier("codexbar.reserve-active-quota-percent-stepper")
                    Text(L.reserveActiveAccountQuotaHint(percent: self.coordinator.draft.reserveActiveAccountQuotaPercent))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .modifier(SettingsContentCard())
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(L.quotaWindowStartSettingTitle, isOn: Binding(
                    get: { self.coordinator.draft.showsQuotaWindowStart },
                    set: { self.coordinator.update(\.showsQuotaWindowStart, to: $0, field: .showsQuotaWindowStart) }
                ))
                .accessibilityIdentifier("codexbar.quota-window-start-toggle")
                Text(L.alignQuotaHint)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(SettingsContentCard())

            SettingsAggregateGatewayProxySection(
                proxyURL: Binding(
                    get: { self.coordinator.draft.aggregateGatewayProxyURL ?? "" },
                    set: {
                        self.coordinator.update(
                            \.aggregateGatewayProxyURL,
                            to: CodexBarOpenAISettings.normalizedAggregateGatewayProxyURL($0),
                            field: .aggregateGatewayProxyURL
                        )
                    }
                )
            )
            .modifier(SettingsContentCard())

            SettingsWebSocketSupportSection(
                mode: Binding(
                    get: { self.coordinator.draft.webSocketSupportOverride },
                    set: {
                        self.coordinator.update(
                            \.webSocketSupportOverride,
                            to: $0,
                            field: .webSocketSupportOverride
                        )
                    }
                )
            )
            .modifier(SettingsContentCard())

            SettingsAccountOrderingModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountOrderingMode },
                    set: { self.coordinator.update(\.accountOrderingMode, to: $0, field: .accountOrderingMode) }
                )
            )
            .modifier(SettingsContentCard())


            SettingsRemoteConnectionAccountSection(
                accounts: self.coordinator.remoteConnectionSelectableAccounts,
                remoteOnlyAccounts: self.coordinator.remoteConnectionAccounts,
                selectedAccountID: Binding(
                    get: { self.coordinator.draft.remoteConnectionAccountID },
                    set: { self.coordinator.update(\.remoteConnectionAccountID, to: $0, field: .remoteConnectionAccountID) }
                ),
                onLoginRemoteConnectionAccount: self.startRemoteConnectionLogin
            )
            .modifier(SettingsContentCard())

            SettingsHybridTargetSection(
                options: self.coordinator.draft.hybridTargetOptions,
                selection: Binding(
                    get: { self.coordinator.draft.hybridTargetSelection },
                    set: { self.coordinator.update(\.hybridTargetSelection, to: $0, field: .hybridTargetSelection) }
                )
            )
            .modifier(SettingsContentCard())

            if self.coordinator.showsManualAccountOrderSection {
                SettingsAccountOrderSection(coordinator: self.coordinator)
                    .modifier(SettingsContentCard())
            }
        }
    }

    private func startRemoteConnectionLogin() {
        OpenAILoginCoordinator.shared.startRemoteConnectionLogin { account in
            self.store.load()
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: self.store.accounts,
                historicalModels: self.store.historicalModels
            )
            self.coordinator.update(
                \.remoteConnectionAccountID,
                to: account.accountId,
                field: .remoteConnectionAccountID
            )
        }
    }
}

private struct SettingsUsagePage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.zh ? "Codex 额度显示与账户排序权重" : "Codex quota display and account sorting weights")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(SettingsPalette.muted)
                .padding(.bottom, 6)

            SettingsUsageDisplayModeSection(
                usageDisplayMode: Binding(
                    get: { self.coordinator.draft.usageDisplayMode },
                    set: { self.coordinator.update(\.usageDisplayMode, to: $0, field: .usageDisplayMode) }
                )
            )
            .modifier(SettingsContentCard())

            SettingsQuotaSortSection(
                plusRelativeWeight: Binding(
                    get: { self.coordinator.draft.plusRelativeWeight },
                    set: { self.coordinator.update(\.plusRelativeWeight, to: $0, field: .plusRelativeWeight) }
                ),
                proRelativeToPlusMultiplier: Binding(
                    get: { self.coordinator.draft.proRelativeToPlusMultiplier },
                    set: { self.coordinator.update(\.proRelativeToPlusMultiplier, to: $0, field: .proRelativeToPlusMultiplier) }
                ),
                teamRelativeToPlusMultiplier: Binding(
                    get: { self.coordinator.draft.teamRelativeToPlusMultiplier },
                    set: { self.coordinator.update(\.teamRelativeToPlusMultiplier, to: $0, field: .teamRelativeToPlusMultiplier) }
                )
            )
            .modifier(SettingsContentCard())

        }
    }
}

struct SettingsUpdatesPage: View {
    @ObservedObject var updateCoordinator: UpdateCoordinator

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var latestVersion: String {
        if let availability = self.updateCoordinator.pendingAvailability {
            return availability.release.version
        }
        switch self.updateCoordinator.state {
        case let .upToDate(_, checkedVersion):
            return checkedVersion
        case let .executing(availability):
            return availability.release.version
        case let .updateAvailable(availability):
            return availability.release.version
        case .idle, .checking, .failed:
            return L.settingsUpdatesUnknownVersion
        }
    }

    private var statusText: String {
        switch self.updateCoordinator.state {
        case .idle:
            return L.settingsUpdatesIdle
        case .checking:
            return L.settingsUpdatesChecking
        case let .upToDate(currentVersion, _):
            return L.settingsUpdatesUpToDate(currentVersion)
        case let .updateAvailable(availability):
            return L.settingsUpdatesAvailable(
                availability.currentVersion,
                availability.release.version
            )
        case let .executing(availability):
            return L.settingsUpdatesExecuting(availability.release.version)
        case let .failed(message):
            return L.settingsUpdatesFailed(message)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.settingsUpdatesPageHint)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                SettingsUpdatesInfoRow(
                    title: L.settingsUpdatesCurrentVersionTitle,
                    value: self.currentVersion
                )
                SettingsUpdatesInfoRow(
                    title: L.settingsUpdatesLatestVersionTitle,
                    value: self.latestVersion
                )
                SettingsUpdatesInfoRow(
                    title: L.settingsUpdatesStatusTitle,
                    value: self.statusText
                )
            }

            HStack(spacing: 10) {
                Button(L.settingsUpdatesCheckAction) {
                    Task { await self.updateCoordinator.checkForUpdates(trigger: .manual) }
                }
                .disabled(self.updateCoordinator.isChecking)

                if self.updateCoordinator.pendingAvailability != nil {
                    Button(L.settingsUpdatesInstallAction) {
                        Task { await self.updateCoordinator.handleToolbarAction() }
                    }
                    .disabled(self.updateCoordinator.isChecking)
                }
            }

            if self.updateCoordinator.isDownloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.zh ? "正在下载更新…" : "Downloading update…").font(.system(size: 11))
                }
            } else if let downloadedURL = self.updateCoordinator.downloadedUpdateURL {
                Button(L.zh ? "在 Finder 中显示下载的更新" : "Show downloaded update in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([downloadedURL])
                }
            } else if self.updateCoordinator.pendingAvailability != nil {
                Button(L.zh ? "下载更新" : "Download update") {
                    self.updateCoordinator.downloadPendingUpdate()
                }
            }
            if let downloadError = self.updateCoordinator.downloadError {
                Text(downloadError).font(.system(size: 11)).foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L.settingsUpdatesSourceNote)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L.settingsUpdatesReissueLimitNote)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsUpdatesInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(self.title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 140, alignment: .leading)
            Text(self.value)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            SettingsPalette.divider.frame(height: 1)
        }
    }
}

private struct SettingsAccountUsageModeSection: View {
    @Binding var mode: CodexBarOpenAIAccountUsageMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountUsageModeTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountUsageModeHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexBarOpenAIAccountUsageMode.allCases) { option in
                    Button {
                        self.mode = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: self.mode == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(self.mode == option ? .accentColor : .secondary)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(option.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            SettingsPalette.divider.frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SettingsAggregateGatewayProxySection: View {
    @Binding var proxyURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.aggregateGatewayProxyTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.aggregateGatewayProxyHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(L.aggregateGatewayProxyPlaceholder, text: self.$proxyURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: 320, alignment: .leading)
        }
    }
}

private struct SettingsWebSocketSupportSection: View {
    @Binding var mode: CodexWebSocketSupportOverride

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.webSocketSupportTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.webSocketSupportHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexWebSocketSupportOverride.allCases) { option in
                    Button {
                        self.mode = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: self.mode == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(self.mode == option ? .accentColor : .secondary)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(option.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            SettingsPalette.divider.frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SettingsAccountOrderingModeSection: View {
    @Binding var mode: CodexBarOpenAIAccountOrderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountOrderingModeTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountOrderingModeHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexBarOpenAIAccountOrderingMode.allCases) { option in
                    Button {
                        self.mode = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: self.mode == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(self.mode == option ? .accentColor : .secondary)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(option.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            SettingsPalette.divider.frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SettingsRemoteConnectionAccountSection: View {
    let accounts: [SettingsOpenAIAccountOrderItem]
    let remoteOnlyAccounts: [SettingsOpenAIAccountOrderItem]
    @Binding var selectedAccountID: String?
    let onLoginRemoteConnectionAccount: () -> Void

    private var selectableAccounts: [SettingsOpenAIAccountOrderItem] {
        var seen: Set<String> = []
        return (self.accounts + self.remoteOnlyAccounts).filter { seen.insert($0.id).inserted }
    }

    private var selectionOptions: [(String, String)] {
        var options = [("", L.remoteConnectionAccountDisabled)]
        options += self.accounts.map { ($0.id, $0.title) }
        options += self.remoteOnlyAccounts.map { ($0.id, L.remoteConnectionAccountRemoteOnlyOption($0.title)) }
        if let selectedAccountID,
           !self.selectableAccounts.contains(where: { $0.id == selectedAccountID }) {
            options.append((selectedAccountID, L.remoteConnectionAccountMissingOption(selectedAccountID)))
        }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.remoteConnectionAccountTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.remoteConnectionAccountHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.selectableAccounts.isEmpty {
                Text(L.remoteConnectionAccountEmpty)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            SettingsSelectionField(
                L.remoteConnectionAccountTitle,
                selection: Binding<String>(
                    get: { self.selectedAccountID ?? "" },
                    set: { self.selectedAccountID = $0.isEmpty ? nil : $0 }
                ),
                options: self.selectionOptions,
                showsLabel: false
            )
            .frame(maxWidth: 320, alignment: .leading)

            Button(L.remoteConnectionAccountLoginNew) {
                self.onLoginRemoteConnectionAccount()
            }
            .buttonStyle(.bordered)

            if let selectedAccountID,
               let account = self.selectableAccounts.first(where: { $0.id == selectedAccountID }) {
                Text(account.detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let selectedAccountID {
                Text(L.remoteConnectionAccountMissingDetail(selectedAccountID))
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct SettingsHybridTargetSection: View {
    let options: [SettingsHybridTargetOption]
    @Binding var selection: CodexBarHybridTargetSelection?

    private var selectionOptions: [(CodexBarHybridTargetSelection?, String)] {
        var choices: [(CodexBarHybridTargetSelection?, String)] = [(nil, L.requestTargetDisabled)]
        choices += self.options.map { (Optional($0.selection), $0.title) }
        if let selection, !self.options.contains(where: { $0.selection == selection }) {
            choices.append((selection, L.requestTargetDisabled))
        }
        return choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.requestTargetTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.requestTargetHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.options.isEmpty {
                Text(L.requestTargetEmpty)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            SettingsSelectionField(
                L.requestTargetTitle,
                selection: self.$selection,
                options: self.selectionOptions,
                showsLabel: false
            )
            .frame(maxWidth: 360, alignment: .leading)

            if let selection,
               let option = self.options.first(where: { $0.selection == selection }) {
                Text(option.detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct SettingsAccountOrderSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountOrderTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountOrderHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.coordinator.orderedAccounts.isEmpty {
                Text(L.noOpenAIAccountsForOrdering)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(self.coordinator.orderedAccounts.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 11, weight: .medium))
                                Text(item.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 6) {
                                Button(L.moveUp) {
                                    self.coordinator.moveAccount(accountID: item.id, offset: -1)
                                }
                                .disabled(index == 0)

                                Button(L.moveDown) {
                                    self.coordinator.moveAccount(accountID: item.id, offset: 1)
                                }
                                .disabled(index == self.coordinator.orderedAccounts.count - 1)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.06))
                        )
                    }
                }
            }
        }
    }
}

struct SettingsMenuBarDisplaySection: View {
    @Binding var showsUsageText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L.menuBarUsageTextTitle, isOn: self.$showsUsageText)

            Text(L.menuBarUsageTextHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

private struct SettingsUsageDisplayModeSection: View {
    @Binding var usageDisplayMode: CodexBarUsageDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.usageDisplayModeTitle)
                .font(.system(size: 12, weight: .medium))

            Picker(L.usageDisplayModeTitle, selection: self.$usageDisplayMode) {
                ForEach(CodexBarUsageDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct SettingsQuotaSortSection: View {
    @Binding var plusRelativeWeight: Double
    @Binding var proRelativeToPlusMultiplier: Double
    @Binding var teamRelativeToPlusMultiplier: Double

    private var proAbsoluteWeight: Double {
        self.plusRelativeWeight * self.proRelativeToPlusMultiplier
    }

    private var teamAbsoluteWeight: Double {
        self.plusRelativeWeight * self.teamRelativeToPlusMultiplier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.quotaSortSettingsTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.quotaSortSettingsHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortPlusWeightTitle)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(L.quotaSortPlusWeightValue(self.plusRelativeWeight))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: self.$plusRelativeWeight,
                    in: CodexBarOpenAISettings.QuotaSortSettings.plusRelativeWeightRange,
                    step: 0.5
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortProRatioTitle)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(
                        L.quotaSortProRatioValue(
                            self.proRelativeToPlusMultiplier,
                            absoluteProWeight: self.proAbsoluteWeight
                        )
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }

                Slider(
                    value: self.$proRelativeToPlusMultiplier,
                    in: CodexBarOpenAISettings.QuotaSortSettings.proRelativeToPlusRange,
                    step: 0.5
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortTeamRatioTitle)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(
                        L.quotaSortTeamRatioValue(
                            self.teamRelativeToPlusMultiplier,
                            absoluteTeamWeight: self.teamAbsoluteWeight
                        )
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }

                Slider(
                    value: self.$teamRelativeToPlusMultiplier,
                    in: CodexBarOpenAISettings.QuotaSortSettings.teamRelativeToPlusRange,
                    step: 0.1
                )
            }
        }
    }
}

struct SettingsModelPricingSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.zh ? "Codex 会话模型价格" : "Codex session model pricing")
                .font(.system(size: 12, weight: .medium))

            Text(L.zh ? "以下单价用于 Codex 会话的本地费用估算；其他工具保留其来源报告的费用。" : "These prices apply to local cost estimates for Codex sessions. Other tools retain costs reported by their sources.")
                .font(.system(size: 10))
                .foregroundStyle(SettingsPalette.muted)

            Text(L.modelPricingSectionHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.coordinator.historicalModels.isEmpty {
                Text(L.modelPricingSectionEmpty)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(self.coordinator.historicalModels, id: \.self) { model in
                        SettingsModelPricingRow(
                            model: model,
                            pricing: Binding(
                                get: { self.coordinator.draft.modelPricing[model] ?? .zero },
                                set: { self.coordinator.updateModelPricing(for: model, pricing: $0) }
                            )
                        )
                    }
                }
            }
        }
    }
}

private struct SettingsModelPricingRow: View {
    let model: String
    @Binding var pricing: CodexBarModelPricing

    private let fieldWidth: CGFloat = 120
    private let tokensPerUnit: Double = 1_000_000
    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...6))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.model)
                .font(.system(size: 11, weight: .medium))
                .textSelection(.enabled)

            HStack(alignment: .top, spacing: 10) {
                self.priceField(
                    title: L.modelPricingInputTitle,
                    binding: Binding(
                        get: { self.pricing.inputUSDPerToken * self.tokensPerUnit },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: $0 / self.tokensPerUnit,
                                cachedInputUSDPerToken: self.pricing.cachedInputUSDPerToken,
                                outputUSDPerToken: self.pricing.outputUSDPerToken
                            )
                        }
                    )
                )
                self.priceField(
                    title: L.modelPricingCachedInputTitle,
                    binding: Binding(
                        get: { self.pricing.cachedInputUSDPerToken * self.tokensPerUnit },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: self.pricing.inputUSDPerToken,
                                cachedInputUSDPerToken: $0 / self.tokensPerUnit,
                                outputUSDPerToken: self.pricing.outputUSDPerToken
                            )
                        }
                    )
                )
                self.priceField(
                    title: L.modelPricingOutputTitle,
                    binding: Binding(
                        get: { self.pricing.outputUSDPerToken * self.tokensPerUnit },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: self.pricing.inputUSDPerToken,
                                cachedInputUSDPerToken: self.pricing.cachedInputUSDPerToken,
                                outputUSDPerToken: $0 / self.tokensPerUnit
                            )
                        }
                    )
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func priceField(title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField(title, value: binding, format: self.numberFormat)
                .textFieldStyle(.roundedBorder)
                .frame(width: self.fieldWidth)
        }
    }
}

private extension SettingsPage {
    var title: String {
        switch self {
        case .accounts: return L.zh ? "账户与路由" : "Accounts and routing"
        case .general: return L.zh ? "常规" : "General"
        case .main: return L.zh ? "主画面" : "Main"
        case .window: return L.zh ? "窗口" : "Window"
        case .appearance: return L.zh ? "外观" : "Appearance"
        case .tools: return L.zh ? "AI 工具" : "AI Tools"
        case .usage: return L.zh ? "额度" : "Limits"
        case .subscriptions: return L.zh ? "订阅记录" : "Subscriptions"
        case .sync: return L.zh ? "多设备同步" : "Multi-device sync"
        }
    }

    var iconName: String {
        switch self {
        case .accounts: return "person.crop.circle"
        case .general: return "gearshape"
        case .main: return "rectangle.grid.1x2"
        case .window: return "macwindow"
        case .appearance: return "paintpalette"
        case .tools: return "square.grid.2x2"
        case .usage: return "gauge.with.needle"
        case .subscriptions: return "creditcard"
        case .sync: return "arrow.triangle.2.circlepath"
        }
    }
}

private extension CodexBarOpenAIAccountUsageMode {
    var title: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitch
        case .aggregateGateway:
            return L.accountUsageModeAggregate
        }
    }

    var detail: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitchHint
        case .aggregateGateway:
            return L.accountUsageModeAggregateHint
        }
    }
}

private extension CodexWebSocketSupportOverride {
    var title: String {
        switch self {
        case .automatic: return L.webSocketSupportAutomatic
        case .enabled: return L.webSocketSupportEnabled
        case .disabled: return L.webSocketSupportDisabled
        }
    }

    var detail: String {
        switch self {
        case .automatic: return L.webSocketSupportAutomaticDetail
        case .enabled: return L.webSocketSupportEnabledDetail
        case .disabled: return L.webSocketSupportDisabledDetail
        }
    }
}

private extension CodexBarOpenAIAccountOrderingMode {
    var title: String {
        switch self {
        case .quotaSort:
            return L.accountOrderingModeQuotaSort
        case .manual:
            return L.accountOrderingModeManual
        }
    }

    var detail: String {
        switch self {
        case .quotaSort:
            return L.accountOrderingModeQuotaSortHint
        case .manual:
            return L.accountOrderingModeManualHint
        }
    }
}
