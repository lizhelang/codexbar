import AppKit
import SwiftUI

@MainActor
private extension ApplicationPreferencesStore {
    func binding<Value>(_ keyPath: WritableKeyPath<ApplicationPreferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

struct SettingsGeneralPage: View {
    @ObservedObject var updateCoordinator: UpdateCoordinator
    @ObservedObject private var preferences = ApplicationPreferencesStore.shared
    @ObservedObject private var loginItem = LoginItemService.shared
    @State private var diagnosticCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSelectionField(L.zh ? "界面语言" : "Interface language", selection: self.preferences.binding(\.language), options: [
                (.system, L.zh ? "跟随系统" : "System"),
                (.simplifiedChinese, "简体中文"),
                (.english, "English"),
            ])
            SettingsPreferenceSection(L.zh ? "启动" : "Startup") {
                Toggle(L.zh ? "登录时启动" : "Start at login", isOn: Binding(get: { self.loginItem.isEnabled }, set: { self.loginItem.setEnabled($0) }))
                if self.loginItem.requiresApproval {
                    Button(L.zh ? "在系统设置中允许启动" : "Allow in System Settings") { self.loginItem.openSystemSettings() }
                }
                if let errorMessage = self.loginItem.errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            SettingsPreferenceSection(L.zh ? "应用更新" : "App updates") {
                Toggle(L.zh ? "自动检查更新" : "Check for updates automatically", isOn: self.preferences.binding(\.automaticUpdateChecks))
                Toggle(L.zh ? "自动下载更新" : "Download updates automatically", isOn: self.preferences.binding(\.automaticallyDownloadUpdates))
                SettingsPreferenceNote(L.zh ? "从 Codexbar 自己的 GitHub Releases 获取更新。后台下载完成后由你确认安装。" : "Updates come from Codexbar's GitHub Releases. Confirm installation after the background download completes.")
                SettingsUpdatesPage(updateCoordinator: self.updateCoordinator)
            }
            SettingsPreferenceSection(L.zh ? "关于 Codexbar" : "About Codexbar") {
                HStack {
                    Button("GitHub") { self.openRepository(suffix: "") }
                    Button(L.zh ? "反馈问题" : "Report issue") { self.openRepository(suffix: "/issues") }
                    Button(self.diagnosticCopied ? (L.zh ? "已复制诊断" : "Diagnostics copied") : (L.zh ? "复制诊断信息" : "Copy diagnostics")) { self.copyDiagnostics() }
                }
                SettingsPreferenceNote(L.zh ? "诊断仅包含应用与系统版本、工具采集状态，不包含凭证、账户、会话内容或文件路径。" : "Diagnostics include app and OS versions and collection states, without credentials, accounts, conversations or paths.")
            }
        }
        .font(.system(size: 12))
        .onAppear { self.loginItem.refresh() }
    }

    private func openRepository(suffix: String) {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CodexBarGitHubReleasesURL") as? String,
              let url = URL(string: raw),
              url.host == "api.github.com" else { return }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 4, components[0] == "repos",
              let destination = URL(string: "https://github.com/\(components[1])/\(components[2])\(suffix)") else { return }
        NSWorkspace.shared.open(destination)
    }

    private func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let states = ToolUsageClient.allCases.map { client in
            "\(client.displayName): \(ToolUsageStore.shared.snapshot(for: client).availability.rawValue)"
        }
        let report = (["Codexbar \(version) (\(build))", ProcessInfo.processInfo.operatingSystemVersionString] + states).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        self.diagnosticCopied = true
    }
}

struct SettingsMainPage: View {
    @ObservedObject private var preferences = ApplicationPreferencesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSelectionField(L.zh ? "默认用量范围" : "Default usage range", selection: self.preferences.binding(\.defaultUsageRange), options:
                UsagePeriod.allCases.map { ($0.rawValue, $0.title) }
            )
            SettingsSelectionField(L.zh ? "默认统计指标" : "Default metric", selection: self.preferences.binding(\.defaultUsageMetric), options: [
                ("tokens", "Tokens"),
                ("cost", L.zh ? "费用" : "Cost"),
            ])
            SettingsOrderedPreferences(
                title: L.zh ? "看板页面" : "Dashboard pages",
                order: self.preferences.binding(\.pageOrder), hidden: self.preferences.binding(\.hiddenPages),
                defaults: ApplicationPreferences.allPages, lockedVisible: ["home"]
            )
            SettingsOrderedPreferences(
                title: L.zh ? "首页模块" : "Home modules",
                order: self.preferences.binding(\.homeModuleOrder), hidden: self.preferences.binding(\.hiddenHomeModules),
                defaults: ApplicationPreferences.allHomeModules
            )
            Stepper(value: self.preferences.binding(\.homeItemLimit), in: 1...20) {
                Text(L.zh ? "首页每组显示 \(self.preferences.preferences.homeItemLimit) 项" : "\(self.preferences.preferences.homeItemLimit) rows per Home section")
            }
            SettingsPreferenceSection(L.zh ? "费用显示" : "Cost display") {
                SettingsSelectionField(L.zh ? "币种" : "Currency", selection: self.preferences.binding(\.displayCurrencyCode), options:
                    ["USD", "AUD", "CNY", "HKD", "TWD", "EUR", "JPY"].map { ($0, $0) }
                )
                if self.preferences.preferences.displayCurrencyCode != "USD" {
                    HStack {
                        Text("1 USD =")
                        TextField("", value: self.preferences.binding(\.usdExchangeRate), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 110)
                        Text(self.preferences.preferences.displayCurrencyCode)
                    }
                    SettingsPreferenceNote(L.zh ? "使用你填写的汇率换算显示；原始账目保持美元计价。" : "Display conversion uses your exchange rate. Original costs remain in USD.")
                }
            }
        }
        .font(.system(size: 12))
    }
}

struct SettingsPanelPage: View {
    @ObservedObject private var preferences = ApplicationPreferencesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPreferenceSection(L.zh ? "菜单栏窗口" : "Menu bar window") {
                Toggle(L.zh ? "点击窗口外时保持打开" : "Keep open when clicking outside", isOn: self.preferences.binding(\.keepMenuOpenOnOutsideClick))
                SettingsPreferenceNote(L.zh ? "仍可点击菜单栏图标关闭窗口。" : "Click the menu bar icon again to close the panel.")
                HStack {
                    Text(L.zh ? "窗口高度" : "Panel height")
                    Spacer()
                    Text(self.preferences.preferences.preferredMenuHeight == 0 ? (L.zh ? "自动" : "Automatic") : "\(Int(self.preferences.preferences.preferredMenuHeight)) pt")
                        .monospacedDigit().foregroundStyle(SettingsPalette.muted)
                    Button(L.zh ? "重置" : "Reset") { self.preferences.update { $0.preferredMenuHeight = 0 } }
                }
                Slider(value: Binding(
                    get: { self.preferences.preferences.preferredMenuHeight == 0 ? 640 : self.preferences.preferences.preferredMenuHeight },
                    set: { height in self.preferences.update { $0.preferredMenuHeight = height } }
                ), in: 260...1200, step: 10)
                SettingsPreferenceNote(L.zh ? "也可以拖动菜单底部调整。实际高度会适应当前屏幕可用空间。" : "You can also drag the bottom edge. The panel is constrained to the current screen's available space.")
            }
        }
        .font(.system(size: 12))
    }
}

struct SettingsAppearancePage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    @ObservedObject private var preferences = ApplicationPreferencesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSelectionField(L.zh ? "主题" : "Theme", selection: self.preferences.binding(\.theme), options: [
                (.system, L.zh ? "跟随系统" : "System"),
                (.dark, L.zh ? "深色" : "Dark"),
                (.light, L.zh ? "浅色" : "Light"),
            ])
            SettingsSelectionField(L.zh ? "强调色" : "Accent color", selection: self.preferences.binding(\.accentColor), options: [
                (.teal, L.zh ? "青色" : "Teal"),
                (.blue, L.zh ? "蓝色" : "Blue"),
                (.green, L.zh ? "绿色" : "Green"),
                (.orange, L.zh ? "橙色" : "Orange"),
                (.purple, L.zh ? "紫色" : "Purple"),
            ])
            SettingsPreferenceSection(L.zh ? "显示元素" : "Visible elements") {
                Toggle(L.zh ? "显示顶部应用图标" : "Show app icon in header", isOn: self.preferences.binding(\.showAppIcon))
                Toggle(L.zh ? "显示 Token 速率" : "Show token rate", isOn: self.preferences.binding(\.showTokenRate))
                Toggle(L.zh ? "显示工具图标" : "Show tool icons", isOn: self.preferences.binding(\.showToolIcons))
                SettingsMenuBarDisplaySection(showsUsageText: Binding(
                    get: { self.coordinator.draft.showsMenuBarUsageText },
                    set: { self.coordinator.update(\.showsMenuBarUsageText, to: $0, field: .showsMenuBarUsageText) }
                ))
            }
            SettingsPreferenceSection(L.zh ? "透明度与尺寸" : "Opacity and size") {
                self.slider(L.zh ? "背景不透明度" : "Background opacity", keyPath: \.backgroundOpacity, range: 0.35...1)
                self.slider(L.zh ? "界面字号" : "Text size", keyPath: \.fontScale, range: 0.85...1.3)
                Button(L.zh ? "恢复外观默认值" : "Reset appearance") {
                    self.preferences.update {
                        $0.theme = .dark; $0.accentColor = .teal; $0.backgroundOpacity = 1; $0.fontScale = 1
                        $0.showAppIcon = true; $0.showTokenRate = true; $0.showToolIcons = true
                    }
                }
            }
        }
        .font(.system(size: 12))
    }

    private func slider(_ title: String, keyPath: WritableKeyPath<ApplicationPreferences, Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((self.preferences.preferences[keyPath: keyPath] * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(SettingsPalette.muted)
            }
            Slider(value: self.preferences.binding(keyPath), in: range, step: 0.05)
        }
    }
}

struct SettingsToolsPage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    @ObservedObject private var preferences = ApplicationPreferencesStore.shared
    @ObservedObject private var toolUsage = ToolUsageStore.shared
    @ObservedObject private var exportService = ScheduledUsageExportService.shared
    @State private var aliasSource = ""
    @State private var aliasTarget = ""
    @State private var directoryDrafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsOrderedPreferences(
                title: L.zh ? "显示与采集" : "Display and collection",
                order: self.preferences.binding(\.toolOrder), hidden: self.preferences.binding(\.disabledTools),
                defaults: ApplicationPreferences.allTools
            )
            SettingsSelectionField(L.zh ? "采集频率" : "Collection frequency", selection: self.preferences.binding(\.refreshIntervalSeconds), options: [
                (30, L.zh ? "每 30 秒" : "Every 30 seconds"),
                (90, L.zh ? "每 90 秒" : "Every 90 seconds"),
                (300, L.zh ? "每 5 分钟" : "Every 5 minutes"),
                (900, L.zh ? "每 15 分钟" : "Every 15 minutes"),
            ])
            SettingsPreferenceNote(L.zh ? "此频率用于本地记录采集；Cursor 远端自动同步至少间隔 5 分钟，手动刷新可立即执行。" : "This controls local collection. Automatic Cursor server sync runs at most every five minutes; manual refresh can run immediately.")
            Button(self.toolUsage.isRefreshing ? (L.zh ? "正在读取…" : "Reading…") : (L.zh ? "立即读取工具用量" : "Refresh tool usage now")) { self.toolUsage.refreshIfNeeded(force: true) }
                .disabled(self.toolUsage.isRefreshing)
            self.sourceDirectories
            self.exports
            self.aliases
            SettingsModelPricingSection(coordinator: self.coordinator)
        }
        .font(.system(size: 12))
    }

    private var sourceDirectories: some View {
        SettingsPreferenceSection(L.zh ? "数据目录" : "Data directories") {
            SettingsPreferenceNote(L.zh ? "留空使用默认目录，编辑后按回车应用。Codex 跟随当前已配置的数据源。" : "Leave empty for the standard location; press Return to apply edits. Codex follows its configured data source.")
            ForEach(ToolUsageClient.allCases) { client in
                VStack(alignment: .leading, spacing: 5) {
                    Text(client.displayName).font(.system(size: 11, weight: .medium))
                    HStack {
                        TextField(self.defaultDirectory(client), text: Binding(
                            get: { self.directoryDrafts[client.rawValue] ?? self.preferences.preferences.customDataDirectories[client.rawValue] ?? "" },
                            set: { self.directoryDrafts[client.rawValue] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let path = self.directoryDrafts[client.rawValue] {
                                self.preferences.update { $0.customDataDirectories[client.rawValue] = path }
                            }
                        }
                        Button(L.zh ? "选择" : "Choose") {
                            if let path = Self.pickDirectory() {
                                self.directoryDrafts[client.rawValue] = path
                                self.preferences.update { $0.customDataDirectories[client.rawValue] = path }
                            }
                        }
                        Button(L.zh ? "重置" : "Reset") {
                            self.directoryDrafts.removeValue(forKey: client.rawValue)
                            self.preferences.update { $0.customDataDirectories.removeValue(forKey: client.rawValue) }
                        }
                    }
                }
            }
        }
    }

    private var exports: some View {
        SettingsPreferenceSection(L.zh ? "用量导出" : "Usage export") {
            Toggle(L.zh ? "定时导出用量" : "Export usage on a schedule", isOn: self.preferences.binding(\.scheduledExportEnabled))
            HStack {
                Text(self.preferences.preferences.scheduledExportDirectory.isEmpty ? (L.zh ? "尚未选择文件夹" : "No folder selected") : self.preferences.preferences.scheduledExportDirectory)
                    .font(.system(size: 10, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button(L.zh ? "选择目录" : "Choose folder") {
                    if let path = Self.pickDirectory() { self.preferences.update { $0.scheduledExportDirectory = path } }
                }
            }
            SettingsSelectionField(L.zh ? "导出频率" : "Export frequency", selection: self.preferences.binding(\.scheduledExportIntervalSeconds), options: [
                (3600, L.zh ? "每小时" : "Hourly"),
                (86400, L.zh ? "每天" : "Daily"),
                (604800, L.zh ? "每周" : "Weekly"),
            ])
            HStack {
                Button(L.zh ? "立即导出" : "Export now") { _ = self.exportService.exportNow() }
                    .disabled(self.preferences.preferences.scheduledExportDirectory.isEmpty)
                if let url = self.exportService.lastExportURL {
                    Button(L.zh ? "在 Finder 中显示" : "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            if let errorMessage = self.exportService.errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
            }
            SettingsPreferenceNote(L.zh ? "仅导出用量统计，不导出账户凭证或会话正文。需要先选择目录。" : "Exports usage statistics without account credentials or conversation content. Select an output folder first.")
        }
    }

    private var aliases: some View {
        SettingsPreferenceSection(L.zh ? "模型别名" : "Model aliases") {
            SettingsPreferenceNote(L.zh ? "替换看板中的模型显示名称；原始记录与统计分组保持不变。" : "Replace model display names in the dashboard while preserving original records and statistical groups.")
            ForEach(self.preferences.preferences.modelAliases.keys.sorted(), id: \.self) { source in
                HStack {
                    Text(source).lineLimit(1)
                    Image(systemName: "arrow.right").foregroundStyle(SettingsPalette.muted)
                    Text(self.preferences.preferences.modelAliases[source] ?? "").lineLimit(1)
                    Spacer()
                    Button {
                        self.preferences.update { $0.modelAliases.removeValue(forKey: source) }
                    } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel(L.zh ? "删除别名" : "Remove alias")
                }
                .font(.system(size: 11, design: .monospaced))
            }
            HStack {
                TextField(L.zh ? "原模型名" : "Original model", text: self.$aliasSource)
                Image(systemName: "arrow.right")
                TextField(L.zh ? "显示名称" : "Display name", text: self.$aliasTarget)
                Button(L.zh ? "添加" : "Add") {
                    self.preferences.update { $0.modelAliases[self.aliasSource.trimmingCharacters(in: .whitespacesAndNewlines)] = self.aliasTarget.trimmingCharacters(in: .whitespacesAndNewlines) }
                    self.aliasSource = ""; self.aliasTarget = ""
                }
                .disabled(self.aliasSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.aliasTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.textFieldStyle(.roundedBorder)
        }
    }

    private func defaultDirectory(_ client: ToolUsageClient) -> String {
        switch client {
        case .claudeCode: "~/.claude"
        case .openCode: "~/.local/share/opencode"
        case .cursor: "~/Library/Application Support/Cursor/User/globalStorage"
        case .deepSeekHarness: "~/.dsh"
        }
    }

    private static func pickDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct SettingsQuotaPreferencesPage: View {
    @ObservedObject private var preferences = ApplicationPreferencesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSelectionField(L.zh ? "额度刷新频率" : "Quota refresh frequency", selection: self.preferences.binding(\.quotaRefreshIntervalSeconds), options: [
                (60, L.zh ? "每分钟" : "Every minute"),
                (300, L.zh ? "每 5 分钟" : "Every 5 minutes"),
                (900, L.zh ? "每 15 分钟" : "Every 15 minutes"),
                (3600, L.zh ? "每小时" : "Hourly"),
            ])
            SettingsPreferenceNote(L.zh ? "当前账户按此间隔刷新，全账户轮询至少间隔 5 分钟。" : "This controls the current account. All-account polling runs at least five minutes apart.")
            Picker(L.zh ? "账号显示" : "Account display", selection: self.preferences.binding(\.accountIdentityDisplay)) {
                Text(L.zh ? "邮箱" : "Email").tag(ApplicationPreferences.AccountIdentityDisplay.email)
                Text(L.zh ? "名字" : "Name").tag(ApplicationPreferences.AccountIdentityDisplay.name)
            }
            .pickerStyle(.segmented)
            SettingsPreferenceNote(L.zh ? "Codex 额度来自已登录账户；其他工具只有在其数据源提供额度时才能显示。账户登录、切换与聚合在管理视图。" : "Codex quotas come from signed-in accounts. Other tools need a source that exposes quotas. Use Management to sign in, switch or aggregate accounts.")
        }
        .font(.system(size: 12))
        .padding(.bottom, 20)
    }
}

private struct SettingsOrderedPreferences: View {
    let title: String
    @Binding var order: [String]
    @Binding var hidden: [String]
    let defaults: [String]
    var lockedVisible: Set<String> = []

    var body: some View {
        SettingsPreferenceSection(self.title) {
            HStack {
                SettingsPreferenceNote(L.zh ? "勾选以显示，使用箭头调整顺序。" : "Choose visibility and use the arrows to reorder.")
                Spacer()
                Button(L.zh ? "全部显示" : "Show all") { self.hidden = [] }
                Button(L.zh ? "重置顺序" : "Reset order") { self.order = self.defaults }
            }
            ForEach(Array(self.order.enumerated()), id: \.element) { index, key in
                HStack(spacing: 10) {
                    Toggle(Self.label(key), isOn: Binding(
                        get: { !self.hidden.contains(key) },
                        set: { visible in
                            if visible { self.hidden.removeAll { $0 == key } }
                            else if !self.lockedVisible.contains(key) { self.hidden.append(key) }
                        }
                    ))
                    .disabled(self.lockedVisible.contains(key))
                    Spacer()
                    Button { self.move(index, offset: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).accessibilityLabel(L.zh ? "上移" : "Move up")
                    Button { self.move(index, offset: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == self.order.count - 1).accessibilityLabel(L.zh ? "下移" : "Move down")
                }
                .font(.system(size: 12))
            }
        }
    }

    private func move(_ index: Int, offset: Int) {
        let target = index + offset
        guard self.order.indices.contains(index), self.order.indices.contains(target) else { return }
        self.order.swapAt(index, target)
    }

    private static func label(_ key: String) -> String {
        if key == "codex" { return "Codex" }
        if let client = ToolUsageClient(rawValue: key) { return client.displayName }
        switch key {
        case "home": return L.zh ? "主页" : "Home"
        case "limits": return L.zh ? "额度" : "Limits"
        case "tools": return L.zh ? "工具" : "Tools"
        case "models": return L.zh ? "模型" : "Models"
        case "projects": return L.zh ? "项目" : "Projects"
        case "sessions": return L.zh ? "会话" : "Sessions"
        case "devices": return L.zh ? "设备" : "Devices"
        case "trends": return L.zh ? "趋势" : "Trends"
        case "activity": return L.zh ? "活动" : "Activity"
        default: return key
        }
    }
}

struct SettingsPreferenceSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(SettingsPalette.muted)
            self.content
            SettingsPalette.divider.frame(height: 1).padding(.top, 5)
        }
    }
}

struct SettingsPreferenceNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(self.text).font(.system(size: 10)).foregroundStyle(SettingsPalette.muted).fixedSize(horizontal: false, vertical: true)
    }
}
