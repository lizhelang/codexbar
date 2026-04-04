import Foundation

enum MenuBarIconResolver {
    static func iconName(accounts: [TokenAccount], activeProviderKind: CodexBarProviderKind?) -> String {
        if let active = accounts.first(where: { $0.isActive }) {
            return self.iconName(for: [active], fallbackProviderKind: activeProviderKind)
        }

        if activeProviderKind == .openAICompatible {
            return "network"
        }

        return self.iconName(for: accounts, fallbackProviderKind: activeProviderKind)
    }

    private static func iconName(
        for accounts: [TokenAccount],
        fallbackProviderKind: CodexBarProviderKind?
    ) -> String {
        if accounts.contains(where: { $0.isBanned }) {
            return "xmark.circle.fill"
        }
        if accounts.contains(where: { $0.secondaryExhausted }) {
            return "exclamationmark.triangle.fill"
        }
        if accounts.contains(where: { $0.quotaExhausted || $0.primaryUsedPercent >= 80 || $0.secondaryUsedPercent >= 80 }) {
            return "bolt.circle.fill"
        }
        if fallbackProviderKind == .openAICompatible {
            return "network"
        }
        return "terminal.fill"
    }
}
