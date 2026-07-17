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

    enum Icon: Equatable {
        case systemSymbol(String)
        case usageBars(MenuBarUsageIconSpec)
    }

    enum Layout: Equatable {
        case compact

        var statusItemLength: CGFloat {
            NSStatusItem.squareLength
        }

        var imagePosition: NSControl.ImagePosition {
            .imageOnly
        }
    }

    let icon: Icon
    let title: String
    let accessibilityValue: String
    let emphasis: Emphasis
    let layout: Layout

    init(
        icon: Icon,
        title: String,
        accessibilityValue: String,
        emphasis: Emphasis,
        layout: Layout
    ) {
        self.icon = icon
        self.title = title
        self.accessibilityValue = accessibilityValue
        self.emphasis = emphasis
        self.layout = layout
    }

    init(iconName: String, title: String, emphasis: Emphasis) {
        self.init(
            icon: .systemSymbol(iconName),
            title: title,
            accessibilityValue: title,
            emphasis: emphasis,
            layout: .compact
        )
    }

    var iconName: String? {
        guard case let .systemSymbol(iconName) = self.icon else { return nil }
        return iconName
    }

    var font: NSFont { .systemFont(ofSize: 12, weight: self.emphasis.fontWeight) }
    var contentTintColor: NSColor? {
        guard case .usageBars = self.icon else { return nil }
        switch self.emphasis {
        case .warning:
            return .systemOrange
        case .critical:
            return .systemRed
        case .primary, .secondary:
            return nil
        }
    }

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
        switch self.icon {
        case let .systemSymbol(iconName):
            let image = NSImage(
                systemSymbolName: iconName,
                accessibilityDescription: accessibilityDescription
            )
            image?.isTemplate = true
            return image
        case let .usageBars(spec):
            return MenuBarUsageIconRenderer.makeImage(
                spec: spec,
                accessibilityDescription: accessibilityDescription
            )
        }
    }

    static func make(
        accounts: [TokenAccount],
        activeProvider: CodexBarProvider?,
        aggregateRoutedAccount: TokenAccount?,
        usageDisplayMode: CodexBarUsageDisplayMode,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        updateAvailable: Bool,
        showsUsageText: Bool = false
    ) -> MenuBarStatusItemPresentation {
        let isAggregateOpenAI = activeProvider?.kind == .openAIOAuth &&
            accountUsageMode == .aggregateGateway
        let activeAccount = accounts.first(where: { $0.isActive })
        let displayAccount = isAggregateOpenAI ? aggregateRoutedAccount : activeAccount
        let iconAccounts = isAggregateOpenAI ? displayAccount.map { [$0] } ?? [] : accounts
        let iconName = MenuBarIconResolver.iconName(
            accounts: iconAccounts,
            activeProviderKind: activeProvider?.kind,
            updateAvailable: updateAvailable
        )

        let content = self.content(
            activeAccount: activeAccount,
            aggregateRoutedAccount: aggregateRoutedAccount,
            activeProvider: activeProvider,
            usageDisplayMode: usageDisplayMode,
            isAggregateOpenAI: isAggregateOpenAI
        )

        let icon = self.icon(
            resolvedSystemSymbol: iconName,
            displayAccount: displayAccount,
            activeProvider: activeProvider,
            usageDisplayMode: usageDisplayMode,
            showsPrimaryPercent: showsUsageText
        )

        return MenuBarStatusItemPresentation(
            icon: icon,
            title: "",
            accessibilityValue: content.accessibilityValue,
            emphasis: content.emphasis,
            layout: .compact
        )
    }

    private static func content(
        activeAccount: TokenAccount?,
        aggregateRoutedAccount: TokenAccount?,
        activeProvider: CodexBarProvider?,
        usageDisplayMode: CodexBarUsageDisplayMode,
        isAggregateOpenAI: Bool
    ) -> (title: String, accessibilityValue: String, emphasis: Emphasis) {
        if isAggregateOpenAI, let aggregateRoutedAccount {
            let primarySummary = aggregateRoutedAccount.compactPrimaryUsageSummary(mode: usageDisplayMode) ?? ""
            let title = primarySummary.isEmpty
                ? primarySummary
                : L.openAIRouteSummaryCompact(primarySummary)
            return (
                title,
                self.accessibilityUsageSummary(
                    windows: aggregateRoutedAccount.usageWindowDisplays(mode: usageDisplayMode),
                    mode: usageDisplayMode
                ),
                self.quotaEmphasis(for: aggregateRoutedAccount)
            )
        }

        if let activeAccount {
            let windows = activeAccount.usageWindowDisplays(mode: usageDisplayMode)
            if let exhaustedWindow = windows.reversed().first(where: { $0.usedPercent >= 100 }) {
                let title = self.limitTitle(for: exhaustedWindow)
                let isLongWindow = exhaustedWindow.limitWindowSeconds.map { $0 >= 86_400 } ?? false
                return (title, title, isLongWindow ? .critical : .warning)
            }

            return (
                windows.map { "\(Int($0.displayPercent))%" }.joined(separator: "·"),
                self.accessibilityUsageSummary(windows: windows, mode: usageDisplayMode),
                self.quotaEmphasis(for: activeAccount)
            )
        }

        if let activeProvider {
            let label = activeProvider.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortLabel = label.count <= 6 ? label : String(label.prefix(6))
            return (shortLabel, label, .secondary)
        }

        return ("", "", .primary)
    }

    private static func quotaEmphasis(for account: TokenAccount) -> Emphasis {
        if let exhaustedWindow = account.usageWindowDisplays(mode: .used)
            .reversed()
            .first(where: { $0.usedPercent >= 100 }) {
            let isLongWindow = exhaustedWindow.limitWindowSeconds.map { $0 >= 86_400 } ?? false
            return isLongWindow ? .critical : .warning
        }
        return account.isBelowVisualWarningThreshold() ? .warning : .primary
    }

    private static func accessibilityUsageSummary(
        windows: [UsageWindowDisplay],
        mode: CodexBarUsageDisplayMode
    ) -> String {
        windows
            .map { "\($0.label) \(mode.badgeTitle) \(Int($0.displayPercent))%" }
            .joined(separator: " · ")
    }

    private static func limitTitle(for window: UsageWindowDisplay) -> String {
        switch window.limitWindowSeconds {
        case 5 * 3_600:
            return L.hourLimit
        case 7 * 86_400:
            return L.weeklyLimit
        default:
            return L.quotaWindowLimit(window.label)
        }
    }

    private static func icon(
        resolvedSystemSymbol: String,
        displayAccount: TokenAccount?,
        activeProvider: CodexBarProvider?,
        usageDisplayMode: CodexBarUsageDisplayMode,
        showsPrimaryPercent: Bool
    ) -> Icon {
        let isOpenAIUsageProvider = activeProvider == nil || activeProvider?.kind == .openAIOAuth
        guard resolvedSystemSymbol == "terminal.fill",
              isOpenAIUsageProvider,
              let displayAccount else {
            return .systemSymbol(resolvedSystemSymbol)
        }

        let windows = displayAccount.usageWindowDisplays(mode: usageDisplayMode)
        guard windows.isEmpty == false else {
            return .systemSymbol(resolvedSystemSymbol)
        }

        return .usageBars(
            MenuBarUsageIconSpec(
                displayPercents: windows.map(\.displayPercent),
                showsPrimaryPercent: showsPrimaryPercent
            )
        )
    }
}
