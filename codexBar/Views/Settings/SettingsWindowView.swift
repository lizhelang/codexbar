import Combine
import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject private var store: TokenStore
    @ObservedObject private var updateCoordinator: UpdateCoordinator
    private let codexAppPathPanelService: CodexAppPathPanelService
    private let onClose: () -> Void

    @StateObject private var coordinator: SettingsWindowCoordinator
    @StateObject private var recordsModel: SettingsRecordsModel

    @MainActor
    init(
        store: TokenStore,
        updateCoordinator: UpdateCoordinator? = nil,
        codexAppPathPanelService: CodexAppPathPanelService,
        onClose: @escaping () -> Void
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._updateCoordinator = ObservedObject(wrappedValue: updateCoordinator ?? .shared)
        self.codexAppPathPanelService = codexAppPathPanelService
        self.onClose = onClose
        self._coordinator = StateObject(
            wrappedValue: SettingsWindowCoordinator(
                config: store.config,
                accounts: store.accounts,
                historicalModels: store.historicalModels
            )
        )
        self._recordsModel = StateObject(
            wrappedValue: SettingsRecordsModel(
                service: RecordsSnapshotService()
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                self.sidebar
            } detail: {
                self.detail
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let validationMessage = self.coordinator.validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()

                    Button(L.cancel) {
                        self.coordinator.cancelAndClose(onClose: self.onClose)
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(L.save) {
                        self.coordinator.saveAndClose(
                            using: self.store,
                            onClose: self.onClose
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.coordinator.hasChanges == false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var sidebar: some View {
        List(SettingsPage.allCases, selection: SettingsSidebarSelectionAdapter.binding(for: self.coordinator)) { page in
            SettingsSidebarRow(page: page)
                .tag(Optional(page))
                .contentShape(Rectangle())
                .onTapGesture {
                    SettingsSidebarSelectionAdapter.apply(page, to: self.coordinator)
                }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.settingsWindowTitle)
                        .font(.system(size: 20, weight: .semibold))
                    Text(L.settingsWindowHint)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch self.coordinator.selectedPage {
                case .accounts:
                    SettingsAccountsPage(
                        coordinator: self.coordinator,
                        codexAppPathPanelService: self.codexAppPathPanelService
                    )
                case .records:
                    SettingsRecordsPage(recordsModel: self.recordsModel) {
                        SettingsSidebarSelectionAdapter.apply(.usage, to: self.coordinator)
                    }
                case .usage:
                    SettingsUsagePage(coordinator: self.coordinator)
                case .updates:
                    SettingsUpdatesPage(updateCoordinator: self.updateCoordinator)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

private struct SettingsSidebarRow: View {
    let page: SettingsPage

    var body: some View {
        Label(self.page.title, systemImage: self.page.iconName)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private struct SettingsAccountsPage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let codexAppPathPanelService: CodexAppPathPanelService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsPage.accounts.title)
                .font(.system(size: 16, weight: .semibold))

            SettingsAccountUsageModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountUsageMode },
                    set: { self.coordinator.update(\.accountUsageMode, to: $0, field: .accountUsageMode) }
                )
            )

            if self.coordinator.showsGatewayCredentialModeSection {
                SettingsGatewayCredentialModeSection(
                    mode: Binding(
                        get: { self.coordinator.draft.gatewayCredentialMode },
                        set: { self.coordinator.update(\.gatewayCredentialMode, to: $0, field: .gatewayCredentialMode) }
                    )
                )
            }

            SettingsAccountOrderingModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountOrderingMode },
                    set: { self.coordinator.update(\.accountOrderingMode, to: $0, field: .accountOrderingMode) }
                )
            )

            if self.coordinator.showsManualActivationBehaviorSection {
                SettingsManualActivationBehaviorSection(
                    behavior: Binding(
                        get: { self.coordinator.draft.manualActivationBehavior },
                        set: { self.coordinator.update(\.manualActivationBehavior, to: $0, field: .manualActivationBehavior) }
                    ),
                    preferredCodexAppPath: Binding(
                        get: { self.coordinator.draft.preferredCodexAppPath },
                        set: { self.coordinator.update(\.preferredCodexAppPath, to: $0, field: .preferredCodexAppPath) }
                    ),
                    validationMessage: self.$coordinator.validationMessage,
                    codexAppPathPanelService: self.codexAppPathPanelService,
                    showsCodexAppPathSection: self.coordinator.showsCodexAppPathSection
                )
            }

            if self.coordinator.showsManualAccountOrderSection {
                SettingsAccountOrderSection(coordinator: self.coordinator)
            }
        }
    }
}

private struct SettingsUsagePage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsPage.usage.title)
                .font(.system(size: 16, weight: .semibold))

            SettingsUsageDisplayModeSection(
                usageDisplayMode: Binding(
                    get: { self.coordinator.draft.usageDisplayMode },
                    set: { self.coordinator.update(\.usageDisplayMode, to: $0, field: .usageDisplayMode) }
                )
            )

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

            SettingsModelPricingSection(coordinator: self.coordinator)
        }
    }
}

private struct SettingsUpdatesPage: View {
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
            Text(SettingsPage.updates.title)
                .font(.system(size: 16, weight: .semibold))

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
                .frame(width: 160, alignment: .leading)
            Text(self.value)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.mode == option ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SettingsManualActivationBehaviorSection: View {
    @Binding var behavior: CodexBarOpenAIManualActivationBehavior
    @Binding var preferredCodexAppPath: String?
    @Binding var validationMessage: String?

    let codexAppPathPanelService: CodexAppPathPanelService
    let showsCodexAppPathSection: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.manualActivationBehaviorTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.manualActivationBehaviorHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexBarOpenAIManualActivationBehavior.allCases) { option in
                    Button {
                        self.behavior = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: self.behavior == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(self.behavior == option ? .accentColor : .secondary)
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.behavior == option ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if self.showsCodexAppPathSection {
                SettingsCodexAppPathSection(
                    preferredCodexAppPath: self.$preferredCodexAppPath,
                    validationMessage: self.$validationMessage,
                    codexAppPathPanelService: self.codexAppPathPanelService
                )
            }
        }
    }
}

private struct SettingsGatewayCredentialModeSection: View {
    @Binding var mode: CodexBarOpenAIGatewayCredentialMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.gatewayCredentialModeTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.gatewayCredentialModeHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexBarOpenAIGatewayCredentialMode.allCases) { option in
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.mode == option ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                        )
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.mode == option ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
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

private struct SettingsCodexAppPathSection: View {
    @Binding var preferredCodexAppPath: String?
    @Binding var validationMessage: String?

    let codexAppPathPanelService: CodexAppPathPanelService

    private var status: CodexDesktopPreferredAppPathStatus {
        CodexDesktopLaunchProbeService.preferredAppPathStatus(for: self.preferredCodexAppPath)
    }

    private var displayedValue: String {
        switch self.status {
        case .automatic:
            return L.codexAppPathAutomaticStatus
        case .manualValid(let path), .manualInvalid(let path):
            return path
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L.codexAppPathTitle)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 72, alignment: .leading)

            Group {
                switch self.status {
                case .automatic:
                    Text(self.displayedValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                case .manualValid, .manualInvalid:
                    Text(self.displayedValue)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(self.statusColor)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: 0)

            Button(L.codexAppPathChooseAction) {
                self.chooseCodexApp()
            }

            if (self.preferredCodexAppPath ?? "").isEmpty == false {
                Button(L.codexAppPathResetAction) {
                    self.preferredCodexAppPath = nil
                    self.validationMessage = nil
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var statusColor: Color {
        switch self.status {
        case .automatic:
            return .secondary
        case .manualValid:
            return .primary
        case .manualInvalid:
            return .orange
        }
    }

    private func chooseCodexApp() {
        guard let selectedURL = self.codexAppPathPanelService.requestCodexAppURL(
            currentPath: self.preferredCodexAppPath
        ) else {
            return
        }

        guard let validatedURL = CodexDesktopLaunchProbeService.validatedPreferredCodexAppURL(
            from: selectedURL.path
        ) else {
            self.validationMessage = L.codexAppPathInvalidSelection
            return
        }

        self.preferredCodexAppPath = validatedURL.path
        self.validationMessage = nil
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

private struct SettingsModelPricingSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.modelPricingSectionTitle)
                .font(.system(size: 12, weight: .medium))

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
    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...10))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.model)
                .font(.system(size: 11, weight: .medium))
                .textSelection(.enabled)

            HStack(alignment: .top, spacing: 10) {
                self.priceField(
                    title: L.modelPricingInputTitle,
                    binding: Binding(
                        get: { self.pricing.inputUSDPerToken },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: $0,
                                cachedInputUSDPerToken: self.pricing.cachedInputUSDPerToken,
                                outputUSDPerToken: self.pricing.outputUSDPerToken
                            )
                        }
                    )
                )
                self.priceField(
                    title: L.modelPricingCachedInputTitle,
                    binding: Binding(
                        get: { self.pricing.cachedInputUSDPerToken },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: self.pricing.inputUSDPerToken,
                                cachedInputUSDPerToken: $0,
                                outputUSDPerToken: self.pricing.outputUSDPerToken
                            )
                        }
                    )
                )
                self.priceField(
                    title: L.modelPricingOutputTitle,
                    binding: Binding(
                        get: { self.pricing.outputUSDPerToken },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: self.pricing.inputUSDPerToken,
                                cachedInputUSDPerToken: self.pricing.cachedInputUSDPerToken,
                                outputUSDPerToken: $0
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
        case .accounts:
            return L.settingsAccountsPageTitle
        case .records:
            return L.settingsRecordsPageTitle
        case .usage:
            return L.settingsUsagePageTitle
        case .updates:
            return L.settingsUpdatesPageTitle
        }
    }

    var iconName: String {
        switch self {
        case .accounts:
            return "person.crop.circle"
        case .records:
            return "clock.arrow.circlepath"
        case .usage:
            return "chart.bar"
        case .updates:
            return "arrow.trianglehead.2.clockwise"
        }
    }
}

private extension CodexBarOpenAIManualActivationBehavior {
    var title: String {
        switch self {
        case .updateConfigOnly:
            return L.manualActivationUpdateConfigOnly
        case .launchNewInstance:
            return L.manualActivationLaunchNewInstance
        }
    }

    var detail: String {
        switch self {
        case .updateConfigOnly:
            return L.manualActivationUpdateConfigOnlyHint
        case .launchNewInstance:
            return L.manualActivationLaunchNewInstanceHint
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

private extension CodexBarOpenAIGatewayCredentialMode {
    var title: String {
        switch self {
        case .oauthPassthrough:
            return L.gatewayCredentialModeOAuthPassthrough
        case .localAPIKey:
            return L.gatewayCredentialModeLocalAPIKey
        }
    }

    var detail: String {
        switch self {
        case .oauthPassthrough:
            return L.gatewayCredentialModeOAuthPassthroughHint
        case .localAPIKey:
            return L.gatewayCredentialModeLocalAPIKeyHint
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
