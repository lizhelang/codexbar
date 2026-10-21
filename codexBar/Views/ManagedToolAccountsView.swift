import AppKit
import SwiftUI

/// Native account controls adapted from Token Monitor's provider-specific flows.
/// Authentication capabilities remain specific to each provider; local history is software-wide.
@MainActor
struct ManagedToolAccountsView: View {
    let client: ToolUsageClient
    @ObservedObject var cursorAccounts: CursorAccountStore
    @ObservedObject var connections: ToolConnectionStore
    @ObservedObject var preferencesStore: ApplicationPreferencesStore
    @ObservedObject var toolUsageStore: ToolUsageStore
    var importCursorCSV: (() -> Void)?
    var showLocalUsage: (() -> Void)?
    var onClose: (() -> Void)?
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var isInline: Bool = false

    @State private var showsSettings = false
    @State private var form: AccountForm?
    @State private var notice: String?
    @State private var expandedUsageAccounts: Set<String> = []
    @State private var isConnectingDSH = false

    private var enabled: Bool { !self.preferencesStore.preferences.disabledTools.contains(self.client.rawValue) }
    private var busy: Bool { self.client == .cursor ? self.cursorAccounts.isDiscovering || self.cursorAccounts.isAdding : self.connections.isRefreshing }

    var body: some View {
        Group {
            if self.isInline {
                self.accountContent
                    .foregroundStyle(MenuSurface.foreground)
                    .modifier(ManagedToolInlineControlsStyle())
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(self.client.displayName).font(.system(size: 18, weight: .semibold))
                            Text(L.zh ? "账号与额度" : "Accounts and limits")
                                .font(.system(size: 11)).foregroundStyle(SettingsPalette.muted)
                        }
                        Spacer()
                        self.settingsButton
                        Button(L.zh ? "完成" : "Done") { self.onClose?() }
                            .accessibilityIdentifier(self.identifier("done"))
                    }.padding(20)
                    SettingsPalette.divider.frame(height: 1)
                    ScrollView { self.accountContent.padding(20) }
                }
                .foregroundStyle(SettingsPalette.foreground).background(SettingsPalette.canvas)
                .frame(minWidth: 460, idealWidth: 560, minHeight: 520, idealHeight: 680)
            }
        }
        .sheet(isPresented: self.$showsSettings) {
            ToolConnectionManagementView(client: self.client, preferencesStore: self.preferencesStore,
                toolUsageStore: self.toolUsageStore, importCursorCSV: self.importCursorCSV,
                onClose: { self.showsSettings = false })
        }
        .sheet(item: self.$form) { form in
            ManagedToolAccountForm(client: self.client, form: form, cursorAccounts: self.cursorAccounts,
                connections: self.connections, onDone: { self.form = nil })
        }
        .task { await self.discover(); await self.refresh(force: false) }
    }

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: self.isInline ? 10 : 18) {
            self.collectionToolbar
            if self.isInline {
                HStack(spacing: 14) {
                    self.discoveryButton
                    self.refreshButton
                    Spacer(minLength: 0)
                    self.addButton
                }
                .font(self.contentFont(10))
            }
            self.note(self.sourceDescription)
            if !self.isInline { self.addButton }
            if self.client == .deepSeekHarness && !self.connections.profiles(for: self.client).contains(where: { $0.providerKind == .dshOfficialAPI }) {
                Button(L.zh ? "连接 DSH 中的 DeepSeek 官方账号" : "Connect DSH's official DeepSeek account") {
                    Task { await self.connectDSHOfficialAccount() }
                }
                .disabled(!self.enabled || self.busy || self.isConnectingDSH)
                .accessibilityIdentifier(self.identifier("connect-dsh-official"))
            }
            HStack(spacing: 12) {
                Button(L.zh ? "打开登录页面" : "Open sign-in page") { self.openURL(self.loginURL) }
                    .accessibilityIdentifier(self.identifier("open-login"))
                Spacer(minLength: 0)
                self.restoreSourcesMenu
            }
            .font(self.contentFont(self.isInline ? 9 : 12))
            if let detail = self.notice ?? (self.client == .cursor ? self.cursorAccounts.status : self.connections.statusDetail) {
                Text(detail).font(self.contentFont(self.isInline ? 9 : 11)).foregroundStyle(self.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(self.identifier("status"))
            }
            if self.client == .cursor {
                if self.cursorAccounts.accounts.isEmpty { self.emptyAccounts }
                ForEach(self.cursorAccounts.accounts) { account in self.cursorRow(account) }
            } else {
                if self.connections.profiles(for: self.client).isEmpty { self.emptyAccounts }
                ForEach(self.connections.profiles(for: self.client)) { profile in self.connectionRow(profile) }
            }
            if self.client != .cursor { self.localUsageContent }
        }
        .font(self.contentFont(self.isInline ? 10 : 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var collectionToolbar: some View {
        HStack(spacing: 12) {
            Toggle(L.zh ? "监测此软件" : (self.isInline ? "Monitor app" : "Monitor this app"), isOn: Binding(
                get: { self.enabled },
                set: { enabled in
                    self.preferencesStore.update {
                        $0.disabledTools.removeAll { $0 == self.client.rawValue }
                        if !enabled { $0.disabledTools.append(self.client.rawValue) }
                    }
                }
            ))
            .toggleStyle(.switch).controlSize(.small)
            .foregroundStyle(self.muted)
            .accessibilityIdentifier(self.identifier("enabled"))
            Spacer(minLength: 0)
            if self.isInline {
                self.settingsButton
            } else {
                self.discoveryButton
                self.refreshButton
            }
        }.font(self.contentFont(self.isInline ? 9 : 12))
    }

    private var settingsButton: some View {
        Button(L.zh ? "读取设置" : "Collection settings") { self.presentSettings() }
            .accessibilityIdentifier(self.identifier("settings"))
    }

    private var discoveryButton: some View {
        Button(L.zh ? "自动识别" : "Discover") { Task { await self.discover() } }
            .disabled(!self.enabled || self.busy)
            .accessibilityIdentifier(self.identifier("discover"))
    }

    private var refreshButton: some View {
        Button(L.zh ? "刷新" : "Refresh") { Task { await self.refresh() } }
            .disabled(!self.enabled || self.busy)
            .accessibilityIdentifier(self.identifier("refresh"))
    }

    private var addButton: some View {
        Button(self.addTitle) { self.presentForm(AccountForm(kind: .credential)) }
            .disabled(!self.enabled)
            .accessibilityIdentifier(self.identifier("add"))
    }

    private func presentSettings() {
        if self.isInline {
            let windowID = "tool-collection-settings-\(self.client.rawValue)"
            NotificationCenter.default.post(name: .codexbarRequestCloseStatusItemMenu, object: nil)
            DetachedWindowPresenter.shared.show(
                id: windowID,
                title: self.client.displayName + (L.zh ? " 读取设置" : " Settings"),
                size: CGSize(width: 520, height: 520)
            ) {
                ToolConnectionManagementView(
                    client: self.client,
                    preferencesStore: self.preferencesStore,
                    toolUsageStore: self.toolUsageStore,
                    importCursorCSV: self.importCursorCSV,
                    onClose: { DetachedWindowPresenter.shared.close(id: windowID) }
                )
            }
        } else {
            self.showsSettings = true
        }
    }

    private func presentForm(_ form: AccountForm) {
        if self.isInline {
            Self.presentDetachedForm(
                client: self.client,
                form: form,
                cursorAccounts: self.cursorAccounts,
                connections: self.connections,
                openURL: self.openURL
            )
        } else {
            self.form = form
        }
    }

    static func presentDetachedSettings(
        client: ToolUsageClient,
        preferencesStore: ApplicationPreferencesStore,
        toolUsageStore: ToolUsageStore,
        importCursorCSV: (() -> Void)? = nil
    ) {
        let windowID = "tool-collection-settings-\(client.rawValue)"
        NotificationCenter.default.post(name: .codexbarRequestCloseStatusItemMenu, object: nil)
        DetachedWindowPresenter.shared.show(
            id: windowID,
            title: client.displayName + (L.zh ? " 读取设置" : " Settings"),
            size: CGSize(width: 520, height: 520)
        ) {
            ToolConnectionManagementView(
                client: client,
                preferencesStore: preferencesStore,
                toolUsageStore: toolUsageStore,
                importCursorCSV: importCursorCSV,
                onClose: { DetachedWindowPresenter.shared.close(id: windowID) }
            )
        }
    }

    static func presentDetachedAccountForm(
        client: ToolUsageClient,
        cursorAccounts: CursorAccountStore,
        connections: ToolConnectionStore,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.presentDetachedForm(
            client: client,
            form: AccountForm(kind: .credential),
            cursorAccounts: cursorAccounts,
            connections: connections,
            openURL: openURL
        )
    }

    /// 菜单栏 Cursor 账号卡片使用：修改名称或更新某个已有账号的登录凭据。
    static func presentDetachedCursorAccountForm(
        accountID: String,
        alias: String,
        rename: Bool,
        cursorAccounts: CursorAccountStore,
        connections: ToolConnectionStore
    ) {
        self.presentDetachedForm(
            client: .cursor,
            form: AccountForm(kind: rename ? .rename : .credential, accountID: accountID, label: alias),
            cursorAccounts: cursorAccounts,
            connections: connections
        )
    }

    fileprivate static func presentDetachedForm(
        client: ToolUsageClient,
        form: AccountForm,
        cursorAccounts: CursorAccountStore,
        connections: ToolConnectionStore,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        let windowID = "tool-account-form-\(client.rawValue)"
        let title = form.kind == .rename
            ? (L.zh ? "修改名称" : "Rename")
            : form.kind == .transfer
            ? (L.zh ? "移动账号凭据" : "Move account credential")
            : client.displayName + (L.zh ? " 接入" : " connection")
        NotificationCenter.default.post(name: .codexbarRequestCloseStatusItemMenu, object: nil)
        DetachedWindowPresenter.shared.show(
            id: windowID,
            title: title,
            size: CGSize(width: 480, height: client == .claudeCode && form.kind == .credential ? 480 : 320)
        ) {
            ManagedToolAccountForm(
                client: client,
                form: form,
                cursorAccounts: cursorAccounts,
                connections: connections,
                openURL: openURL,
                onDone: { DetachedWindowPresenter.shared.close(id: windowID) }
            )
        }
    }

    @ViewBuilder private var restoreSourcesMenu: some View {
        if self.client != .cursor, !self.connections.hiddenProfiles(for: self.client).isEmpty {
            Menu(L.zh ? "恢复已隐藏来源" : "Restore hidden sources") {
                ForEach(self.connections.hiddenProfiles(for: self.client)) { profile in
                    Button(profile.label) { self.perform { try self.connections.restoreAutomaticSource(profile.id) } }
                        .accessibilityIdentifier(self.identifier("restore.\(profile.id)"))
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier(self.identifier("restore-hidden"))
        }
    }

    private var localUsageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.divider.frame(height: 1)
            Text(L.zh ? "本地软件用量" : "Local app usage").font(self.contentFont(self.isInline ? 10 : 12, weight: .semibold))
            self.note(L.zh
                ? "本地历史按软件汇总；未识别账号的记录不归入某个手动账号。上方额度按各连接查询。"
                : "Local history belongs to the app. Unidentified records are not assigned to a manual account; limits above are queried per connection.")
            Button(L.zh ? "查看本地用量" : "View local usage") { self.showLocalUsage?() }
                .accessibilityIdentifier(self.identifier("local-usage"))
        }
    }

    private var muted: Color { self.isInline ? MenuSurface.muted : SettingsPalette.muted }
    private var divider: Color { self.isInline ? MenuSurface.line : SettingsPalette.divider }
    private func contentFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        self.isInline ? MenuSurface.font(size: size, weight: weight, design: design) : .system(size: size, weight: weight, design: design)
    }
    @ViewBuilder private func note(_ text: String) -> some View {
        if self.isInline {
            Text(text).font(self.contentFont(9)).foregroundStyle(self.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else { SettingsPreferenceNote(text) }
    }

    private var emptyAccounts: some View {
        Text(L.zh ? "尚未连接账号。可自动识别本机登录，或在上方添加支持的凭据。"
             : "No connected account. Discover a local sign-in or add supported credentials above.")
            .foregroundStyle(self.muted).padding(.vertical, self.isInline ? 8 : 16)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(self.identifier("empty"))
    }

    private func cursorRow(_ account: CursorManagedAccount) -> some View {
        let state = self.cursorAccounts.states[account.id]
        return VStack(alignment: .leading, spacing: self.isInline ? 8 : 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName).font(self.contentFont(self.isInline ? 11 : 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    if let email = account.email, email != account.displayName {
                        Text(email).font(self.contentFont(self.isInline ? 9 : 11)).foregroundStyle(self.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text(account.isDesktop ? (L.zh ? "桌面端自动识别" : "Discovered on desktop") : (L.zh ? "手动添加" : "Manually added"))
                        .font(self.contentFont(self.isInline ? 9 : 10)).foregroundStyle(self.muted)
                }
                if let plan = account.planType {
                    Text(plan.uppercased()).font(self.contentFont(self.isInline ? 9 : 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(self.muted).lineLimit(1)
                }
                Menu {
                    Button(L.zh ? "修改名称" : "Rename") { self.presentForm(AccountForm(kind: .rename, accountID: account.id, label: account.alias)) }
                        .accessibilityIdentifier(self.identifier("account.\(account.id).rename"))
                    if !account.isDesktop {
                        Button(L.zh ? "更新凭据" : "Update credentials") { self.presentForm(AccountForm(kind: .credential, accountID: account.id, label: account.alias)) }
                            .accessibilityIdentifier(self.identifier("account.\(account.id).credential"))
                        Button(L.zh ? "删除账号" : "Remove account", role: .destructive) { self.perform { try self.cursorAccounts.removeAccount(account.id) } }
                            .accessibilityIdentifier(self.identifier("account.\(account.id).remove"))
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L.zh ? "账号操作" : "Account actions")
                .accessibilityIdentifier(self.identifier("account.\(account.id).actions"))
            }
            HStack(spacing: self.isInline ? 8 : 10) {
                Toggle(L.zh ? "监测" : "Monitor", isOn: Binding(get: { !account.isPaused }, set: { enabled in
                    self.perform { try self.cursorAccounts.setPaused(account.id, paused: !enabled) }
                })).toggleStyle(.switch).controlSize(.small)
                    .foregroundStyle(self.muted)
                    .accessibilityIdentifier(self.identifier("account.\(account.id).enabled"))
                Spacer(minLength: 0)
                Button {
                    self.perform { try self.cursorAccounts.selectAccount(account.id) }
                } label: {
                    Label(self.cursorAccounts.selectedAccountID == account.id
                          ? (L.zh ? "看板账号" : "Dashboard account") : (L.zh ? "用于看板" : "Use in dashboard"),
                          systemImage: self.cursorAccounts.selectedAccountID == account.id ? "checkmark.circle.fill" : "circle")
                }.disabled(account.isPaused || !self.enabled)
                    .accessibilityIdentifier(self.identifier("account.\(account.id).select"))
                Button(L.zh ? "刷新账号" : "Refresh account") { Task { await self.cursorAccounts.refreshAccount(account.id, force: true) } }
                    .disabled(account.isPaused || !self.enabled || state?.status == .refreshing)
                    .accessibilityIdentifier(self.identifier("account.\(account.id).refresh"))
            }.font(self.contentFont(self.isInline ? 9 : 10))
            if let quota = state?.quota { self.quota(quota) }
            if let usage = state?.usage { self.cursorUsage(usage, accountID: account.id) }
            if let detail = state?.statusDetail, !detail.isEmpty {
                self.note(detail)
            }
            if let date = state?.refreshedAt { self.updatedAt(date) }
            Text(L.zh ? "看板选择只影响监测，不改变 Cursor 桌面端登录。" : "Dashboard selection does not change Cursor's desktop sign-in.")
                .font(self.contentFont(9)).foregroundStyle(self.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, self.isInline ? 10 : 14)
        .overlay(alignment: .bottom) { self.divider.frame(height: 1) }
        .accessibilityIdentifier(self.identifier("account.\(account.id)"))
    }

    private func cursorUsage(_ usage: ToolUsageSnapshot, accountID: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            let tokens = usage.dailyEntries.reduce(0.0) { $0 + Double($1.totalTokens) }
            HStack {
                Text(L.zh ? "已读取用量" : "Collected usage").foregroundStyle(self.muted)
                Spacer(minLength: 0)
                Text(tokens.formatted(.number.precision(.fractionLength(0))) + " tokens")
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            Button(self.expandedUsageAccounts.contains(accountID) ? (L.zh ? "收起每日用量" : "Hide daily usage") : (L.zh ? "查看每日用量" : "Show daily usage")) {
                if !self.expandedUsageAccounts.insert(accountID).inserted { self.expandedUsageAccounts.remove(accountID) }
            }.font(self.contentFont(self.isInline ? 9 : 10))
                .accessibilityIdentifier(self.identifier("account.\(accountID).daily-usage"))
            if self.expandedUsageAccounts.contains(accountID) {
                ForEach(usage.dailyEntries.sorted { $0.date > $1.date }) { entry in
                    HStack(spacing: 8) {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(self.muted)
                        Spacer(minLength: 0)
                        Text(entry.totalTokens.formatted() + " tokens").monospacedDigit()
                        if let cost = entry.costUSD { Text(MenuSurface.currency(cost)).monospacedDigit() }
                    }.font(self.contentFont(self.isInline ? 9 : 10)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(L.zh ? "费用为用量价值；实际扣费以账号账单为准。" : "Usage value is separate from actual billing.")
                    .font(self.contentFont(9)).foregroundStyle(self.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = usage.statusDetail { self.note(detail) }
        }
    }

    private func connectionRow(_ profile: ManagedToolConnection) -> some View {
        VStack(alignment: .leading, spacing: self.isInline ? 8 : 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.label).font(self.contentFont(self.isInline ? 11 : 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(profile.sourceDescription).font(self.contentFont(self.isInline ? 9 : 10)).foregroundStyle(self.muted)
                        .lineLimit(self.isInline ? 2 : nil).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true).help(profile.sourceDescription)
                }
                Menu {
                    if self.client == .openCode && !profile.isAutomatic {
                        Button(L.zh ? "修改名称" : "Rename") { self.presentForm(AccountForm(kind: .rename, accountID: profile.id, label: profile.label)) }
                        Button(L.zh ? "更新凭据" : "Update credentials") { self.presentForm(AccountForm(kind: .credential, accountID: profile.id, label: profile.label)) }
                        Button(L.zh ? "上移" : "Move up") { self.perform { try self.connections.move(profile.id, by: -1) } }
                        Button(L.zh ? "下移" : "Move down") { self.perform { try self.connections.move(profile.id, by: 1) } }
                    }
                    if profile.hasAPIKey && !profile.isAutomatic {
                        if self.client == .openCode {
                            Button(L.zh ? "移动 API Key 到其他连接" : "Move API key to another connection") {
                                self.presentForm(AccountForm(kind: .transfer, accountID: profile.id, credentialKind: .apiKey))
                            }
                        }
                        Button(L.zh ? "清除 API Key" : "Clear API key", role: .destructive) { self.clearCredential(profile.id, kind: .apiKey) }
                    }
                    if profile.hasCookie && !profile.isAutomatic {
                        if self.client == .openCode {
                            Button(L.zh ? "移动 Cookie 到其他连接" : "Move cookie to another connection") {
                                self.presentForm(AccountForm(kind: .transfer, accountID: profile.id, credentialKind: .cookie))
                            }
                        }
                        Button(L.zh ? "清除 Cookie" : "Clear cookie", role: .destructive) { self.clearCredential(profile.id, kind: .cookie) }
                    }
                    if profile.canHideAutomaticSource {
                        Button(L.zh ? "隐藏此来源" : "Hide this source") {
                            self.perform { try self.connections.hideAutomaticSource(profile.id) }
                        }
                        .accessibilityIdentifier(self.identifier("connection.\(profile.id).hide"))
                    } else if profile.canRemove {
                        Button(L.zh ? "删除连接" : "Remove connection", role: .destructive) { self.perform { try self.connections.remove(profile.id) } }
                            .accessibilityIdentifier(self.identifier("connection.\(profile.id).remove"))
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L.zh ? "连接操作" : "Connection actions")
                .accessibilityIdentifier(self.identifier("connection.\(profile.id).actions"))
            }
            HStack(spacing: self.isInline ? 8 : 10) {
                Toggle(L.zh ? "监测" : "Monitor", isOn: Binding(get: { profile.isEnabled }, set: { enabled in
                    self.perform { try self.connections.setEnabled(profile.id, enabled: enabled) }
                })).toggleStyle(.switch).controlSize(.small)
                    .foregroundStyle(self.muted)
                    .accessibilityIdentifier(self.identifier("connection.\(profile.id).enabled"))
                Spacer(minLength: 0)
                if self.client == .openCode {
                    Button(self.connections.selectedProfile(for: self.client)?.id == profile.id
                           ? (L.zh ? "看板连接" : "Dashboard connection") : (L.zh ? "用于看板" : "Use in dashboard")) {
                        self.perform { try self.connections.select(profile.id) }
                    }.disabled(!profile.isEnabled || !self.enabled)
                        .accessibilityIdentifier(self.identifier("connection.\(profile.id).select"))
                }
                Button(profile.providerKind == .dshSnapshot ? (L.zh ? "重读快照" : "Reload snapshot")
                       : (L.zh ? "查询额度" : "Query limits")) {
                    Task { await self.connections.refresh(profileID: profile.id, force: true) }
                }
                    .disabled(!profile.isEnabled || !self.enabled || self.connections.isRefreshing)
                    .accessibilityIdentifier(self.identifier("connection.\(profile.id).refresh"))
            }.font(self.contentFont(self.isInline ? 9 : 10))
            if let quota = self.connections.quota(for: profile.id) { self.quota(quota) }
            if let quota = self.connections.quota(for: profile.id), !quota.isLocalSnapshot,
               let date = quota.refreshedAt { self.updatedAt(date) }
        }
        .padding(.vertical, self.isInline ? 10 : 14)
        .overlay(alignment: .bottom) { self.divider.frame(height: 1) }
        .accessibilityIdentifier(self.identifier("connection.\(profile.id)"))
    }

    private func quota(_ snapshot: ToolQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ToolQuotaView(snapshot: snapshot, symbol: "gauge", tint: MenuSurface.accent, mode: .remaining,
                expanded: false, toggle: {}, refresh: {}, showUsage: {}, managementMode: true,
                showsHeader: false, compactManagementActions: true)
            if snapshot.status == .ready && !snapshot.isLocalSnapshot && !snapshot.statusDetail.isEmpty {
                self.note(snapshot.statusDetail)
            }
        }
    }
    private func updatedAt(_ date: Date) -> some View {
        Text((L.zh ? "更新：" : "Updated: ") + date.formatted(date: .abbreviated, time: .shortened))
            .font(self.contentFont(9)).foregroundStyle(self.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); self.notice = nil }
        catch { self.notice = L.zh ? "操作未完成，请检查账号状态后重试。" : "The operation could not be completed. Check the account and try again." }
    }
    private func clearCredential(_ id: String, kind: ManagedToolCredentialKind) {
        self.perform { try self.connections.removeCredential(id, kind: kind) }
        Task { await self.discover(); await self.refresh() }
    }
    private func connectDSHOfficialAccount() async {
        self.isConnectingDSH = true; defer { self.isConnectingDSH = false }
        do {
            try await self.connections.connectExistingDSHOfficialAccount(preferences: self.preferencesStore.preferences,
                officialAccountConfirmed: true)
            self.notice = nil
        } catch {
            self.notice = (error as? ToolConnectionError)?.errorDescription
                ?? (L.zh ? "未能连接官方账号，请设置官方 API Key 后重试。" : "Could not connect. Set an official API key and try again.")
        }
    }
    func discover() async {
        guard self.enabled else { return }
        if self.client == .cursor { await self.cursorAccounts.discoverDesktopAccount(force: true) }
        else { await self.connections.discover(client: self.client, preferences: self.preferencesStore.preferences) }
    }
    func refresh(force: Bool = true) async {
        guard self.enabled else { return }
        if self.client == .cursor { await self.cursorAccounts.refreshAll(force: force) }
        else {
            for profile in self.connections.profiles(for: self.client) where profile.isEnabled {
                await self.connections.refresh(profileID: profile.id, force: force)
            }
        }
    }
    private func identifier(_ suffix: String) -> String { "codexbar.accounts.\(self.client.rawValue).\(suffix)" }
    private var addTitle: String {
        switch self.client {
        case .cursor: L.zh ? "手动添加账号" : "Add account manually"
        case .claudeCode: self.isInline ? (L.zh ? "连接 Claude 账号" : "Connect Claude")
            : (L.zh ? "连接 Claude 网站账号" : "Connect Claude web account")
        case .openCode: L.zh ? "添加接入账号" : "Add connection"
        case .deepSeekHarness: self.isInline ? (L.zh ? "设置 DeepSeek Key" : "Set DeepSeek key")
            : (L.zh ? "设置 DeepSeek API Key" : "Set DeepSeek API key")
        case .antigravity: L.zh ? "管理 Antigravity 账号" : "Manage Antigravity accounts"
        }
    }
    private var sourceDescription: String {
        switch self.client {
        case .cursor: L.zh ? "自动识别 Cursor 桌面端登录，或手动添加网站会话（同时支持新版合并会员与旧版拆分会员）。每个账号独立查询用量与额度。" : "Discover the desktop sign-in or add a web session (both unified and legacy split plans are supported). Usage and limits are queried separately for each account."
        case .claudeCode: L.zh ? "自动读取 Claude Code OAuth 订阅额度；也可连接 Claude 网站 sessionKey 并选择组织。网站连接优先，普通 API Key 不含订阅额度。" : "Read Claude Code OAuth limits automatically, or connect a Claude web session and choose an organization. Web sessions take priority; API keys do not include subscription limits."
        case .openCode: L.zh ? "自动识别 OpenCode Go 配置；也可添加 API Key 或网站 Cookie，按接入账号分别读取额度。OpenAI 登录不作为 OpenCode Go 账号。" : "Discover OpenCode Go or add API keys and web cookies. Each connection has separate limits; OpenAI sign-ins are not OpenCode Go accounts."
        case .deepSeekHarness: L.zh ? "官方账号直接查询实时余额。确认账号属于 DeepSeek 官方后，可连接 DSH 已保存的 Key，或手动填写官方 Key；其他来源显示 DSH 快照。" : "Official accounts query live balances. Connect DSH's saved key after confirming an official DeepSeek account, or enter an official key; other sources show DSH snapshots."
        case .antigravity: L.zh ? "Antigravity 账号在额度页管理；本地 Token 记录独立采集。" : "Manage Antigravity accounts on the Limits page; local token history is collected independently."
        }
    }
    private var loginURL: URL {
        switch self.client {
        case .cursor: URL(string: "https://cursor.com/dashboard")!
        case .claudeCode: URL(string: "https://claude.ai")!
        case .openCode: URL(string: "https://opencode.ai")!
        case .deepSeekHarness: URL(string: "https://platform.deepseek.com/api_keys")!
        case .antigravity: URL(string: "https://antigravity.google")!
        }
    }
}

private struct ManagedToolInlineControlsStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(ManagedToolInlineButtonStyle()).tint(MenuSurface.accent)
    }
}

private struct ManagedToolInlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(self.enabled ? MenuSurface.accent : MenuSurface.muted)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
    }
}

struct AccountForm: Identifiable {
    enum Kind { case credential, rename, transfer }
    let id = UUID()
    var kind: Kind
    var accountID: String? = nil
    var label: String = ""
    var credentialKind: ManagedToolCredentialKind? = nil
}

@MainActor
struct ManagedToolAccountForm: View {
    let client: ToolUsageClient
    let form: AccountForm
    @ObservedObject var cursorAccounts: CursorAccountStore
    @ObservedObject var connections: ToolConnectionStore
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    let onDone: () -> Void
    @State private var label: String
    @State private var cookie = ""
    @State private var apiKey = ""
    @State private var organizationID = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmsSameAccount = false
    @State private var targetProfileID = ""
    @State private var organizationsLoaded = false

    init(client: ToolUsageClient, form: AccountForm, cursorAccounts: CursorAccountStore,
         connections: ToolConnectionStore, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         onDone: @escaping () -> Void) {
        self.client = client; self.form = form; self.cursorAccounts = cursorAccounts
        self.connections = connections; self.openURL = openURL; self.onDone = onDone
        self._label = State(initialValue: form.label)
    }

    var body: some View {
        Group {
            if self.client == .claudeCode && self.form.kind == .credential {
                ScrollView { self.formContent }
                    .frame(width: 480, height: 480)
            } else {
                self.formContent
            }
        }
        .foregroundStyle(SettingsPalette.foreground)
        .background(SettingsPalette.canvas)
        .preferredColorScheme(SettingsPalette.colorScheme)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(self.form.kind == .rename ? (L.zh ? "修改名称" : "Rename") : self.form.kind == .transfer
                 ? (L.zh ? "移动账号凭据" : "Move account credential") : self.client.displayName + (L.zh ? " 接入" : " connection"))
                .font(.system(size: 17, weight: .semibold))
            if self.form.kind != .transfer && (self.form.kind == .rename || self.client == .cursor || self.client == .openCode) {
                TextField(self.client == .openCode ? (L.zh ? "接入名称" : "Connection name")
                          : (L.zh ? "账号名称（可选）" : "Account name (optional)"), text: self.$label)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("codexbar.account-form.label")
            }
            if self.form.kind == .credential {
                switch self.client {
                case .cursor:
                    SecureField("WorkosCursorSessionToken / JWT", text: self.$cookie).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("codexbar.account-form.cookie")
                    SettingsPreferenceNote(L.zh ? "在 Cursor 网站登录后，从开发者工具的 Cookies 中复制 WorkosCursorSessionToken（也支持完整 Cookie 头或桌面端 JWT）。同时支持新版合并会员（Plus / Premium / Super / Ultra，与 Grok 等共用包含用量）与旧版拆分会员；提交时自动识别套餐类型。" : "Copy WorkosCursorSessionToken from browser cookies after signing in (full Cookie headers and desktop JWTs are also supported). Both unified memberships (Plus / Premium / Super / Ultra) and legacy split plans are detected automatically.")
                    HStack(spacing: 12) {
                        Button(L.zh ? "打开 Cursor 网站" : "Open Cursor dashboard") {
                            if let url = URL(string: "https://cursor.com/dashboard") {
                                self.openURL(url)
                            }
                        }
                        .disabled(self.busy)
                        .accessibilityIdentifier("codexbar.account-form.open-cursor-dashboard")
                        if self.form.accountID == nil {
                            Button(L.zh ? "从本机 Cursor 自动识别" : "Discover from local Cursor") {
                                Task { await self.discoverCursorDesktop() }
                            }
                            .disabled(self.busy)
                            .accessibilityIdentifier("codexbar.account-form.discover-cursor-desktop")
                        }
                    }
                    .font(.system(size: 12))
                case .claudeCode:
                    SecureField("Claude sessionKey / Cookie / OAuth token", text: self.$cookie).textFieldStyle(.roundedBorder)
                        .disabled(self.busy)
                        .accessibilityIdentifier("codexbar.account-form.cookie")
                    SettingsPreferenceNote(L.zh ? "可粘贴 Claude 网站 sessionKey、完整 Cookie 头，或 sk-ant-oat 开头的 OAuth 令牌。不要填写邮箱、密码或普通 API Key。"
                        : "Paste a Claude sessionKey, a full Cookie header, or an OAuth token starting with sk-ant-oat. Do not enter an email, password or ordinary API key.")
                    Button(L.zh ? "打开 Claude 网站" : "Open Claude website") {
                        self.openURL(URL(string: "https://claude.ai")!)
                    }
                    .disabled(self.busy)
                    if self.claudeUsesWebSession {
                        SettingsPreferenceNote(L.zh ? "网站登录后，在开发者工具的 Application → Cookies → claude.ai 中复制 sessionKey。保存时自动读取组织；多个组织时需要选择。"
                            : "After signing in, copy sessionKey from developer tools: Application → Cookies → claude.ai. Organizations are loaded on save; choose one if there are several.")
                        Button(L.zh ? "读取组织" : "Load organizations") { Task { await self.loadOrganizations() } }
                            .disabled(self.cookie.isEmpty || self.busy).accessibilityIdentifier("codexbar.account-form.organizations")
                        if self.organizationsLoaded && !self.connections.organizations.isEmpty {
                            Picker(L.zh ? "组织" : "Organization", selection: self.$organizationID) {
                                Text(L.zh ? "选择组织" : "Choose organization").tag("")
                                ForEach(self.connections.organizations) { organization in Text(organization.name).tag(organization.id) }
                            }
                            .disabled(self.busy)
                        }
                    }
                case .openCode:
                    SecureField(L.zh ? "API Key（可选）" : "API key (optional)", text: self.$apiKey).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("codexbar.account-form.api-key")
                    SecureField(L.zh ? "网站 Cookie（可选）" : "Web cookie (optional)", text: self.$cookie).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("codexbar.account-form.cookie")
                    if self.requiresPairConfirmation {
                        Toggle(L.zh ? "确认 API Key 和 Cookie 属于同一个账号" : "These credentials belong to the same account", isOn: self.$confirmsSameAccount)
                    }
                    SettingsPreferenceNote(L.zh ? "填入 OpenCode Go API Key 或 OpenCode 网站 Cookie。优先查询 Go 额度，再尝试网站；编辑时留空保留已有凭据。" : "Provide an OpenCode Go API key or website cookie. Go limits are queried first, then web limits; blank fields keep existing credentials when editing.")
                case .deepSeekHarness:
                    SecureField("DeepSeek API Key", text: self.$apiKey).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("codexbar.account-form.api-key")
                    SettingsPreferenceNote(L.zh ? "填写 platform.deepseek.com 创建的官方 API Key。查询返回人民币或美元余额，不提供订阅百分比。" : "Use an official API key from platform.deepseek.com. The query reports CNY or USD balance, not a subscription percentage.")
                case .antigravity:
                    SettingsPreferenceNote(L.zh ? "请在额度页的 Antigravity 分区管理账号。" : "Manage accounts in the Antigravity section on the Limits page.")
                }
            }
            if self.form.kind == .transfer {
                Picker(L.zh ? "目标连接" : "Target connection", selection: self.$targetProfileID) {
                    Text(L.zh ? "选择目标连接" : "Choose target connection").tag("")
                    ForEach(self.connections.profiles(for: .openCode).filter { !$0.isAutomatic && $0.id != self.form.accountID }) { profile in
                        Text(profile.label).tag(profile.id)
                    }
                }
                SettingsPreferenceNote(L.zh ? "凭据会从原连接移到目标连接；已有同类凭据不会被覆盖。请核对目标连接中的凭据是否属于同一账号。"
                    : "Move the credential to the target without overwriting an existing credential of the same kind. Verify that the target belongs to the same account.")
                Toggle(L.zh ? "确认目标连接属于同一账号" : "The target belongs to the same account", isOn: self.$confirmsSameAccount)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L.zh ? "取消" : "Cancel") { self.clearSecrets(); self.onDone() }.disabled(self.busy)
                Button(self.busy ? (L.zh ? "正在验证…" : "Checking…") : (L.zh ? "保存" : "Save")) { Task { await self.save() } }
                    .disabled(self.busy || (self.form.kind == .credential && self.client == .claudeCode &&
                        (self.cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                         (self.claudeUsesWebSession && self.organizationsLoaded && self.connections.organizations.count > 1 && self.organizationID.isEmpty))))
                    .disabled(self.form.kind == .credential && self.client == .openCode &&
                        self.requiresPairConfirmation && !self.confirmsSameAccount)
                    .disabled(self.form.kind == .transfer && (self.targetProfileID.isEmpty || !self.confirmsSameAccount))
                    .disabled(self.form.kind == .credential && self.client == .openCode && self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("codexbar.account-form.save")
            }
        }.padding(24).frame(width: 480).background(SettingsPalette.canvas)
            .interactiveDismissDisabled(self.busy).onDisappear { self.clearSecrets() }
            .onChange(of: self.cookie) { _ in self.organizationsLoaded = false; self.organizationID = ""; self.error = nil }
    }
    private func discoverCursorDesktop() async {
        self.busy = true; defer { self.busy = false }
        let beforeIDs = Set(self.cursorAccounts.accounts.map(\.id))
        await self.cursorAccounts.discoverDesktopAccount(force: true)
        if let desktop = self.cursorAccounts.accounts.first(where: { $0.isDesktop }) {
            if !beforeIDs.contains(desktop.id) || self.cursorAccounts.selectedAccountID == nil {
                try? self.cursorAccounts.selectAccount(desktop.id)
            }
            await self.cursorAccounts.refreshAccount(desktop.id, force: true)
            self.clearSecrets()
            self.onDone()
        } else {
            self.error = self.cursorAccounts.status
                ?? (L.zh ? "未检测到本机 Cursor 登录，请使用上方输入框粘贴网站 Cookie 或 JWT。" : "No local Cursor sign-in found. Paste a web cookie or JWT above.")
        }
    }
    private func loadOrganizations() async {
        self.busy = true; defer { self.busy = false }
        do {
            try await self.connections.loadClaudeOrganizations(sessionKey: self.cookie)
            self.organizationsLoaded = true
            self.organizationID = self.connections.organizations.count == 1 ? self.connections.organizations[0].id : ""
            self.error = nil
        } catch { self.error = ToolConnectionService.opaque(error).localizedDescription }
    }
    private func save() async {
        self.busy = true; defer { self.busy = false }
        do {
            if self.form.kind == .rename, let id = self.form.accountID {
                if self.client == .cursor { try self.cursorAccounts.renameAccount(id, alias: self.label) }
                else { try self.connections.rename(id, label: self.label) }
            } else if self.form.kind == .transfer, let id = self.form.accountID, let kind = self.form.credentialKind {
                try self.connections.transferCredential(from: id, to: self.targetProfileID, kind: kind,
                    confirmedSameAccount: self.confirmsSameAccount)
            } else {
                switch self.client {
                case .cursor:
                    if let id = self.form.accountID {
                        try await self.cursorAccounts.replaceCredential(accountID: id, sessionCookie: self.cookie)
                        await self.cursorAccounts.refreshAccount(id, force: true)
                    } else {
                        let id = try await self.cursorAccounts.addAccount(sessionCookie: self.cookie, alias: self.label)
                        try? self.cursorAccounts.selectAccount(id)
                        await self.cursorAccounts.refreshAccount(id, force: true)
                    }
                case .claudeCode:
                    if self.claudeUsesWebSession && !self.organizationsLoaded {
                        try await self.connections.loadClaudeOrganizations(sessionKey: self.cookie)
                        self.organizationsLoaded = true
                        self.organizationID = self.connections.organizations.count == 1 ? self.connections.organizations[0].id : ""
                        if self.connections.organizations.count > 1 {
                            self.error = ToolConnectionError.organizationSelectionRequired.localizedDescription
                            return
                        }
                    }
                    try await self.connections.saveClaudeCredential(self.cookie,
                        organizationID: self.organizationID.isEmpty ? nil : self.organizationID)
                case .openCode:
                    try await self.connections.saveOpenCodeProfile(label: self.label, apiKey: self.apiKey.isEmpty ? nil : self.apiKey,
                        cookie: self.cookie.isEmpty ? nil : self.cookie, profileID: self.form.accountID,
                        confirmedSameAccount: self.confirmsSameAccount)
                case .deepSeekHarness:
                    try await self.connections.saveDeepSeekKey(self.apiKey)
                case .antigravity:
                    throw ToolConnectionError.unsupported
                }
            }
            self.clearSecrets(); self.onDone()
        } catch {
            self.error = self.client == .claudeCode ? ToolConnectionService.opaque(error).localizedDescription
                : (L.zh ? "保存失败：凭据无效、已过期或接口暂不可用，请检查后重试。" : "Could not save. Check for invalid or expired credentials, or try again later.")
        }
    }
    private var claudeUsesWebSession: Bool {
        guard let credential = try? ToolConnectionService.parseClaudeCredential(self.cookie) else { return false }
        if case .web = credential { return true }
        return false
    }
    private func clearSecrets() { self.cookie = ""; self.apiKey = "" }
    private var requiresPairConfirmation: Bool {
        let existing = self.connections.profiles.first { $0.id == self.form.accountID }
        let finalHasKey = !self.apiKey.isEmpty || existing?.hasAPIKey == true
        let finalHasCookie = !self.cookie.isEmpty || existing?.hasCookie == true
        return finalHasKey && finalHasCookie && (!self.apiKey.isEmpty || !self.cookie.isEmpty)
    }
}

// MARK: - 菜单栏平铺账号行（与 Cursor / Antigravity 同款）

@MainActor
struct CompactToolAccountsPanel: View {
    let client: ToolUsageClient
    @ObservedObject var connections: ToolConnectionStore
    @ObservedObject var cursorAccounts: CursorAccountStore
    @ObservedObject var preferencesStore: ApplicationPreferencesStore
    @ObservedObject var toolUsageStore: ToolUsageStore
    var collapsed: Bool = false
    var compactManagement: Bool = false
    let usageDisplayMode: CodexBarUsageDisplayMode
    let privacyLabel: (String) -> String
    let onShowUsage: () -> Void
    var now: Date = Date()

    private var profiles: [ManagedToolConnection] { self.connections.profiles(for: self.client) }
    private var currentProfile: ManagedToolConnection? {
        self.connections.selectedProfile(for: self.client) ?? self.profiles.first
    }
    private var otherProfiles: [ManagedToolConnection] {
        self.profiles.filter { $0.id != self.currentProfile?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.compactManagement ? 6 : 10) {
            if !self.compactManagement {
                HStack {
                    Text(L.zh ? "\(self.profiles.count) 个账号" : "\(self.profiles.count) accounts")
                        .foregroundStyle(MenuSurface.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { self.addAccount() } label: {
                        Label(self.addTitle, systemImage: self.client == .deepSeekHarness ? "key" : "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MenuSurface.accent)
                    .accessibilityIdentifier("codexbar.management.\(self.client.rawValue).add-account")
                }
                .font(MenuSurface.font(size: 9, weight: .medium))
            }

            if let current = self.currentProfile {
                self.row(current, isSummary: true)
                    .accessibilityIdentifier("codexbar.management.\(self.client.rawValue).summary")
                if !self.collapsed, !self.otherProfiles.isEmpty {
                    self.accountsSection
                        .accessibilityIdentifier("codexbar.management.\(self.client.rawValue).details")
                }
                if !self.compactManagement {
                    HStack {
                        Spacer(minLength: 4)
                        Button { self.onShowUsage() } label: {
                            Label(L.zh ? "查看用量" : "View usage", systemImage: "arrow.right")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MenuSurface.accent)
                        .accessibilityIdentifier("codexbar.tool-quota.\(self.client.rawValue).usage")
                    }
                    .font(MenuSurface.font(size: 9))
                }
            } else {
                self.emptyCard
            }
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: self.compactManagement ? 6 : 10) {
            HStack(spacing: 8) {
                Text(self.sectionTitle)
                    .font(MenuSurface.font(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(MenuSurface.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !self.otherProfiles.isEmpty {
                    let available = self.otherProfiles.filter { self.isAvailable($0) }.count
                    Text(L.zh ? "\(available)/\(self.otherProfiles.count) 可用" : "\(available)/\(self.otherProfiles.count) available")
                        .font(MenuSurface.font(size: 10))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(available > 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                        .foregroundColor(available > 0 ? .green : .red)
                        .cornerRadius(4)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(self.otherProfiles) { profile in
                    self.row(profile)
                }
            }
        }
    }

    private func row(_ profile: ManagedToolConnection, isSummary: Bool = false) -> some View {
        return CompactToolAccountRow(
            client: self.client,
            profile: profile,
            quota: self.connections.quota(for: profile.id),
            displayLabel: self.privacyLabel(profile.accountDisplayLabel),
            secondaryLabel: profile.accountDisplayDetail.map(self.privacyLabel),
            isActive: self.connections.selectedProfile(for: self.client)?.id == profile.id,
            usageDisplayMode: self.usageDisplayMode,
            onSelect: { try? self.connections.select(profile.id) },
            onRefresh: { Task { await self.connections.refresh(profileID: profile.id, force: true) } },
            onRename: {
                ManagedToolAccountsView.presentDetachedForm(
                    client: self.client,
                    form: AccountForm(kind: .rename, accountID: profile.id, label: profile.label),
                    cursorAccounts: self.cursorAccounts,
                    connections: self.connections
                )
            },
            onUpdateCredential: {
                ManagedToolAccountsView.presentDetachedForm(
                    client: self.client,
                    form: AccountForm(kind: .credential, accountID: profile.id, label: profile.label),
                    cursorAccounts: self.cursorAccounts,
                    connections: self.connections
                )
            },
            onSettings: {
                ManagedToolAccountsView.presentDetachedSettings(
                    client: self.client,
                    preferencesStore: self.preferencesStore,
                    toolUsageStore: self.toolUsageStore
                )
            },
            onTogglePaused: { try? self.connections.setEnabled(profile.id, enabled: !profile.isEnabled) },
            onDelete: {
                if profile.canHideAutomaticSource {
                    try? self.connections.hideAutomaticSource(profile.id)
                } else if profile.canRemove {
                    try? self.connections.remove(profile.id)
                }
            },
            isRefreshing: self.connections.isRefreshing,
            collectionEnabled: !self.preferencesStore.preferences.disabledTools.contains(self.client.rawValue),
            isSummary: isSummary,
            compactManagement: self.compactManagement,
            now: self.now
        )
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.zh ? "还没有 \(self.client.displayName) 账号" : "No \(self.client.displayName) account")
                .font(MenuSurface.font(size: 11, weight: .medium))
            Text(self.compactManagement && ![ToolQuotaStatus.failed, .authenticationRequired].contains(self.toolUsageStore.quota(for: self.client).status)
                 ? (L.zh ? "点击顶部 ＋ 添加账号或连接服务" : "Use + above to add an account or connect a service")
                 : (self.toolUsageStore.quota(for: self.client).statusDetail.isEmpty
                    ? self.emptyDetail : self.toolUsageStore.quota(for: self.client).statusDetail))
                .font(MenuSurface.font(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(MenuSurface.raised))
    }

    private var sectionTitle: String {
        L.zh ? "其他账号" : "OTHER ACCOUNTS"
    }

    private var addTitle: String {
        switch self.client {
        case .deepSeekHarness: L.zh ? "设置 API Key" : "Set API key"
        case .claudeCode: L.zh ? "连接账号" : "Connect account"
        case .openCode: L.zh ? "添加账号" : "Add account"
        case .cursor: L.zh ? "添加账号" : "Add account"
        case .antigravity: L.zh ? "管理账号" : "Manage accounts"
        }
    }

    private var emptyDetail: String {
        switch self.client {
        case .deepSeekHarness:
            return L.zh ? "官方 API Key 查询实时余额。没有 Key 时，右上角菜单可以读取 DSH 快照。" : "An official API key reads the live balance. The menu can also load a DSH snapshot."
        case .claudeCode:
            return L.zh ? "右上角菜单可以自动识别本机登录，或在这里连接账号。" : "Discover a local sign-in from the menu, or connect an account here."
        case .openCode:
            return L.zh ? "右上角菜单可以自动识别，或添加 API Key / 网站账号。" : "Discover from the menu, or add an API key or web account."
        case .cursor:
            return ""
        case .antigravity:
            return L.zh ? "请在额度页管理 Antigravity 账号。" : "Manage Antigravity accounts on the Limits page."
        }
    }

    private func isAvailable(_ profile: ManagedToolConnection) -> Bool {
        guard profile.isEnabled, let quota = self.connections.quota(for: profile.id) else { return false }
        if quota.status != .ready { return false }
        if quota.balance != nil && quota.windows.isEmpty { return true }
        let percents = quota.windows.compactMap(\.usedPercent)
        return percents.isEmpty || percents.contains { $0 < 100 }
    }

    private func addAccount() {
        ManagedToolAccountsView.presentDetachedAccountForm(
            client: self.client,
            cursorAccounts: self.cursorAccounts,
            connections: self.connections
        )
    }
}

private struct CompactToolAccountRow: View {
    let client: ToolUsageClient
    let profile: ManagedToolConnection
    let quota: ToolQuotaSnapshot?
    let displayLabel: String
    let secondaryLabel: String?
    let isActive: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    let onSelect: () -> Void
    let onRefresh: () -> Void
    let onRename: () -> Void
    let onUpdateCredential: () -> Void
    let onSettings: () -> Void
    let onTogglePaused: () -> Void
    let onDelete: () -> Void
    var isRefreshing = false
    var collectionEnabled = true
    var isSummary = false
    var compactManagement = false
    var now: Date = Date()

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(self.statusColor)
                    .frame(width: 7, height: 7)
                Text(self.displayLabel)
                    .font(MenuSurface.font(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let secondary = self.secondaryLabel, !secondary.isEmpty, secondary != self.displayLabel {
                    Text(secondary)
                        .font(MenuSurface.font(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if self.client != .claudeCode {
                        Text(self.badgeTitle)
                            .font(MenuSurface.font(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(self.badgeColor)
                    }
                    if self.isRefreshing {
                        ProgressView().controlSize(.mini)
                    }
                    if self.compactManagement {
                        AccountUpdateLabel(isCurrent: self.isActive, updatedAt: self.quota?.refreshedAt, now: self.now)
                    } else if self.isActive {
                        Text(L.zh ? "当前账号" : "Current")
                            .font(MenuSurface.font(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if !self.isActive, self.isHovering, self.profile.isEnabled {
                        Button(L.zh ? "切换" : "Use") { self.onSelect() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .font(MenuSurface.font(size: 10, weight: .semibold))
                    }
                    self.actions
                }
                .fixedSize()
            }

            if !self.collectionEnabled || !self.profile.isEnabled {
                Text(!self.collectionEnabled
                     ? (L.zh ? "已暂停读取此工具" : "Collection paused for this tool")
                     : (L.zh ? "已暂停读取此账号" : "Collection paused for this account"))
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.orange)
            }
            CursorAccountQuotaView(
                quota: self.quota,
                state: nil,
                usageDisplayMode: self.usageDisplayMode,
                showsFooter: !self.compactManagement,
                balance: self.quota?.balance,
                balanceIsSnapshot: self.quota?.isLocalSnapshot == true,
                now: self.now
            )
        }
        .padding(.vertical, self.isSummary ? 0 : (self.compactManagement ? 5 : 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { self.isHovering = $0 }
        .accessibilityIdentifier("codexbar.compact-account.\(self.client.rawValue).\(self.profile.id)")
    }

    private var actions: some View {
        Menu {
            if !self.isActive, self.profile.isEnabled {
                Button(L.zh ? "切换到此账号" : "Switch to account") { self.onSelect() }
                Divider()
            }
            Button(self.quota?.isLocalSnapshot == true ? (L.zh ? "重读快照" : "Reload snapshot") : L.refreshUsage) {
                self.onRefresh()
            }
            .disabled(self.isRefreshing || !self.profile.isEnabled || !self.collectionEnabled)
            if self.client == .openCode, !self.profile.isAutomatic {
                Button(L.zh ? "修改名称" : "Rename") { self.onRename() }
            }
            if !self.profile.isAutomatic || self.profile.hasAPIKey || self.profile.hasCookie {
                Button(L.zh ? "更新凭据" : "Update credentials") { self.onUpdateCredential() }
            }
            Button(L.zh ? "读取设置" : "Collection settings") { self.onSettings() }
            Button(self.profile.isEnabled ? (L.zh ? "暂停读取此账号" : "Pause collection")
                   : (L.zh ? "恢复读取此账号" : "Resume collection")) { self.onTogglePaused() }
            if self.profile.canHideAutomaticSource || self.profile.canRemove {
                Divider()
                Button(self.profile.canHideAutomaticSource ? (L.zh ? "隐藏此来源" : "Hide this source")
                       : (L.zh ? "删除账号" : "Delete account"), role: .destructive) {
                    self.onDelete()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(MenuSurface.font(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .accessibilityLabel(L.zh ? "账号操作" : "Account actions")
        .accessibilityIdentifier("codexbar.compact-account.\(self.client.rawValue).\(self.profile.id).actions")
    }

    private var badgeTitle: String {
        switch self.profile.providerKind {
        case .dshSnapshot:
            return L.zh ? "快照" : "SNAP"
        case .dshOfficialAPI, .deepSeekAPI:
            return "API"
        case .primary:
            if self.profile.hasAPIKey { return "API" }
            if self.client == .openCode { return "GO" }
            return "OAUTH"
        }
    }

    private var badgeColor: Color {
        switch self.badgeTitle {
        case "API": return .cyan
        case "GO": return .indigo
        case "OAUTH": return .orange
        default: return .gray
        }
    }

    private var statusColor: Color {
        if !self.collectionEnabled || !self.profile.isEnabled { return .gray }
        switch self.quota?.status {
        case .ready:
            let percents = self.quota?.windows.compactMap(\.usedPercent) ?? []
            return !percents.isEmpty && percents.allSatisfy { $0 >= 100 } ? .orange : .green
        case .authenticationRequired:
            return .orange
        case .failed:
            return .red
        default:
            return .gray
        }
    }
}
