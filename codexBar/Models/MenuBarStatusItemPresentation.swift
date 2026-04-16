import AppKit
import Foundation

struct MenuBarStatusItemPresentation: Equatable {
    enum Emphasis: Equatable {
        case primary
        case secondary
        case warning
        case critical

        var foregroundColor: NSColor {
            switch self {
            case .primary:
                return .labelColor
            case .secondary:
                return .secondaryLabelColor
            case .warning:
                return .systemOrange
            case .critical:
                return .systemRed
            }
        }

        var fontWeight: NSFont.Weight {
            switch self {
            case .primary, .secondary:
                return .medium
            case .warning, .critical:
                return .semibold
            }
        }
    }

    let iconName: String
    let title: String
    let emphasis: Emphasis

    var foregroundColor: NSColor { self.emphasis.foregroundColor }
    var font: NSFont { .systemFont(ofSize: 12, weight: self.emphasis.fontWeight) }

    static func make(
        accounts: [TokenAccount],
        activeProvider: CodexBarProvider?,
        aggregateRoutedAccount: TokenAccount?,
        usageDisplayMode: CodexBarUsageDisplayMode,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        updateAvailable: Bool
    ) -> MenuBarStatusItemPresentation {
        let iconName = MenuBarIconResolver.iconName(
            accounts: accounts,
            activeProviderKind: activeProvider?.kind,
            updateAvailable: updateAvailable
        )

        if activeProvider?.kind == .openAIOAuth,
           accountUsageMode == .aggregateGateway,
           let aggregateRoutedAccount {
            let summary = aggregateRoutedAccount.compactPrimaryUsageSummary(mode: usageDisplayMode) ?? ""
            return MenuBarStatusItemPresentation(
                iconName: iconName,
                title: summary.isEmpty ? summary : L.openAIRouteSummaryCompact(summary),
                emphasis: .primary
            )
        }

        if let active = accounts.first(where: { $0.isActive }) {
            if active.secondaryExhausted {
                return MenuBarStatusItemPresentation(
                    iconName: iconName,
                    title: L.weeklyLimit,
                    emphasis: .critical
                )
            }
            if active.primaryExhausted {
                return MenuBarStatusItemPresentation(
                    iconName: iconName,
                    title: L.hourLimit,
                    emphasis: .warning
                )
            }
            return MenuBarStatusItemPresentation(
                iconName: iconName,
                title: active.usageWindowDisplays(mode: usageDisplayMode)
                    .map { "\(Int($0.displayPercent))%" }
                    .joined(separator: "·"),
                emphasis: .primary
            )
        }

        if let activeProvider {
            let label = activeProvider.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortLabel = label.count <= 6 ? label : String(label.prefix(6))
            return MenuBarStatusItemPresentation(
                iconName: iconName,
                title: shortLabel,
                emphasis: .secondary
            )
        }

        return MenuBarStatusItemPresentation(iconName: iconName, title: "", emphasis: .primary)
    }
}
