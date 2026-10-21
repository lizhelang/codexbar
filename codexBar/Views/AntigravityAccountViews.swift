import AppKit
import SwiftUI

struct AntigravityAccountQuotaView: View {
    let account: AntigravityAccount
    let usageDisplayMode: CodexBarUsageDisplayMode
    var now: Date = Date()
    var showsFooter = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if self.account.status == .reauthRequired {
                Text(L.zh ? "凭证已过期，请点击右侧菜单重新授权" : "Token expired — use the menu to re-authenticate")
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.orange)
            } else if self.account.status == .error, let message = self.account.statusMessage, !message.isEmpty {
                Text(message)
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }

            if !self.account.quotaWindows.isEmpty {
                ForEach(self.account.quotaWindows) { window in
                    self.usageRow(window: window)
                }

                if self.showsFooter {
                    HStack(spacing: 6) {
                        Text(self.usageDisplayMode.badgeTitle)
                            .font(MenuSurface.font(size: 9))
                            .foregroundColor(.secondary.opacity(0.75))

                        Spacer(minLength: 4)

                        if let updatedAt = self.account.lastUpdatedAt {
                            Text(self.relativeTime(updatedAt))
                                .font(MenuSurface.font(size: 9))
                                .foregroundColor(.secondary.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
            } else if self.account.status == .ok {
                HStack(spacing: 6) {
                    Text(L.zh ? "点击刷新读取 Gemini 与 Claude/GPT 额度" : "Refresh to load Gemini & Claude/GPT quotas")
                        .font(MenuSurface.font(size: 9))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func usageRow(window: AntigravityQuotaWindow) -> some View {
        let displayPercent = window.displayPercent(mode: self.usageDisplayMode)
        let remainingPercent = window.remainingPercent
        return HStack(spacing: 6) {
            Text(window.shortLabel)
                .font(MenuSurface.font(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(window.resetDescription(now: self.now))
                .font(MenuSurface.font(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(self.barColor(remainingPercent: remainingPercent))
                        .frame(width: max(0, geo.size.width * min(displayPercent, 100) / 100))
                }
            }
            .frame(width: 58, height: 4)

            Text("\(Int(displayPercent))%")
                .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(remainingPercent <= 0 ? .red : .primary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func barColor(remainingPercent: Double) -> Color {
        switch self.usageDisplayMode {
        case .remaining:
            if remainingPercent > 40 { return .green }
            if remainingPercent > 15 { return .yellow }
            return .red
        case .used:
            if remainingPercent <= 15 { return .red }
            if remainingPercent <= 40 { return .yellow }
            return .accentColor
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(self.now.timeIntervalSince(date))
        if seconds < 60 { return L.justUpdated }
        if seconds < 3600 { return L.minutesAgo(seconds / 60) }
        return L.hoursAgo(seconds / 3600)
    }
}

struct AntigravityAccountRowView: View {
    let account: AntigravityAccount
    let displayLabel: String
    let isRefreshing: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onReauth: () -> Void
    let onDelete: () -> Void
    var now: Date = Date()
    var compactManagement = false

    @State private var isHovering = false

    private var statusDotColor: Color {
        switch self.account.status {
        case .reauthRequired:
            return .orange
        case .error:
            return .red
        case .ok:
            return self.account.quotaExhausted ? .orange : .green
        }
    }

    private var planBadgeColor: Color {
        switch self.account.planBadgeTitle {
        case "ULTRA":
            return .purple
        case "PRO":
            return .cyan
        default:
            return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(self.statusDotColor)
                    .frame(width: 7, height: 7)

                Text(self.displayLabel)
                    .font(MenuSurface.font(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if let name = self.account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty,
                   name != self.displayLabel {
                    Text(name)
                        .font(MenuSurface.font(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                Text(self.account.planBadgeTitle)
                    .font(MenuSurface.font(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(self.planBadgeColor)
                    .fixedSize()

                HStack(spacing: 4) {
                    if self.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if self.compactManagement {
                        AccountUpdateLabel(isCurrent: self.account.isActive,
                                           updatedAt: self.account.lastUpdatedAt, now: self.now)
                    } else if !self.isRefreshing, self.account.isActive {
                        Text(L.zh ? "当前账号" : "Current")
                            .font(MenuSurface.font(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if !self.isRefreshing, !self.account.isActive, self.isHovering {
                        Button(L.zh ? "切换" : "Use") {
                            self.onActivate()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(MenuSurface.font(size: 10, weight: .semibold))
                    }

                    Menu {
                        if !self.account.isActive {
                            Button(L.zh ? "切换到此账号" : "Switch to account") {
                                self.onActivate()
                            }
                            Divider()
                        }
                        Button(L.refreshUsage) {
                            self.onRefresh()
                        }
                        Button(L.zh ? "重新授权" : "Re-authenticate") {
                            self.onReauth()
                        }
                        Divider()
                        Button(L.zh ? "删除账号" : "Delete account", role: .destructive) {
                            self.onDelete()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(MenuSurface.font(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                    .help(L.zh ? "账号操作" : "Account actions")
                    .accessibilityLabel(L.zh ? "账号操作" : "Account actions")
                }
                .fixedSize()
            }

            AntigravityAccountQuotaView(
                account: self.account,
                usageDisplayMode: self.usageDisplayMode,
                now: self.now,
                showsFooter: !self.compactManagement
            )
        }
        .padding(.vertical, self.compactManagement ? 6 : 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isHovering = hovering
        }
        .accessibilityIdentifier("codexbar.antigravity.account.\(self.account.id)")
    }
}

struct AntigravityOAuthSheet: View {
    @ObservedObject var coordinator: AntigravityLoginCoordinator
    @ObservedObject var store: AntigravityAccountStore
    let onClose: () -> Void

    @State private var callbackInput = ""
    @State private var tokenJSONInput = ""
    @State private var showManualTokenImport = false
    @State private var copiedLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MenuSurface.accent)
                Text(L.zh ? "添加 Antigravity 账号" : "Add Antigravity Account")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L.cancel) {
                    self.coordinator.stop()
                    self.onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(
                L.zh
                    ? "已在浏览器打开 Google OAuth 登录页。授权完成后会自动回调并导入账号；如果在其他浏览器完成登录，也可以将回调链接粘贴到下方。"
                    : "Google OAuth sign-in has been opened in your browser. Once authorized, the account will be imported automatically, or you can paste the callback URL below."
            )
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    if let url = self.coordinator.activeSession?.authorizationURL {
                        NSWorkspace.shared.open(url)
                    } else {
                        self.coordinator.startBrowserOAuth(store: self.store, openBrowser: true)
                    }
                } label: {
                    Label(
                        L.zh ? "在浏览器中打开 Google 授权" : "Open Google Sign-In",
                        systemImage: "safari"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if let authURL = self.coordinator.activeSession?.authorizationURL {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(authURL.absoluteString, forType: .string)
                        self.copiedLink = true
                    } label: {
                        Label(
                            self.copiedLink
                                ? (L.zh ? "已复制链接" : "Copied")
                                : (L.zh ? "复制授权链接" : "Copy Link"),
                            systemImage: self.copiedLink ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    self.store.load()
                    Task {
                        await self.store.refreshAll(force: true)
                    }
                } label: {
                    Label(
                        L.zh ? "扫描本机已登录账号" : "Scan Local Account",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L.zh ? "手动粘贴 OAuth 回调链接（可选）" : "Paste OAuth Callback URL (Optional)")
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 8) {
                    TextField(
                        "http://localhost:51121/auth/callback?code=...",
                        text: self.$callbackInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                    Button(L.zh ? "完成授权" : "Complete") {
                        Task {
                            _ = await self.coordinator.completeCallback(
                                callbackInput: self.callbackInput,
                                store: self.store
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(self.callbackInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.coordinator.isExchanging)
                }
            }

            DisclosureGroup(
                isExpanded: self.$showManualTokenImport,
                content: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            L.zh
                                ? "支持直接粘贴 ~/.gemini/jetski-standalone-oauth-token 的 JSON 内容："
                                : "Paste the JSON contents of ~/.gemini/jetski-standalone-oauth-token:"
                        )
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                        TextEditor(text: self.$tokenJSONInput)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 84)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )

                        HStack {
                            Spacer()
                            Button(L.zh ? "导入凭证 JSON" : "Import Token JSON") {
                                Task {
                                    _ = await self.coordinator.importManualTokenJSON(
                                        self.tokenJSONInput,
                                        store: self.store
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(self.tokenJSONInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.coordinator.isExchanging)
                        }
                    }
                    .padding(.top, 6)
                },
                label: {
                    Text(L.zh ? "使用凭证 JSON 导入" : "Import via Token JSON")
                        .font(.system(size: 11, weight: .medium))
                }
            )

            if self.coordinator.isExchanging {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L.zh ? "正在验证账号并同步额度…" : "Verifying account and fetching quota…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if let errorMessage = self.coordinator.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 480)
    }
}
