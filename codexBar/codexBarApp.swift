import SwiftUI

@main
struct codexBarApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleObserver.self) private var lifecycleObserver
    @StateObject private var store = TokenStore.shared
    @StateObject private var oauth = OAuthManager.shared
    @StateObject private var updateCoordinator = UpdateCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(oauth)
                .environmentObject(updateCoordinator)
        } label: {
            MenuBarIconView(store: store, updateCoordinator: updateCoordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏图标：显示 terminal 图标 + 活跃账号的 5h / 周额度
struct MenuBarIconView: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var updateCoordinator: UpdateCoordinator

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
            if self.store.activeProvider?.kind == .openAIOAuth,
               self.store.config.openAI.accountUsageMode == .aggregateGateway {
                Text(L.accountUsageModeAggregateShort)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            } else if let active = store.accounts.first(where: { $0.isActive }) {
                if active.secondaryExhausted {
                    Text(L.weeklyLimit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                } else if active.primaryExhausted {
                    Text(L.hourLimit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                } else {
                    Text(self.usageSummaryText(for: active))
                        .font(.system(size: 10, weight: .medium))
                }
            } else if let provider = store.activeProvider {
                Text(shortProviderLabel(provider))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var iconName: String {
        MenuBarIconResolver.iconName(
            accounts: store.accounts,
            activeProviderKind: store.activeProvider?.kind,
            updateAvailable: self.updateCoordinator.pendingAvailability != nil
        )
    }

    private func shortProviderLabel(_ provider: CodexBarProvider) -> String {
        let label = provider.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.count <= 6 { return label }
        return String(label.prefix(6))
    }

    private func usageSummaryText(for account: TokenAccount) -> String {
        account.usageWindowDisplays(mode: self.store.config.openAI.usageDisplayMode)
            .map { "\(Int($0.displayPercent))%" }
            .joined(separator: "·")
    }
}
