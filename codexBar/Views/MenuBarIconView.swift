import SwiftUI

/// 菜单栏图标：显示 terminal 图标 + 活跃账号的 5h / 周额度
struct MenuBarIconView: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var updateCoordinator: UpdateCoordinator

    var body: some View {
        let presentation = MenuBarStatusItemPresentation.make(
            accounts: self.store.accounts,
            activeProvider: self.store.activeProvider,
            aggregateRoutedAccount: self.store.aggregateRoutedAccount,
            usageDisplayMode: self.store.config.openAI.usageDisplayMode,
            accountUsageMode: self.store.config.openAI.accountUsageMode,
            updateAvailable: self.updateCoordinator.pendingAvailability != nil
        )

        HStack(spacing: 3) {
            Image(systemName: presentation.iconName)
                .symbolRenderingMode(.hierarchical)
            if presentation.title.isEmpty == false {
                Text(presentation.title)
                    .font(.system(size: 10, weight: self.fontWeight(for: presentation.emphasis)))
                    .foregroundColor(self.foregroundColor(for: presentation.emphasis))
            }
        }
    }

    private func fontWeight(for emphasis: MenuBarStatusItemPresentation.Emphasis) -> Font.Weight {
        switch emphasis {
        case .primary, .secondary:
            return .medium
        case .warning, .critical:
            return .semibold
        }
    }

    private func foregroundColor(for emphasis: MenuBarStatusItemPresentation.Emphasis) -> Color {
        switch emphasis {
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}
