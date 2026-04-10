import SwiftUI

/// One org/account row under an email group
struct AccountRowView: View {
    let account: TokenAccount
    let rowState: OpenAIAccountRowState
    let isRefreshing: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    let defaultManualActivationBehavior: CodexBarOpenAIManualActivationBehavior?
    let onActivate: (OpenAIManualActivationTrigger) -> Void
    let onRefresh: () -> Void
    let onReauth: () -> Void
    let onDelete: () -> Void

    @State private var isHoveringPlanBadge = false

    var body: some View {
        HStack(spacing: 4) {
            if self.usesExpandedTeamBadgeHoverLayout == false {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            self.planBadge

            if self.usesExpandedTeamBadgeHoverLayout == false {
                usageSummary

                if let runningThreadBadgeTitle = rowState.runningThreadBadgeTitle {
                    Text(runningThreadBadgeTitle)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }

                if self.rowState.isNextUseTarget {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 10))
                }
            }

            Spacer(minLength: self.usesExpandedTeamBadgeHoverLayout ? 0 : 6)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)

            if account.tokenExpired {
                Button(L.reauth, action: onReauth)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .font(.system(size: 10, weight: .medium))
                    .tint(.orange)
            } else if !account.isBanned {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )
                }
                .buttonStyle(.borderless)
                .foregroundColor(isRefreshing ? .accentColor : .secondary)
                .disabled(isRefreshing)

                if rowState.showsUseAction {
                    Button(rowState.useActionTitle) {
                        onActivate(OpenAIAccountPresentation.primaryManualActivationTrigger)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 16)   // indent under email header
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(rowBorderColor, lineWidth: 0.6)
        }
        .overlay(alignment: .leading) {
            if self.rowState.isNextUseTarget {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .contextMenu {
            if let defaultManualActivationBehavior,
               rowState.showsUseAction {
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
        }
    }

    @ViewBuilder
    private var usageSummary: some View {
        HStack(spacing: 6) {
            ForEach(Array(account.usageWindowDisplays(mode: self.usageDisplayMode).enumerated()), id: \.offset) { index, window in
                if index > 0 {
                    Text("•")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Text(window.label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("\(Int(window.displayPercent))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(usageColor(window))
            }
        }
    }

    private var planBadge: some View {
        Text(
            OpenAIAccountPresentation.planBadgeTitle(
                for: self.account,
                isHovered: self.isHoveringPlanBadge
            )
        )
        .font(.system(size: 9, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .allowsTightening(self.usesExpandedTeamBadgeHoverLayout)
        .minimumScaleFactor(self.usesExpandedTeamBadgeHoverLayout ? 0.85 : 1)
        .layoutPriority(self.usesExpandedTeamBadgeHoverLayout ? 1 : 0)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(planBadgeColor.opacity(0.15))
        .foregroundColor(planBadgeColor)
        .cornerRadius(3)
        .contentShape(RoundedRectangle(cornerRadius: 3))
        .onHover { isHovering in
            self.isHoveringPlanBadge = isHovering
        }
    }

    private var usesExpandedTeamBadgeHoverLayout: Bool {
        OpenAIAccountPresentation.usesExpandedTeamBadgeHoverLayout(
            for: self.account,
            isHovered: self.isHoveringPlanBadge
        )
    }

    private var statusColor: Color {
        if account.isBanned { return .red }
        if account.quotaExhausted { return .orange }
        if account.isBelowVisualWarningThreshold() { return .yellow }
        return .green
    }

    private var rowBackgroundColor: Color {
        if self.rowState.isNextUseTarget { return Color.accentColor.opacity(0.14) }
        if account.isBanned { return Color.red.opacity(0.045) }
        if account.quotaExhausted { return Color.orange.opacity(0.05) }
        if account.isBelowVisualWarningThreshold() {
            return Color.yellow.opacity(0.05)
        }
        return Color.secondary.opacity(0.055)
    }

    private var rowBorderColor: Color {
        if self.rowState.isNextUseTarget { return Color.accentColor.opacity(0.28) }
        if account.isBanned { return Color.red.opacity(0.12) }
        if account.quotaExhausted { return Color.orange.opacity(0.14) }
        if account.isBelowVisualWarningThreshold() {
            return Color.yellow.opacity(0.14)
        }
        return Color.primary.opacity(0.08)
    }

    private var planBadgeColor: Color {
        switch account.planType.lowercased() {
        case "team": return .blue
        case "plus": return .purple
        default: return .gray
        }
    }

    private func usageColor(_ window: UsageWindowDisplay) -> Color {
        if window.usedPercent >= 100 { return .red }
        if window.remainingPercent <= OpenAIVisualWarningThreshold.remainingPercent {
            return .orange
        }

        switch self.usageDisplayMode {
        case .remaining:
            return .green
        case .used:
            if window.usedPercent >= 70 { return .orange }
            return .green
        }
    }
}
