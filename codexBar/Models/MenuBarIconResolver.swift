import Foundation

enum MenuBarIconResolver {
    static func iconName(
        accounts: [TokenAccount],
        activeProviderKind: CodexBarProviderKind?,
        updateAvailable: Bool = false
    ) -> String {
        if updateAvailable {
            return "arrow.down.circle.fill"
        }

        if let active = accounts.first(where: { $0.isActive }) {
            return self.iconName(
                for: [active],
                fallbackProviderKind: activeProviderKind
            )
        }

        if activeProviderKind == .openAICompatible || activeProviderKind == .openRouter {
            return "network"
        }

        return self.iconName(
            for: accounts,
            fallbackProviderKind: activeProviderKind
        )
    }

    private static func iconName(
        for accounts: [TokenAccount],
        fallbackProviderKind: CodexBarProviderKind?
    ) -> String {
        if accounts.contains(where: { $0.isBanned }) {
            return "xmark.circle.fill"
        }
        if accounts.contains(where: { account in
            account.usageWindowDisplays(mode: .used).contains { window in
                window.usedPercent >= 100 && (window.limitWindowSeconds ?? 0) >= 86_400
            }
        }) {
            return "exclamationmark.triangle.fill"
        }
        if accounts.contains(where: { $0.quotaExhausted || $0.isBelowVisualWarningThreshold() }) {
            return "bolt.circle.fill"
        }
        if fallbackProviderKind == .openAICompatible || fallbackProviderKind == .openRouter {
            return "network"
        }
        return "terminal.fill"
    }
}
