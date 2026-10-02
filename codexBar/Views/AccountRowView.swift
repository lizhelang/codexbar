import SwiftUI

/// One org/account row under an email group
struct AccountRowView: View {
    private var mint: Color { MenuSurface.accent }
    private var graphite: Color { MenuSurface.raised }
    let account: TokenAccount
    let accountLabel: String
    let accountDetail: String?
    let rowState: OpenAIAccountRowState
    let isRefreshing: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    let defaultManualActivationBehavior: CodexBarOpenAIManualActivationBehavior?
    let onActivate: (OpenAIManualActivationTrigger) -> Void
    let onRefresh: () -> Void
    let onReauth: () -> Void
    let onDelete: () -> Void

    @State private var isHoveringUsage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(self.statusDescription)

                self.planBadge

                VStack(alignment: .leading, spacing: 1) {
                    Text(self.accountLabel)
                        .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(self.accountLabel)
                        .accessibilityLabel(self.accountLabel)
                    if let accountDetail {
                        Text(accountDetail)
                            .font(MenuSurface.font(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if self.rowState.isNextUseTarget {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(self.mint)
                        .font(MenuSurface.font(size: 11))
                        .accessibilityLabel(L.zh ? "下次使用的账号" : "Next account to use")
                }

                Spacer(minLength: 4)

                if account.tokenExpired {
                    Button(L.reauth, action: onReauth)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(MenuSurface.font(size: 10, weight: .medium))
                        .tint(.orange)
                } else if self.canPerformManualActivation {
                    Button(
                        OpenAIAccountPresentation.manualActivationButtonTitle(
                            defaultBehavior: defaultManualActivationBehavior
                        )
                    ) {
                        onActivate(OpenAIAccountPresentation.primaryManualActivationTrigger)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .font(MenuSurface.font(size: 10, weight: .medium))
                    .tint(self.mint)
                }

                self.moreActionsMenu
            }

            HStack(spacing: 6) {
                usageSummary
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if let runningThreadBadgeTitle = rowState.runningThreadBadgeTitle {
                    Text(runningThreadBadgeTitle)
                        .font(MenuSurface.font(size: 9, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.10))
                        .foregroundColor(Color.primary.opacity(0.68))
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(rowBorderColor, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if self.rowState.isNextUseTarget {
                RoundedRectangle(cornerRadius: 2)
                    .fill(self.mint)
                    .frame(width: 2)
                    .padding(.vertical, 8)
            }
        }
        .contextMenu {
            if let defaultManualActivationBehavior,
               self.canPerformManualActivation {
                ForEach(
                    OpenAIAccountPresentation.manualActivationContextActions(
                        defaultBehavior: defaultManualActivationBehavior
                    ),
                    id: \.behavior
                ) { action in
                    Button {
                        onActivate(action.trigger)
                    } label: {
                        if action.isDefault {
                            Label(action.title, systemImage: "checkmark")
                        } else {
                            Text(action.title)
                        }
                    }
                }
            }

            Divider()
            if account.tokenExpired == false && account.isBanned == false {
                Button(L.refreshUsage, action: onRefresh)
                    .disabled(self.isRefreshing)
            }
            Button(role: .destructive, action: onDelete) {
                Label(L.delete, systemImage: "trash")
            }
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            if let defaultManualActivationBehavior,
               self.canPerformManualActivation {
                ForEach(
                    OpenAIAccountPresentation.manualActivationContextActions(
                        defaultBehavior: defaultManualActivationBehavior
                    ),
                    id: \.behavior
                ) { action in
                    Button {
                        onActivate(action.trigger)
                    } label: {
                        if action.isDefault {
                            Label(action.title, systemImage: "checkmark")
                        } else {
                            Text(action.title)
                        }
                    }
                }
                Divider()
            }

            if account.tokenExpired == false && account.isBanned == false {
                Button(action: onRefresh) {
                    Label(L.refreshUsage, systemImage: "arrow.clockwise")
                }
                .disabled(self.isRefreshing)
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(L.delete, systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(MenuSurface.font(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L.zh ? "更多账号操作" : "More account actions")
        .accessibilityLabel(L.zh ? "更多账号操作" : "More account actions")
    }

    private var canPerformManualActivation: Bool {
        self.account.tokenExpired == false
            && self.account.isBanned == false
            && self.showsManualActivationAction
    }

    private var showsManualActivationAction: Bool {
        self.rowState.showsManualActivationAction(
            defaultBehavior: self.defaultManualActivationBehavior
        )
    }

    @ViewBuilder
    private var usageSummary: some View {
        let windows = account.usageWindowDisplays(mode: self.usageDisplayMode)
        let regularWindows = account.lunaReserveUsedPercent == nil ? windows : Array(windows.dropLast())

        let showsReserve = OpenAIAccountPresentation.showsReserveUsage(
            for: account,
            isHovered: self.isHoveringUsage
        )
        let visibleWindows = showsReserve ? Array(windows.suffix(1)) : regularWindows

        HStack(spacing: 6) {
            Text(self.usageDisplayMode.badgeTitle)
                .font(MenuSurface.font(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
            ForEach(Array(visibleWindows.enumerated()), id: \.offset) { index, window in
                if index > 0 {
                    Text("•")
                        .font(MenuSurface.font(size: 9))
                        .foregroundColor(.secondary)
                }
                Text(window.label)
                    .font(MenuSurface.font(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("\(Int(window.displayPercent))%")
                    .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(usageColor(window))
            }
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .onHover { self.isHoveringUsage = $0 }
    }

    private var planBadge: some View {
        Text(OpenAIAccountPresentation.planBadgeTitle(for: self.account, isHovered: false))
        .font(MenuSurface.font(size: 9, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(planBadgeColor.opacity(0.18))
        .foregroundColor(planBadgeColor)
        .cornerRadius(3)
    }

    private var statusDescription: String {
        if self.account.isBanned { return L.zh ? "账号已停用" : "Account suspended" }
        if self.account.tokenExpired { return L.zh ? "需要重新授权" : "Reauthorization required" }
        if self.account.quotaExhausted { return L.zh ? "额度已用尽" : "Quota exhausted" }
        if self.account.isBelowVisualWarningThreshold() { return L.zh ? "额度较低" : "Quota running low" }
        return L.zh ? "账号可用" : "Account available"
    }

    private var statusColor: Color {
        if account.isBanned { return .red }
        if account.tokenExpired { return .orange }
        if account.quotaExhausted { return .orange }
        if account.isBelowVisualWarningThreshold() { return .yellow }
        return .green
    }

    private var rowBackgroundColor: Color {
        if self.rowState.isNextUseTarget { return self.graphite.opacity(0.96) }
        if account.isBanned { return self.graphite.opacity(0.86) }
        if account.quotaExhausted { return self.graphite.opacity(0.86) }
        if account.isBelowVisualWarningThreshold() {
            return self.graphite.opacity(0.86)
        }
        return self.graphite.opacity(0.78)
    }

    private var rowBorderColor: Color {
        if self.rowState.isNextUseTarget { return self.mint.opacity(0.55) }
        if account.isBanned { return Color.red.opacity(0.24) }
        if account.quotaExhausted { return Color.orange.opacity(0.25) }
        if account.isBelowVisualWarningThreshold() {
            return Color.yellow.opacity(0.25)
        }
        return Color.primary.opacity(0.12)
    }

    private var planBadgeColor: Color {
        switch account.planType.lowercased() {
        case "team": return Color(red: 0.58, green: 0.76, blue: 0.93)
        case "plus": return self.mint
        default: return Color.primary.opacity(0.62)
        }
    }

    private func usageColor(_ window: UsageWindowDisplay) -> Color {
        if window.usedPercent >= 100 { return .red }
        if window.remainingPercent <= OpenAIVisualWarningThreshold.remainingPercent {
            return .orange
        }

        switch self.usageDisplayMode {
        case .remaining:
            return self.mint
        case .used:
            if window.usedPercent >= 70 { return .orange }
            return self.mint
        }
    }
}
