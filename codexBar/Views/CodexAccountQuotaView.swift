import SwiftUI

/// 可复用于管理列表和额度看板的账号额度详情，账号标题与操作由外层提供。
@MainActor
struct CodexAccountQuotaView: View {
    enum DisplayScope {
        case all
        case activeAccount(usesReserve: Bool)
    }

    let account: TokenAccount
    let mode: CodexBarUsageDisplayMode
    let now: Date
    var displayScope: DisplayScope = .all
    var showsFooter = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if self.windows.isEmpty {
                if self.showsFooter {
                    Text(self.updatedLabel)
                        .font(MenuSurface.font(size: 9))
                        .foregroundStyle(MenuSurface.muted)
                        .accessibilityIdentifier(self.identifier("updated"))
                }
                Text(L.zh ? "额度未知" : "Quota unknown")
                    .font(MenuSurface.font(size: 10))
                    .foregroundStyle(MenuSurface.muted)
                    .accessibilityIdentifier(self.identifier("unknown"))
                if self.resetCount > 0 {
                    self.resetCardsLabel
                }
            } else {
                ForEach(self.windows) { window in
                    self.windowRow(window)
                }
                if self.showsFooter {
                    self.footer
                } else if self.resetCount > 0 {
                    self.resetCardsLabel
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var windows: [CodexAccountQuotaWindow] {
        // 普通额度窗口会按时长排序、去重；先规范化，再将显示窗口与重置时间配对。
        // 在配对完成之前不要过滤窗口，否则副窗口可能错用主窗口的重置时间。
        let normalized = self.account.normalizedQuotaSnapshot(now: self.now)
        let hasRegularSnapshot = self.account.lastChecked != nil
            || self.account.primaryLimitWindowSeconds != nil
            || self.account.secondaryLimitWindowSeconds != nil
            || self.account.primaryResetAt != nil
            || self.account.secondaryResetAt != nil
            || self.account.primaryUsedPercent != 0
            || self.account.secondaryUsedPercent != 0
        let paired: [CodexAccountQuotaWindow] = normalized.usageWindowDisplays(mode: self.mode).enumerated().compactMap { index, display in
            let isReserve = display.label == L.lunaReserve
            guard hasRegularSnapshot || isReserve else { return nil }
            let resetAt = isReserve ? normalized.lunaReserveResetAt
                : (index == 0 ? normalized.primaryResetAt : normalized.secondaryResetAt)
            return CodexAccountQuotaWindow(display: display, resetAt: resetAt)
        }
        switch self.displayScope {
        case .all: return paired
        case .activeAccount(usesReserve: true):
            return paired.filter { $0.display.label == L.lunaReserve }
        case .activeAccount(usesReserve: false):
            return Array(paired.prefix(2))
        }
    }

    var resetCount: Int {
        max(self.account.rateLimitResetAvailableCount,
            self.account.availableRateLimitResetCredits(now: self.now).count)
    }

    private var updatedLabel: String {
        guard let checked = self.account.lastChecked else {
            return L.zh ? "尚未刷新" : "Not refreshed yet"
        }
        let seconds = max(0, Int(self.now.timeIntervalSince(checked)))
        if seconds < 60 { return L.justUpdated }
        if seconds < 3_600 { return L.minutesAgo(seconds / 60) }
        if seconds < 86_400 { return L.hoursAgo(seconds / 3_600) }
        return checked.formatted(date: .abbreviated, time: .shortened)
    }

    private var resetCardsText: String {
        "\(self.resetCount) " + (L.zh ? "张重置卡" : "resets available")
    }

    private var resetCardsLabel: some View {
        Text(self.resetCardsText)
            .font(MenuSurface.font(size: 9, design: .monospaced))
            .foregroundStyle(MenuSurface.muted)
            .accessibilityIdentifier(self.identifier("reset-cards"))
    }

    /// 与 Antigravity / Cursor 相同：窗口名、重置倒计时在左，绿色进度条和百分比只占右侧。
    private var footer: some View {
        HStack(spacing: 6) {
            Text(self.mode.badgeTitle)
                .font(MenuSurface.font(size: 9))
                .foregroundColor(.secondary.opacity(0.75))
            if self.resetCount > 0 {
                Text("·")
                    .font(MenuSurface.font(size: 9))
                    .foregroundColor(.secondary.opacity(0.45))
                self.resetCardsLabel
            }
            Spacer(minLength: 4)
            Text(self.updatedLabel)
                .font(MenuSurface.font(size: 9))
                .foregroundColor(.secondary.opacity(0.7))
                .lineLimit(1)
                .accessibilityIdentifier(self.identifier("updated"))
        }
    }

    private func windowRow(_ window: CodexAccountQuotaWindow) -> some View {
        let remaining = window.display.remainingPercent
        return HStack(spacing: 6) {
            Text(window.display.label)
                .font(MenuSurface.font(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(Self.compactResetDescription(window.resetAt, now: self.now))
                .font(MenuSurface.font(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            if let percent = window.percent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(self.barColor(remainingPercent: remaining))
                            .frame(width: max(0, geo.size.width * min(percent, 100) / 100))
                    }
                }
                .frame(width: 58, height: 4)
                .accessibilityHidden(true)

                Text("\(Int(percent))%")
                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(remaining <= 0 ? .red : .primary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text(L.zh ? "额度未知" : "Quota unknown")
                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(MenuSurface.muted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(self.identifier("window.\(window.id)"))
    }

    static func compactResetDescription(_ resetAt: Date?, now: Date) -> String {
        guard let resetAt else { return L.zh ? "重置时间未知" : "Reset time unknown" }
        let seconds = Int(resetAt.timeIntervalSince(now))
        if seconds <= 0 { return L.resetSoon }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    private func barColor(remainingPercent: Double) -> Color {
        switch self.mode {
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

    private func identifier(_ detail: String) -> String {
        let prefix: String
        switch self.displayScope {
        case .all: prefix = "codexbar.codex-quota"
        case .activeAccount: prefix = "codexbar.management.codex-summary.quota"
        }
        return "\(prefix).\(self.account.id).\(detail)"
    }
}

struct CodexAccountQuotaWindow: Identifiable {
    let display: UsageWindowDisplay
    let resetAt: Date?

    var id: String { self.display.id }
    var percent: Double? {
        guard self.display.usedPercent.isFinite, self.display.displayPercent.isFinite else { return nil }
        return min(100, max(0, self.display.displayPercent))
    }
}
