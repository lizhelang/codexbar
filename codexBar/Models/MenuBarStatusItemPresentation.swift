import AppKit
import Foundation

struct MenuBarStatusItemPresentation: Equatable {
    enum Emphasis: Equatable {
        case primary
        case secondary
        case warning
        case critical

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

    var font: NSFont { .systemFont(ofSize: 12, weight: self.emphasis.fontWeight) }
    var attributedTitle: NSAttributedString {
        guard self.title.isEmpty == false else {
            return NSAttributedString(string: "")
        }

        return NSAttributedString(
            string: " " + self.title,
            attributes: [
                .font: self.font,
            ]
        )
    }

    func makeTemplateImage(accessibilityDescription: String) -> NSImage? {
        let image = NSImage(
            systemSymbolName: self.iconName,
            accessibilityDescription: accessibilityDescription
        )
        image?.isTemplate = true
        return image
    }

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
