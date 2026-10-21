import AppKit
import SwiftUI

/// Inline metadata keeps update freshness visible without reserving a footer row.
struct AccountUpdateLabel: View {
    let isCurrent: Bool
    let updatedAt: Date?
    var now: Date = Date()
    var additionalHelp: String? = nil

    var body: some View {
        Text(self.title)
            .font(MenuSurface.font(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(self.detail)
            .accessibilityLabel(self.detail)
    }

    private var title: String {
        let update: String
        if let updatedAt {
            let seconds = max(0, Int(self.now.timeIntervalSince(updatedAt)))
            if seconds < 60 { update = L.zh ? "刚更新" : "now" }
            else if seconds < 3_600 { update = L.zh ? "\(seconds / 60)m前" : "\(seconds / 60)m ago" }
            else if seconds < 86_400 { update = L.zh ? "\(seconds / 3_600)h前" : "\(seconds / 3_600)h ago" }
            else { update = L.zh ? "\(seconds / 86_400)d前" : "\(seconds / 86_400)d ago" }
        } else {
            update = L.zh ? "未刷新" : "not refreshed"
        }
        return self.isCurrent ? (L.zh ? "当前 · " : "Current · ") + update : update
    }

    private var detail: String {
        var parts: [String] = []
        if self.isCurrent { parts.append(L.zh ? "当前账号" : "Current account") }
        parts.append(self.updatedAt.map {
            (L.zh ? "更新于 " : "Updated ") + $0.formatted(date: .abbreviated, time: .standard)
        } ?? (L.zh ? "尚未刷新" : "Not refreshed yet"))
        if let additionalHelp, !additionalHelp.isEmpty { parts.append(additionalHelp) }
        return parts.joined(separator: "；")
    }
}

// MARK: - 额度行（与 AntigravityAccountQuotaView 同款）

struct CursorAccountQuotaView: View {
    let quota: ToolQuotaSnapshot?
    let state: CursorAccountState?
    let usageDisplayMode: CodexBarUsageDisplayMode
    var showsFooter = true
    var balance: ToolQuotaBalance? = nil
    var balanceIsSnapshot = false
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let message = self.problemMessage {
                Text(message)
                    .font(MenuSurface.font(size: 10))
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let windows = self.quota?.windows ?? []
            if !windows.isEmpty {
                ForEach(windows) { window in
                    self.usageRow(window: window)
                }
                if let balance = self.balance {
                    self.balanceRow(balance)
                }
                if self.showsFooter {
                    self.footer
                }
            } else if let balance = self.balance {
                self.balanceRow(balance)
                if self.showsFooter {
                    self.footer
                }
            } else if self.problemMessage == nil {
                if (self.quota?.resetCredits?.availableCount(at: self.now) ?? 0) == 0 {
                    Text(self.emptyMessage)
                        .font(MenuSurface.font(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            if let quota = self.quota {
                ClaudeResetCreditsView(snapshot: quota, now: self.now)
            }
        }
    }

    private var problemMessage: String? {
        if self.state?.status == .paused {
            return L.zh ? "已暂停读取此账号" : "Collection paused for this account"
        }
        if self.state?.status == .authenticationRequired || self.quota?.status == .authenticationRequired {
            return L.zh ? "登录已过期，请在右侧菜单更新凭据" : "Session expired — update credentials from the menu"
        }
        if self.quota?.status == .failed {
            let detail = self.quota?.statusDetail ?? ""
            return detail.isEmpty ? (L.zh ? "额度读取失败" : "Failed to load limits") : detail
        }
        if self.state == nil,
           let quota = self.quota,
           quota.status != .ready,
           quota.status != .loading,
           !quota.statusDetail.isEmpty {
            return quota.statusDetail
        }
        return nil
    }

    private var emptyMessage: String {
        if self.state?.status == .refreshing || self.quota?.status == .loading {
            return L.zh ? "正在读取额度…" : "Loading limits…"
        }
        if self.state != nil || self.quota?.client == .cursor {
            return L.zh ? "点击刷新读取 Cursor 额度" : "Refresh to load Cursor limits"
        }
        return L.zh ? "点击刷新读取额度" : "Refresh to load limits"
    }

    private func balanceRow(_ balance: ToolQuotaBalance) -> some View {
        HStack(spacing: 6) {
            Text(self.balanceIsSnapshot
                 ? (L.zh ? "快照余额" : "Snapshot")
                 : (L.zh ? "账户余额" : "Balance"))
                .font(MenuSurface.font(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(balance.amount.formatted(.currency(code: balance.currency)))
                .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(self.usageDisplayMode.badgeTitle)
                .font(MenuSurface.font(size: 9))
                .foregroundColor(.secondary.opacity(0.75))
            if let tokens = self.totalTokens, tokens > 0 {
                Text("· " + Self.compactTokens(tokens) + " tokens")
                    .font(MenuSurface.font(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let updatedAt = self.state?.refreshedAt ?? self.quota?.refreshedAt {
                Text(self.relativeTime(updatedAt))
                    .font(MenuSurface.font(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    private var totalTokens: Int? {
        guard let usage = self.state?.usage else { return nil }
        return usage.dailyEntries.reduce(0) { $0 + $1.totalTokens }
    }

    @ViewBuilder
    private func usageRow(window: ToolQuotaWindow) -> some View {
        HStack(spacing: 6) {
            Text(window.label)
                .font(MenuSurface.font(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(Self.resetDescription(window.resetsAt, now: self.now))
                .font(MenuSurface.font(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            if let used = window.usedPercent {
                let usedPercent = min(max(used, 0), 100)
                let remaining = 100 - usedPercent
                let display = self.usageDisplayMode == .remaining ? remaining : usedPercent
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(self.barColor(remainingPercent: remaining))
                            .frame(width: max(0, geo.size.width * display / 100))
                    }
                }
                .frame(width: 58, height: 4)

                if window.unit == "USD", let amount = self.amountText(window) {
                    Text(amount)
                        .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minWidth: 34, alignment: .trailing)
                } else {
                    Text("\(Int(display.rounded()))%")
                        .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(remaining <= 0 ? .red : .primary)
                        .frame(width: 34, alignment: .trailing)
                }
            } else if let amount = self.amountText(window) {
                Text(amount)
                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func amountText(_ window: ToolQuotaWindow) -> String? {
        guard let used = window.used else { return window.limit.map { Self.amount($0, unit: window.unit) } }
        if let limit = window.limit, limit > 0 {
            return Self.amount(used, unit: window.unit) + "/" + Self.amount(limit, unit: window.unit)
        }
        return Self.amount(used, unit: window.unit)
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
        let seconds = max(0, Int(self.now.timeIntervalSince(date)))
        if seconds < 60 { return L.justUpdated }
        if seconds < 3600 { return L.minutesAgo(seconds / 60) }
        if seconds < 86_400 { return L.hoursAgo(seconds / 3600) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func resetDescription(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return L.zh ? "即将重置" : "resetting" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    static func amount(_ value: Double, unit: String?) -> String {
        if unit == "USD" {
            return "$" + value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : 2)))
        }
        return value.formatted(.number.precision(.fractionLength(0...1))) + (unit.map { " " + $0 } ?? "")
    }

    static func compactTokens(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }
}

// MARK: - 平铺账号行（与 AntigravityAccountRowView 同款）

struct CursorAccountRowView: View {
    let account: CursorManagedAccount
    let state: CursorAccountState?
    let displayLabel: String
    let secondaryLabel: String?
    let isActive: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onRename: () -> Void
    let onUpdateCredential: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    var isSummary = false
    var compactManagement = false
    var now: Date = Date()

    @State private var isHovering = false

    static func statusColor(_ state: CursorAccountState?) -> Color {
        guard let state else { return .gray }
        if state.status == .paused { return .gray }
        if state.status == .authenticationRequired { return .orange }
        switch state.quota?.status {
        case .ready?:
            return Self.isExhausted(state.quota) ? .orange : .green
        case .authenticationRequired?:
            return .orange
        case .failed?:
            return .red
        default:
            return .gray
        }
    }

    static func isExhausted(_ quota: ToolQuotaSnapshot?) -> Bool {
        guard let quota else { return false }
        let percents = quota.windows.filter { $0.unit != "USD" }.compactMap(\.usedPercent)
        guard !percents.isEmpty else { return false }
        return percents.allSatisfy { $0 >= 100 }
    }

    static func planBadgeTitle(_ plan: String?) -> String {
        let raw = (plan ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "CURSOR" : raw.uppercased()
    }

    static func planBadgeColor(_ title: String) -> Color {
        switch title {
        case "ULTRA": return .purple
        case "SUPER": return .pink
        case "PREMIUM": return .orange
        case "PLUS": return .blue
        case "PRO", "PRO+", "PRO_PLUS", "PRO_STUDENT", "BUSINESS", "TEAM", "ENTERPRISE": return .cyan
        default: return .gray
        }
    }

    var body: some View {
        let badge = Self.planBadgeTitle(self.account.planType)
        let badgeColor = Self.planBadgeColor(badge)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Self.statusColor(self.state))
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
                    if !self.isSummary {
                        Text(badge)
                            .font(MenuSurface.font(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(badgeColor)
                    }
                    if self.state?.status == .refreshing {
                        ProgressView().controlSize(.mini)
                    }
                    if self.compactManagement {
                        AccountUpdateLabel(isCurrent: self.isActive,
                            updatedAt: self.state?.refreshedAt ?? self.state?.quota?.refreshedAt,
                            now: self.now, additionalHelp: self.recordedUsageHelp)
                    } else if self.isActive {
                        Text(L.zh ? "当前账号" : "Current")
                            .font(MenuSurface.font(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if !self.isActive, self.isHovering, !self.account.isPaused {
                        Button(L.zh ? "切换" : "Use") { self.onActivate() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .font(MenuSurface.font(size: 10, weight: .semibold))
                            .accessibilityIdentifier("codexbar.cursor.account.\(self.account.id).select")
                    }

                    Menu {
                        if !self.isActive, !self.account.isPaused {
                            Button(L.zh ? "切换到此账号" : "Switch to account") { self.onActivate() }
                            Divider()
                        }
                        if self.account.isPaused {
                            Button(L.zh ? "恢复读取" : "Resume collection") { self.onResume() }
                        } else {
                            Button(L.refreshUsage) { self.onRefresh() }
                        }
                        Button(L.zh ? "修改名称" : "Rename") { self.onRename() }
                        if !self.account.isDesktop {
                            Button(L.zh ? "更新凭据" : "Update credentials") { self.onUpdateCredential() }
                            Divider()
                            Button(L.zh ? "删除账号" : "Delete account", role: .destructive) { self.onDelete() }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(MenuSurface.font(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                    .accessibilityIdentifier("codexbar.cursor.account.\(self.account.id).actions")
                }
                .fixedSize()
            }

            CursorAccountQuotaView(
                quota: self.state?.quota,
                state: self.state,
                usageDisplayMode: self.usageDisplayMode,
                showsFooter: !self.compactManagement,
                now: self.now
            )
        }
        .padding(.vertical, self.isSummary ? 0 : (self.compactManagement ? 5 : 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { self.isHovering = $0 }
        .accessibilityIdentifier("codexbar.cursor.account.\(self.account.id)")
    }

    private var recordedUsageHelp: String? {
        guard let entries = self.state?.usage?.dailyEntries, !entries.isEmpty else { return nil }
        let total = entries.reduce(0) { current, entry in
            let (sum, overflow) = current.addingReportingOverflow(max(0, entry.totalTokens))
            return overflow ? Int.max : sum
        }
        return L.zh ? "已记录历史用量：\(total.formatted()) Token" : "Recorded usage history: \(total.formatted()) tokens"
    }
}

// MARK: - 菜单栏 Cursor 管理面板

struct CursorManagementPanel: View {
    @ObservedObject var cursorAccounts: CursorAccountStore
    let connections: ToolConnectionStore
    let collapsed: Bool
    var compactManagement: Bool = false
    let usageDisplayMode: CodexBarUsageDisplayMode
    let privacyLabel: (String) -> String
    let onAddAccount: () -> Void
    let onShowUsage: () -> Void
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: self.compactManagement ? 6 : 10) {
            if !self.compactManagement {
                HStack {
                    Text(L.zh ? "\(self.cursorAccounts.accounts.count) 个账号" : "\(self.cursorAccounts.accounts.count) accounts")
                        .foregroundStyle(MenuSurface.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { self.onAddAccount() } label: {
                        Label(L.zh ? "手动添加账号" : "Add account manually", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MenuSurface.accent)
                    .accessibilityIdentifier("codexbar.management.cursor.add-account-inline")
                }
                .font(MenuSurface.font(size: 9, weight: .medium))
            }

            if self.collapsed {
                self.activeSummary
                    .accessibilityIdentifier("codexbar.management.cursor.summary")
            } else {
                self.accountsSection
                    .accessibilityIdentifier("codexbar.management.cursor.details")
            }
        }
    }

    private var activeAccount: CursorManagedAccount? {
        self.cursorAccounts.selectedAccount ?? self.cursorAccounts.accounts.first
    }

    @ViewBuilder
    private var activeSummary: some View {
        if let account = self.activeAccount {
            VStack(alignment: .leading, spacing: 6) {
                self.row(account, isSummary: true)
                if !self.compactManagement {
                    HStack {
                        Spacer(minLength: 4)
                        Button { self.onShowUsage() } label: {
                            Label(L.zh ? "查看用量" : "View usage", systemImage: "arrow.right")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MenuSurface.accent)
                        .accessibilityIdentifier("codexbar.tool-quota.cursor.usage")
                    }
                    .font(MenuSurface.font(size: 9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            self.emptyCard
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: self.compactManagement ? 6 : 10) {
            HStack(spacing: 8) {
                Text(L.zh ? "CURSOR 账号" : "CURSOR ACCOUNTS")
                    .font(MenuSurface.font(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(MenuSurface.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !self.cursorAccounts.accounts.isEmpty {
                    let total = self.cursorAccounts.accounts.count
                    let available = self.cursorAccounts.accounts.filter {
                        CursorAccountRowView.statusColor(self.cursorAccounts.states[$0.id]) == .green
                    }.count
                    Text(L.zh ? "\(available)/\(total) 可用" : "\(available)/\(total) available")
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

            if self.cursorAccounts.accounts.isEmpty {
                self.emptyCard
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.cursorAccounts.accounts) { account in
                        self.row(account)
                    }
                }
                if !self.compactManagement {
                    HStack {
                        Spacer(minLength: 4)
                        Button { self.onShowUsage() } label: {
                            Label(L.zh ? "查看用量" : "View usage", systemImage: "arrow.right")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MenuSurface.accent)
                    }
                    .font(MenuSurface.font(size: 9))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ account: CursorManagedAccount, isSummary: Bool = false) -> some View {
        let primary = isSummary || account.alias.isEmpty
            ? (account.email ?? account.name ?? (account.alias.isEmpty ? account.userID : account.alias)) : account.alias
        let secondary = isSummary || account.alias.isEmpty ? nil : (account.email ?? account.name)
        return CursorAccountRowView(
            account: account,
            state: self.cursorAccounts.states[account.id],
            displayLabel: self.privacyLabel(primary),
            secondaryLabel: secondary.map(self.privacyLabel),
            isActive: self.cursorAccounts.selectedAccountID == account.id,
            usageDisplayMode: self.usageDisplayMode,
            onActivate: { try? self.cursorAccounts.selectAccount(account.id) },
            onRefresh: { Task { await self.cursorAccounts.refreshAccount(account.id, force: true) } },
            onRename: {
                ManagedToolAccountsView.presentDetachedCursorAccountForm(
                    accountID: account.id, alias: account.alias, rename: true,
                    cursorAccounts: self.cursorAccounts, connections: self.connections)
            },
            onUpdateCredential: {
                ManagedToolAccountsView.presentDetachedCursorAccountForm(
                    accountID: account.id, alias: account.alias, rename: false,
                    cursorAccounts: self.cursorAccounts, connections: self.connections)
            },
            onResume: {
                try? self.cursorAccounts.setPaused(account.id, paused: false)
                Task { await self.cursorAccounts.refreshAccount(account.id, force: true) }
            },
            onDelete: { try? self.cursorAccounts.removeAccount(account.id) },
            isSummary: isSummary,
            compactManagement: self.compactManagement,
            now: self.now
        )
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.zh ? "还没有 Cursor 账号" : "No Cursor account added")
                .font(MenuSurface.font(size: 11, weight: .medium))
            Text(self.cursorAccounts.status ?? (self.compactManagement
                 ? (L.zh ? "点击顶部 ＋ 添加账号，或从菜单识别本机登录" : "Use + above to add an account, or discover a local sign-in from the menu")
                 : (L.zh ? "登录 Cursor 桌面端会自动识别，也可以手动添加账号" : "Sign in to Cursor desktop or add an account manually")))
                .font(MenuSurface.font(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(MenuSurface.raised))
    }
}
