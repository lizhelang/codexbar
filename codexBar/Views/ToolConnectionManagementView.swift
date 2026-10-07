import AppKit
import SwiftUI

/// Configures collection from a client's existing data and login state.
/// Credentials stay with the original client; only Codexbar preferences are changed here.
@MainActor
struct ToolConnectionManagementView: View {
    let client: ToolUsageClient
    @ObservedObject var preferencesStore: ApplicationPreferencesStore
    @ObservedObject var toolUsageStore: ToolUsageStore
    let importCursorCSV: (() -> Void)?
    let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var directoryDraft: String
    @State private var directoryError: String?

    init(
        client: ToolUsageClient,
        preferencesStore: ApplicationPreferencesStore,
        toolUsageStore: ToolUsageStore,
        importCursorCSV: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.client = client
        self.preferencesStore = preferencesStore
        self.toolUsageStore = toolUsageStore
        self.importCursorCSV = importCursorCSV
        self.onClose = onClose
        self._directoryDraft = State(initialValue: preferencesStore.preferences.customDataDirectories[client.rawValue] ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.client.displayName).font(.system(size: 18, weight: .semibold))
                    Text(L.zh ? "用量与额度管理" : "Usage and quota management")
                        .font(.system(size: 11)).foregroundStyle(SettingsPalette.muted)
                }
                Spacer()
                Button(L.zh ? "完成" : "Done") {
                    if let onClose { onClose() } else { self.dismiss() }
                }
                    .accessibilityIdentifier(self.identifier("done"))
            }
            .padding(20)
            SettingsPalette.divider.frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsPreferenceSection(L.zh ? "读取设置" : "Collection") {
                        Toggle(L.zh ? "启用用量采集与额度读取" : "Enable usage collection and quota reading", isOn: Binding(
                            get: { self.isEnabled },
                            set: { self.setEnabled($0) }
                        ))
                        .accessibilityIdentifier(self.identifier("enabled"))
                        SettingsPreferenceNote(L.zh
                            ? "暂停后保留已读取的历史用量，停止新的采集与额度请求。"
                            : "Pausing keeps collected history and stops new collection and quota requests.")
                        HStack {
                            Button(self.isRefreshing
                                ? (L.zh ? "正在刷新…" : "Refreshing…")
                                : (L.zh ? "刷新用量与额度" : "Refresh usage and quota")) {
                                self.refresh()
                            }
                            .disabled(!self.isEnabled || self.isRefreshing)
                            .accessibilityIdentifier(self.identifier("refresh"))
                            if self.client == .cursor, let importCursorCSV {
                                Button(L.zh ? "导入用量 CSV" : "Import usage CSV", action: importCursorCSV)
                                    .disabled(!self.isEnabled || self.isRefreshing)
                                    .accessibilityIdentifier(self.identifier("import-csv"))
                            }
                        }
                    }

                    SettingsPreferenceSection(L.zh ? "当前状态" : "Current status") {
                        self.statusRow(L.zh ? "用量" : "Usage", value: self.usageStatus)
                        if let detail = self.toolUsageStore.snapshot(for: self.client).statusDetail {
                            SettingsPreferenceNote(detail)
                        }
                        self.statusRow(L.zh ? "额度" : "Quota", value: self.quotaStatus)
                        if self.isEnabled {
                            SettingsPreferenceNote(self.toolUsageStore.quota(for: self.client).statusDetail)
                        }
                        if self.isEnabled, let updatedAt = self.toolUsageStore.quota(for: self.client).refreshedAt {
                            Text(L.zh ? "额度更新：\(updatedAt.formatted(date: .abbreviated, time: .shortened))"
                                 : "Quota updated: \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(SettingsPalette.muted)
                        }
                    }

                    SettingsPreferenceSection(L.zh ? "数据目录" : "Data directory") {
                        Text(self.effectiveDirectory.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SettingsPalette.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(self.identifier("current-directory"))
                        TextField(Self.defaultDataDirectory(for: self.client).path, text: self.$directoryDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { self.applyDirectoryDraft() }
                            .accessibilityLabel(L.zh ? "自定义数据目录" : "Custom data directory")
                            .accessibilityIdentifier(self.identifier("directory"))
                        HStack {
                            Button(L.zh ? "选择目录" : "Choose folder") { self.chooseDirectory() }
                                .accessibilityIdentifier(self.identifier("choose-directory"))
                            Button(L.zh ? "保存目录" : "Save folder") { self.applyDirectoryDraft() }
                                .accessibilityIdentifier(self.identifier("save-directory"))
                            Button(L.zh ? "恢复默认" : "Use default") {
                                self.resetDataDirectory()
                                self.directoryDraft = ""
                                self.directoryError = nil
                            }
                            .accessibilityIdentifier(self.identifier("reset-directory"))
                        }
                        SettingsPreferenceNote(L.zh
                            ? "选择软件的数据根目录；输入后按回车或保存。留空恢复默认位置，启用时会自动重新读取。"
                            : "Choose the client's data root. Press Return or Save to apply. Leave empty for the default; enabled clients reload automatically.")
                        if let directoryError {
                            Text(directoryError).font(.system(size: 11)).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SettingsPreferenceNote(self.directoryDescription)
                    }

                    SettingsPreferenceSection(L.zh ? "登录与额度来源" : "Sign-in and quota source") {
                        SettingsPreferenceNote(self.connectionDescription)
                    }
                }
                .font(.system(size: 12))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(SettingsPalette.foreground)
        .background(SettingsPalette.canvas)
        .frame(minWidth: 420, idealWidth: 540, minHeight: 560, idealHeight: 680)
    }

    var isEnabled: Bool { !self.preferencesStore.preferences.disabledTools.contains(self.client.rawValue) }
    var isRefreshing: Bool { self.toolUsageStore.isRefreshing || self.toolUsageStore.isRefreshingQuotas }

    func setEnabled(_ enabled: Bool) {
        self.preferencesStore.update { preferences in
            preferences.disabledTools.removeAll { $0 == self.client.rawValue }
            if !enabled { preferences.disabledTools.append(self.client.rawValue) }
        }
    }

    func refresh() {
        guard self.isEnabled, !self.isRefreshing else { return }
        self.toolUsageStore.refreshIfNeeded(force: true)
    }

    /// Rejects a file or a relative path instead of silently collecting the wrong source.
    /// A blank value restores the original client's default location.
    @discardableResult
    func saveDataDirectory(_ draft: String) -> String? {
        let path = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            self.resetDataDirectory()
            return nil
        }
        let expanded = NSString(string: path).expandingTildeInPath
        guard NSString(string: expanded).isAbsolutePath else {
            return L.zh ? "请输入绝对目录路径，或使用 ~ 表示用户目录。" : "Enter an absolute folder path, or use ~ for your home directory."
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            return L.zh ? "目录不存在或路径指向文件，请选择软件的数据目录。" : "The folder does not exist or the path points to a file. Choose the client's data directory."
        }
        let normalized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        self.preferencesStore.update { $0.customDataDirectories[self.client.rawValue] = normalized }
        return nil
    }

    func resetDataDirectory() {
        self.preferencesStore.update { $0.customDataDirectories.removeValue(forKey: self.client.rawValue) }
    }

    static func defaultDataDirectory(for client: ToolUsageClient) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        switch client {
        case .claudeCode:
            return home.appendingPathComponent(".claude")
        case .openCode:
            let root = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".local/share")
            return root.appendingPathComponent("opencode")
        case .cursor:
            return home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
        case .deepSeekHarness:
            return environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".dsh")
        }
    }

    private var effectiveDirectory: URL {
        self.preferencesStore.preferences.dataDirectory(for: self.client.rawValue)
            ?? Self.defaultDataDirectory(for: self.client)
    }

    private var usageStatus: String {
        guard self.isEnabled else { return L.zh ? "已暂停" : "Paused" }
        switch self.toolUsageStore.snapshot(for: self.client).availability {
        case .ready: return L.zh ? "已读取" : "Available"
        case .partial: return L.zh ? "部分记录已读取" : "Partial records"
        case .noRecords: return L.zh ? "尚无记录" : "No records"
        case .sourceMissing: return L.zh ? "未找到数据源" : "Source not found"
        case .needsImport: return L.zh ? "等待登录或导入 CSV" : "Sign in or import CSV"
        case .failed: return L.zh ? "读取失败" : "Read failed"
        }
    }

    private var quotaStatus: String {
        guard self.isEnabled else { return L.zh ? "已暂停" : "Paused" }
        switch self.toolUsageStore.quota(for: self.client).status {
        case .loading: return L.zh ? "尚未读取" : "Not read yet"
        case .ready: return self.toolUsageStore.quota(for: self.client).providerName
        case .notConfigured: return L.zh ? "未连接账号" : "Not connected"
        case .unsupported: return L.zh ? "服务未提供额度" : "Quota unavailable"
        case .authenticationRequired: return L.zh ? "需要重新登录" : "Sign-in required"
        case .failed: return L.zh ? "额度读取失败" : "Quota read failed"
        }
    }

    private var directoryDescription: String {
        switch self.client {
        case .claudeCode:
            return L.zh ? "根目录下的 projects / transcripts 用于采集用量，settings.json 与原应用登录状态用于读取额度。未指定目录时，额度读取也遵循 CLAUDE_CONFIG_DIR。"
                : "Usage comes from projects / transcripts under this root. Quota uses settings.json and the client's sign-in state. Without an override, quota also follows CLAUDE_CONFIG_DIR."
        case .openCode:
            return L.zh ? "根目录下的 opencode.db / storage 用于采集用量，auth.json 用于已支持服务的额度读取。OPENCODE_DB 环境变量仍可覆盖数据库位置；接入地址继续使用 OpenCode 的原有全局配置。"
                : "Usage comes from opencode.db / storage; quota uses supported services in auth.json. OPENCODE_DB can override the database location. Provider endpoints still follow OpenCode's global configuration."
        case .cursor:
            return L.zh ? "选择包含 state.vscdb 的 globalStorage 目录，用于自动识别桌面登录。手动账号由账号管理独立保存；CSV 用量导入绑定看板选中的监测账号。"
                : "Choose globalStorage containing state.vscdb for desktop discovery. Manual accounts are managed separately; CSV imports belong to the selected dashboard account."
        case .deepSeekHarness:
            return L.zh ? "根目录下的 sessions 用于采集用量，dsh-usage/provider-snapshots.json 用于读取 DSH 保存的接入服务余额。"
                : "Usage comes from sessions. Provider balances saved by DSH come from dsh-usage/provider-snapshots.json."
        }
    }

    private var connectionDescription: String {
        switch self.client {
        case .claudeCode:
            return L.zh ? "自动识别已有 Claude Code OAuth 文件或钥匙串。账号管理也支持网站 sessionKey 和组织选择，网站连接优先；API Key 不包含官方订阅额度。"
                : "Discover Claude Code OAuth files or Keychain. Account management also supports a web sessionKey and organization selection, with web connections taking priority; API keys do not include subscription limits."
        case .openCode:
            return L.zh ? "自动识别 OpenCode Go 和已绑定官方地址的 DeepSeek 接入，也可在账号管理中添加 Go API Key 或网站 Cookie。各连接分别查询额度；OpenAI 登录不会作为 Go 账号。"
                : "Discover OpenCode Go and officially bound DeepSeek connections, or add Go API keys and web cookies in account management. Limits are separate per connection; OpenAI sign-ins are not Go accounts."
        case .cursor:
            return L.zh ? "账号管理支持自动识别桌面登录及手动 Cookie／JWT 多账号，各账号独立查询用量和额度。先连接并选择看板账号，再导入属于该账号的 CSV。"
                : "Account management supports desktop discovery and manual Cookie/JWT accounts with separate usage and limits. Connect and select the dashboard account before importing its CSV."
        case .deepSeekHarness:
            return L.zh ? "读取 DSH 保存的服务余额快照。账号管理可手动设置官方 DeepSeek API Key；环境 Key 必须明确绑定官方地址，余额保留原币种。"
                : "Read saved DSH provider balance snapshots, or set an official DeepSeek API key in account management. Environment keys require an explicit official endpoint binding; balances keep their currency."
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(SettingsPalette.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func identifier(_ suffix: String) -> String { "codexbar.tool-connection.\(self.client.rawValue).\(suffix)" }

    private func applyDirectoryDraft() {
        self.directoryError = self.saveDataDirectory(self.directoryDraft)
        if self.directoryError == nil {
            self.directoryDraft = self.preferencesStore.preferences.customDataDirectories[self.client.rawValue] ?? ""
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = self.effectiveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.directoryDraft = url.path
        self.applyDirectoryDraft()
    }
}
