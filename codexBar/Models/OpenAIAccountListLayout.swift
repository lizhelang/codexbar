import Foundation

enum OpenAIAccountSortBucket: Int {
    case usable
    case unavailableNonExhausted
    case exhausted
}

private enum OpenAIAccountDisplayPriority: Int {
    case prioritized
    case standard
}

struct OpenAIAccountGroup: Identifiable {
    let id: String
    let email: String
    let displayTitle: String
    let accounts: [TokenAccount]

    nonisolated init(
        id: String? = nil,
        email: String,
        displayTitle: String? = nil,
        accounts: [TokenAccount]
    ) {
        self.email = email
        self.displayTitle = displayTitle
            ?? accounts.first?.displayIdentifier
            ?? TokenAccount.normalizedProfileString(self.email)
            ?? self.email
        self.id = id ?? "\(self.email)\u{1F}\(self.displayTitle)"
        self.accounts = accounts
    }
}

extension OpenAIAccountGroup {
    nonisolated var representativeAccount: TokenAccount? {
        accounts.first
    }

    nonisolated func headerQuotaRemark(now: Date = Date()) -> String? {
        let nearestResetAt = TokenAccount.nearestResetDate(
            in: self.accounts.compactMap { $0.availabilityResetAt(now: now) },
            now: now
        )

        guard let nearestResetAt else { return nil }
        return TokenAccount.compactResetRemaining(until: nearestResetAt, now: now)
    }
}

enum OpenAIAccountListLayout {
    static let visibleGroupLimit = 4

    nonisolated static func groupedAccounts(
        from accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings = .init(),
        preferredAccountOrder: [String] = [],
        highlightActiveAccount: Bool = true
    ) -> [OpenAIAccountGroup] {
        self.groupedAccounts(
            from: accounts,
            prioritizedAccountIDs: [],
            quotaSortSettings: quotaSortSettings,
            preferredAccountOrder: preferredAccountOrder,
            highlightActiveAccount: highlightActiveAccount
        )
    }

    nonisolated static func groupedAccounts(
        from accounts: [TokenAccount],
        attribution: OpenAILiveSessionAttribution,
        now: Date = Date(),
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings = .init(),
        preferredAccountOrder: [String] = [],
        highlightActiveAccount: Bool = true
    ) -> [OpenAIAccountGroup] {
        self.groupedAccounts(
            from: accounts,
            prioritizedAccountIDs: Set(attribution.liveSummary(now: now).inUseSessionCounts.keys),
            quotaSortSettings: quotaSortSettings,
            preferredAccountOrder: preferredAccountOrder,
            highlightActiveAccount: highlightActiveAccount
        )
    }

    nonisolated static func groupedAccounts(
        from accounts: [TokenAccount],
        attribution: OpenAIRunningThreadAttribution,
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings = .init(),
        preferredAccountOrder: [String] = [],
        highlightActiveAccount: Bool = true
    ) -> [OpenAIAccountGroup] {
        self.groupedAccounts(
            from: accounts,
            prioritizedAccountIDs: Set(attribution.summary.runningThreadCounts.keys),
            quotaSortSettings: quotaSortSettings,
            preferredAccountOrder: preferredAccountOrder,
            highlightActiveAccount: highlightActiveAccount
        )
    }

    nonisolated static func groupedAccounts(
        from accounts: [TokenAccount],
        summary: OpenAIRunningThreadAttribution.Summary,
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings = .init(),
        preferredAccountOrder: [String] = [],
        highlightActiveAccount: Bool = true
    ) -> [OpenAIAccountGroup] {
        self.groupedAccounts(
            from: accounts,
            prioritizedAccountIDs: Set(summary.runningThreadCounts.keys),
            quotaSortSettings: quotaSortSettings,
            preferredAccountOrder: preferredAccountOrder,
            highlightActiveAccount: highlightActiveAccount
        )
    }

    nonisolated private static func groupedAccounts(
        from accounts: [TokenAccount],
        prioritizedAccountIDs: Set<String>,
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        preferredAccountOrder: [String],
        highlightActiveAccount: Bool
    ) -> [OpenAIAccountGroup] {
        let preferredRanks = self.preferredAccountRanks(from: preferredAccountOrder)
        return Dictionary(grouping: accounts, by: self.groupKey(for:))
            .map { key, groupedAccounts in
                let representative = groupedAccounts[0]
                return OpenAIAccountGroup(
                    id: key,
                    email: representative.email,
                    displayTitle: representative.displayIdentifier,
                    accounts: groupedAccounts.sorted {
                        self.displayAccountPrecedes(
                            $0,
                            $1,
                            prioritizedAccountIDs: prioritizedAccountIDs,
                            quotaSortSettings: quotaSortSettings,
                            preferredRanks: preferredRanks,
                            highlightActiveAccount: highlightActiveAccount
                        )
                    }
                )
            }
            .sorted {
                self.displayGroupPrecedes(
                    $0,
                    $1,
                    prioritizedAccountIDs: prioritizedAccountIDs,
                    quotaSortSettings: quotaSortSettings,
                    preferredRanks: preferredRanks,
                    highlightActiveAccount: highlightActiveAccount
                )
            }
    }

    nonisolated static func visibleGroups(
        from groups: [OpenAIAccountGroup],
        maxAccounts: Int
    ) -> [OpenAIAccountGroup] {
        guard maxAccounts > 0 else { return [] }

        var remaining = maxAccounts
        var visible: [OpenAIAccountGroup] = []

        for group in groups where remaining > 0 {
            let accounts = Array(group.accounts.prefix(remaining))
            guard accounts.isEmpty == false else { continue }
            visible.append(
                OpenAIAccountGroup(
                    id: group.id,
                    email: group.email,
                    displayTitle: group.displayTitle,
                    accounts: accounts
                )
            )
            remaining -= accounts.count
        }

        return visible
    }

    nonisolated static func accountPrecedes(
        _ lhs: TokenAccount,
        _ rhs: TokenAccount,
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings = .init()
    ) -> Bool {
        let now = Date()

        if lhs.sortBucket != rhs.sortBucket {
            return lhs.sortBucket.rawValue < rhs.sortBucket.rawValue
        }

        if lhs.sortBucket == .exhausted,
           let earlierResetPrecedes = self.earlierResetPrecedes(lhs, rhs, now: now) {
            return earlierResetPrecedes
        }

        let lhsWeightedPrimary = lhs.weightedPrimaryRemainingPercent(now: now, using: quotaSortSettings)
        let rhsWeightedPrimary = rhs.weightedPrimaryRemainingPercent(now: now, using: quotaSortSettings)
        if lhsWeightedPrimary != rhsWeightedPrimary {
            return lhsWeightedPrimary > rhsWeightedPrimary
        }

        let lhsWeightedSecondary = lhs.weightedSecondaryRemainingPercent(now: now, using: quotaSortSettings)
        let rhsWeightedSecondary = rhs.weightedSecondaryRemainingPercent(now: now, using: quotaSortSettings)
        if lhsWeightedSecondary != rhsWeightedSecondary {
            return lhsWeightedSecondary > rhsWeightedSecondary
        }

        if let earlierResetPrecedes = self.earlierResetPrecedes(lhs, rhs, now: now) {
            return earlierResetPrecedes
        }

        let lhsPlanMultiplier = lhs.planQuotaMultiplier(using: quotaSortSettings)
        let rhsPlanMultiplier = rhs.planQuotaMultiplier(using: quotaSortSettings)
        if lhsPlanMultiplier != rhsPlanMultiplier {
            return lhsPlanMultiplier > rhsPlanMultiplier
        }

        let lhsPrimaryRemaining = lhs.primaryRemainingPercent(now: now)
        let rhsPrimaryRemaining = rhs.primaryRemainingPercent(now: now)
        if lhsPrimaryRemaining != rhsPrimaryRemaining {
            return lhsPrimaryRemaining > rhsPrimaryRemaining
        }

        let lhsSecondaryRemaining = lhs.secondaryRemainingPercent(now: now)
        let rhsSecondaryRemaining = rhs.secondaryRemainingPercent(now: now)
        if lhsSecondaryRemaining != rhsSecondaryRemaining {
            return lhsSecondaryRemaining > rhsSecondaryRemaining
        }

        let lhsLabel = lhs.displayIdentifier.localizedLowercase
        let rhsLabel = rhs.displayIdentifier.localizedLowercase
        if lhsLabel != rhsLabel {
            return lhsLabel < rhsLabel
        }

        return lhs.accountId < rhs.accountId
    }

    nonisolated private static func earlierResetPrecedes(
        _ lhs: TokenAccount,
        _ rhs: TokenAccount,
        now: Date
    ) -> Bool? {
        guard let lhsResetAt = lhs.availabilityResetAt(now: now),
              let rhsResetAt = rhs.availabilityResetAt(now: now),
              lhsResetAt != rhsResetAt else {
            return nil
        }

        return lhsResetAt < rhsResetAt
    }

    nonisolated private static func displayAccountPrecedes(
        _ lhs: TokenAccount,
        _ rhs: TokenAccount,
        prioritizedAccountIDs: Set<String>,
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        preferredRanks: [String: Int],
        highlightActiveAccount: Bool
    ) -> Bool {
        let lhsPriority = self.displayPriority(
            for: lhs,
            prioritizedAccountIDs: prioritizedAccountIDs,
            highlightActiveAccount: highlightActiveAccount
        )
        let rhsPriority = self.displayPriority(
            for: rhs,
            prioritizedAccountIDs: prioritizedAccountIDs,
            highlightActiveAccount: highlightActiveAccount
        )
        if lhsPriority != rhsPriority {
            return lhsPriority.rawValue < rhsPriority.rawValue
        }

        if let preferredOrderResult = self.preferredOrderPrecedes(
            lhs,
            rhs,
            preferredRanks: preferredRanks
        ) {
            return preferredOrderResult
        }

        return self.accountPrecedes(
            lhs,
            rhs,
            quotaSortSettings: quotaSortSettings
        )
    }

    nonisolated private static func displayPriority(
        for account: TokenAccount,
        prioritizedAccountIDs: Set<String>,
        highlightActiveAccount: Bool
    ) -> OpenAIAccountDisplayPriority {
        if (highlightActiveAccount && account.isActive) || prioritizedAccountIDs.contains(account.accountId) {
            return .prioritized
        }
        return .standard
    }

    nonisolated private static func displayGroupPrecedes(
        _ lhs: OpenAIAccountGroup,
        _ rhs: OpenAIAccountGroup,
        prioritizedAccountIDs: Set<String>,
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        preferredRanks: [String: Int],
        highlightActiveAccount: Bool
    ) -> Bool {
        let lhsRepresentative = lhs.accounts.first
        let rhsRepresentative = rhs.accounts.first

        switch (lhsRepresentative, rhsRepresentative) {
        case let (lhsAccount?, rhsAccount?):
            if self.displayAccountPrecedes(
                lhsAccount,
                rhsAccount,
                prioritizedAccountIDs: prioritizedAccountIDs,
                quotaSortSettings: quotaSortSettings,
                preferredRanks: preferredRanks,
                highlightActiveAccount: highlightActiveAccount
            ) {
                return true
            }
            if self.displayAccountPrecedes(
                rhsAccount,
                lhsAccount,
                prioritizedAccountIDs: prioritizedAccountIDs,
                quotaSortSettings: quotaSortSettings,
                preferredRanks: preferredRanks,
                highlightActiveAccount: highlightActiveAccount
            ) {
                return false
            }
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            break
        }

        return lhs.email.localizedLowercase < rhs.email.localizedLowercase
    }

    nonisolated private static func preferredAccountRanks(from preferredAccountOrder: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: preferredAccountOrder.enumerated().map { ($0.element, $0.offset) })
    }

    nonisolated private static func groupKey(for account: TokenAccount) -> String {
        let stableIdentity = TokenAccount.normalizedProfileString(account.email)?.localizedLowercase
            ?? account.accountId
        return "\(stableIdentity)\u{1F}\(account.displayIdentifier.localizedLowercase)"
    }

    nonisolated private static func preferredOrderPrecedes(
        _ lhs: TokenAccount,
        _ rhs: TokenAccount,
        preferredRanks: [String: Int]
    ) -> Bool? {
        // Approved base-order semantics:
        // 1. Compare only inside the same display band; active/running still float above.
        // 2. Manually listed accounts outrank unlisted accounts.
        // 3. Unlisted accounts fall back to the existing quota comparator.
        let lhsRank = preferredRanks[lhs.accountId]
        let rhsRank = preferredRanks[rhs.accountId]

        switch (lhsRank, rhsRank) {
        case let (lhsRank?, rhsRank?) where lhsRank != rhsRank:
            return lhsRank < rhsRank
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return nil
        }
    }
}
