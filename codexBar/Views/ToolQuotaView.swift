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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: self.toggle) {
                HStack(spacing: 7) {
                    Image(systemName: self.symbol).foregroundStyle(self.tint)
                    Text(self.snapshot.client.displayName)
                        .font(MenuSurface.font(size: 12, weight: .semibold, design: .monospaced))
                    Spacer(minLength: 2)
                    if self.snapshot.status != .ready {
                        Text(self.statusLabel).font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.muted)
                    }
                    Image(systemName: self.expanded ? "chevron.down" : "chevron.right")
                        .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
            if self.expanded || self.snapshot.status != .ready {
                Text(self.snapshot.statusDetail)
                    .font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.expanded {
                if let refreshed = self.snapshot.refreshedAt {
                    Text(self.snapshot.providerName + " · " + (L.zh ? "更新于 " : "Updated ")
                         + refreshed.formatted(date: .abbreviated, time: .shortened))
                        .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                }
                HStack {
                    Button(action: self.refresh) {
                        Label(L.zh ? "刷新额度" : "Refresh limits", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    Button(action: self.showUsage) {
                        Label(L.zh ? "查看用量" : "View usage", systemImage: "arrow.right")
                    }
                }
                .buttonStyle(.plain).foregroundStyle(MenuSurface.accent)
                .font(MenuSurface.font(size: 10))
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { MenuSurface.line.frame(height: 1) }
    }

    private var statusLabel: String {
        switch self.snapshot.status {
        case .loading: L.zh ? "正在读取" : "Loading"
        case .ready: ""
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
