import SwiftUI

/// Quota comes from the account service, independently of local usage history.
@MainActor
struct ToolQuotaView: View {
    let snapshot: ToolQuotaSnapshot
    let symbol: String
    let tint: Color
    let mode: CodexBarUsageDisplayMode
    let expanded: Bool
    let toggle: () -> Void
    let refresh: () -> Void
    let showUsage: () -> Void
    var managementMode: Bool = false
    var isRefreshing: Bool = false
    var manage: (() -> Void)? = nil
    var canRefresh: Bool = true
    var statusTitle: String? = nil
    var showsHeader: Bool = true
    var compactManagementActions: Bool = false

    private var isCompactManagement: Bool { self.managementMode && self.compactManagementActions }
    private var showsDetails: Bool { (self.managementMode && !self.isCompactManagement) || self.expanded }
    private var refreshInProgress: Bool { self.isRefreshing || self.snapshot.status == .loading }
    private var showsStatusDetail: Bool {
        !self.snapshot.statusDetail.isEmpty &&
            (self.isCompactManagement ? self.snapshot.status != .ready
                : (self.showsDetails || self.snapshot.status != .ready))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.showsHeader {
                if self.managementMode && !self.isCompactManagement {
                    self.header
                } else {
                    Button(action: self.toggle) {
                        self.header
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(self.controlIdentifier("toggle"))
                }
            }
            ForEach(self.snapshot.windows) { window in
                self.windowRow(window)
            }
            if let balance = self.snapshot.balance {
                HStack {
                    Text(L.zh ? "账户余额" : "Account balance").foregroundStyle(MenuSurface.muted)
                    Spacer()
                    Text(balance.amount.formatted(.currency(code: balance.currency)))
                }
                .font(MenuSurface.font(size: 11, weight: .medium, design: .monospaced))
            }
            if self.showsStatusDetail {
                Text(self.snapshot.statusDetail)
                    .font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.muted)
                    .lineLimit(self.isCompactManagement ? 1 : nil)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: !self.isCompactManagement)
                    .help(self.snapshot.statusDetail)
                    .accessibilityIdentifier(self.controlIdentifier("status-detail"))
            }
            if self.showsDetails {
                if self.isCompactManagement {
                    HStack(spacing: 14) {
                        self.refreshButton
                        self.usageButton
                        self.manageButton
                        Spacer(minLength: 0)
                    }
                    .font(MenuSurface.font(size: 9))
                } else {
                    Text(self.providerAndRefreshLabel)
                        .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        self.refreshButton
                        Spacer()
                        self.usageButton
                    }
                    .font(MenuSurface.font(size: 10))
                    self.manageButton
                        .font(MenuSurface.font(size: 10))
                }
            }
        }
        .padding(.vertical, self.isCompactManagement ? 5 : 13)
        .overlay(alignment: .bottom) {
            if !self.isCompactManagement { MenuSurface.line.frame(height: 1) }
        }
    }

    private var refreshButton: some View {
        Button(action: self.refreshQuota) {
            Label(self.refreshInProgress ? (L.zh ? "正在刷新" : "Refreshing")
                  : (L.zh ? "刷新额度" : "Refresh limits"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .disabled(!self.canRefresh || self.refreshInProgress)
        .foregroundStyle(!self.canRefresh || self.refreshInProgress ? MenuSurface.muted : MenuSurface.accent)
        .accessibilityIdentifier(self.controlIdentifier("refresh"))
    }

    private var usageButton: some View {
        Button(action: self.showUsage) {
            Label(L.zh ? "查看用量" : "View usage", systemImage: "arrow.right")
        }
        .buttonStyle(.plain).foregroundStyle(MenuSurface.accent)
        .accessibilityIdentifier(self.controlIdentifier("usage"))
    }

    @ViewBuilder
    private var manageButton: some View {
        if self.managementMode, let manage = self.manage {
            Button(action: manage) {
                Label(L.zh ? "管理连接" : "Manage connection", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain).foregroundStyle(MenuSurface.accent)
            .accessibilityLabel((L.zh ? "管理 " : "Manage ") + self.snapshot.client.displayName
                                + (L.zh ? " 连接" : " connection"))
            .accessibilityIdentifier(self.controlIdentifier("manage"))
        }
    }

    func refreshQuota() {
        guard self.canRefresh, !self.refreshInProgress else { return }
        self.refresh()
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: self.symbol).foregroundStyle(self.tint)
            Text(self.snapshot.client.displayName)
                .font(MenuSurface.font(size: 12, weight: .semibold, design: .monospaced))
            Spacer(minLength: 2)
            if self.managementMode || self.snapshot.status != .ready {
                Text(self.statusTitle ?? self.statusLabel).font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.muted)
            }
            if !self.managementMode || self.isCompactManagement {
                Image(systemName: self.expanded ? "chevron.down" : "chevron.right")
                    .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
            }
        }
    }

    private var providerAndRefreshLabel: String {
        let updated = self.snapshot.refreshedAt.map {
            (L.zh ? "更新于 " : "Updated ") + $0.formatted(date: .abbreviated, time: .shortened)
        } ?? (L.zh ? "尚未刷新" : "Not refreshed yet")
        return self.snapshot.providerName + " · " + updated
    }

    private func controlIdentifier(_ action: String) -> String {
        "codexbar.tool-quota.\(self.snapshot.client.rawValue).\(action)"
    }

    private var statusLabel: String {
        switch self.snapshot.status {
        case .loading: L.zh ? "正在读取" : "Loading"
        case .ready: L.zh ? "已连接" : "Connected"
        case .notConfigured: L.zh ? "未连接账号" : "Not connected"
        case .unsupported: L.zh ? "服务未提供额度" : "No quota API"
        case .authenticationRequired: L.zh ? "需要重新登录" : "Sign in again"
        case .failed: L.zh ? "读取失败" : "Fetch failed"
        }
    }

    private func windowRow(_ window: ToolQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).foregroundStyle(MenuSurface.muted)
                Spacer()
                if let usedPercent = window.usedPercent, usedPercent.isFinite {
                    let percent = min(100, max(0, self.mode == .remaining ? 100 - usedPercent : usedPercent))
                    Text("\(Int(percent.rounded()))% " + self.mode.badgeTitle)
                } else if let used = window.used {
                    Text(self.amount(used, unit: window.unit)
                         + (window.limit.map { " / " + self.amount($0, unit: window.unit) } ?? ""))
                }
            }
            .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
            if let usedPercent = window.usedPercent, usedPercent.isFinite {
                let percent = self.mode == .remaining ? 100 - usedPercent : usedPercent
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(usedPercent >= 80 ? Color.orange : self.tint)
                            .frame(width: geometry.size.width * min(max(percent / 100, 0), 1))
                    }
                }
                .frame(height: 5)
            }
            if let reset = window.resetsAt {
                Text((L.zh ? "重置于 " : "Resets ") + reset.formatted(date: .abbreviated, time: .shortened))
                    .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
            }
        }
        .padding(.top, 3)
    }

    private func amount(_ value: Double, unit: String?) -> String {
        if unit == "USD" { return value.formatted(.currency(code: "USD")) }
        return value.formatted(.number.precision(.fractionLength(0...2))) + (unit.map { " " + $0 } ?? "")
    }
}
