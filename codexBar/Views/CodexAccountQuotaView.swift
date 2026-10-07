import SwiftUI

/// 可复用于管理列表和额度看板的账号额度详情，账号标题与操作由外层提供。
@MainActor
struct CodexAccountQuotaView: View {
    let account: TokenAccount
    let mode: CodexBarUsageDisplayMode
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.updatedLabel)
                .font(MenuSurface.font(size: 9, design: .monospaced))
                .foregroundStyle(MenuSurface.muted)
                .accessibilityIdentifier(self.identifier("updated"))

            if self.windows.isEmpty {
                Text(L.zh ? "额度未知" : "Quota unknown")
                    .font(MenuSurface.font(size: 10))
                    .foregroundStyle(MenuSurface.muted)
                    .accessibilityIdentifier(self.identifier("unknown"))
            } else {
                ForEach(self.windows) { window in
                    self.windowRow(window)
                }
            }

            if self.resetCount > 0 {
                Text("\(self.resetCount) " + (L.zh ? "张重置卡" : "resets available"))
                    .font(MenuSurface.font(size: 9, design: .monospaced))
                    .foregroundStyle(MenuSurface.muted)
                    .accessibilityIdentifier(self.identifier("reset-cards"))
            }
        }
        .padding(.top, 4)
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
        return normalized.usageWindowDisplays(mode: self.mode).enumerated().compactMap { index, display in
            let isReserve = display.label == L.lunaReserve
            guard hasRegularSnapshot || isReserve else { return nil }
            let resetAt = isReserve ? normalized.lunaReserveResetAt
                : (index == 0 ? normalized.primaryResetAt : normalized.secondaryResetAt)
            return CodexAccountQuotaWindow(display: display, resetAt: resetAt)
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
        return (L.zh ? "更新于 " : "Updated ") + checked.formatted(date: .abbreviated, time: .shortened)
    }

    private func windowRow(_ window: CodexAccountQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.display.label).foregroundStyle(MenuSurface.muted)
                Spacer(minLength: 4)
                if let percent = window.percent {
                    Text("\(Int(percent))% " + self.mode.badgeTitle)
                        .monospacedDigit()
                } else {
                    Text(L.zh ? "额度未知" : "Quota unknown")
                        .foregroundStyle(MenuSurface.muted)
                }
            }
            .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))

            if let percent = window.percent {
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(0.10))
                        .overlay(alignment: .leading) {
                            Capsule().fill(self.color(for: window.display))
                                .frame(width: geometry.size.width * percent / 100)
                        }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
            }

            Text(self.resetLabel(window.resetAt))
                .font(MenuSurface.font(size: 9, design: .monospaced))
                .foregroundStyle(MenuSurface.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(self.identifier("window.\(window.id)"))
    }

    private func resetLabel(_ resetAt: Date?) -> String {
        guard let resetAt else { return L.zh ? "重置时间未知" : "Reset time unknown" }
        let remaining = resetAt.timeIntervalSince(self.now)
        guard remaining > 0 else { return L.resetSoon }
        let seconds = Int(remaining)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return L.resetInDay(days, hours) }
        if hours > 0 { return L.resetInHr(hours, minutes) }
        return L.resetInMin(minutes)
    }

    private func color(for window: UsageWindowDisplay) -> Color {
        if window.usedPercent >= 100 { return .red }
        if window.remainingPercent <= OpenAIVisualWarningThreshold.remainingPercent { return .orange }
        if self.mode == .used && window.usedPercent >= 70 { return .orange }
        return MenuSurface.accent
    }

    private func identifier(_ detail: String) -> String {
        "codexbar.codex-quota.\(self.account.id).\(detail)"
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
