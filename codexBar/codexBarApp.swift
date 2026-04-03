import SwiftUI

@main
struct codexBarApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleObserver.self) private var lifecycleObserver
    @StateObject private var store = TokenStore.shared
    @StateObject private var oauth = OAuthManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(oauth)
        } label: {
            MenuBarIconView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏图标：显示 terminal 图标 + 活跃账号的 5h / 周额度
struct MenuBarIconView: View {
    @ObservedObject var store: TokenStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
            if let active = store.accounts.first(where: { $0.isActive }) {
                if active.secondaryExhausted {
                    Text(L.weeklyLimit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                } else if active.primaryExhausted {
                    Text(L.hourLimit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                } else {
                    Text("\(Int(active.primaryUsedPercent))%·\(Int(active.secondaryUsedPercent))%")
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
        // 优先以活跃账号状态决定图标；无活跃账号才看全部
        let ref: [TokenAccount]
        if let active = store.accounts.first(where: { $0.isActive }) {
            ref = [active]
        } else {
            ref = store.accounts
        }
        if ref.contains(where: { $0.isBanned }) {
            return "xmark.circle.fill"
        }
        if ref.contains(where: { $0.secondaryExhausted }) {
            return "exclamationmark.triangle.fill"
        }
        if ref.contains(where: { $0.quotaExhausted || $0.primaryUsedPercent >= 80 || $0.secondaryUsedPercent >= 80 }) {
            return "bolt.circle.fill"
        }
        if store.activeProvider?.kind == .openAICompatible {
            return "network"
        }
        return "terminal.fill"
    }

    private func shortProviderLabel(_ provider: CodexBarProvider) -> String {
        let label = provider.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.count <= 6 { return label }
        return String(label.prefix(6))
    }
}
