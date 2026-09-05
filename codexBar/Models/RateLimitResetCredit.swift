import Foundation

struct RateLimitResetCredit: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var status: String
    var grantedAt: Date?
    var expiresAt: Date?

    nonisolated var isAvailable: Bool {
        self.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "available"
    }

    nonisolated func isAvailable(now: Date) -> Bool {
        guard self.isAvailable else { return false }
        guard let expiresAt else { return true }
        return expiresAt > now
    }
}

struct RateLimitResetCreditsSnapshot: Equatable {
    var availableCount: Int
    var credits: [RateLimitResetCredit]

    var availableCredits: [RateLimitResetCredit] {
        self.availableCredits(now: Date())
    }

    nonisolated func availableCredits(now: Date) -> [RateLimitResetCredit] {
        self.credits.filter { $0.isAvailable(now: now) }
    }
}

struct RateLimitResetConsumeResult: Equatable {
    enum Code: String, Equatable {
        case reset
        case nothingToReset = "nothing_to_reset"
        case noCredit = "no_credit"
        case alreadyRedeemed = "already_redeemed"
        case unknown
    }

    let code: Code
    let windowsReset: Int?
}

enum RateLimitResetCreditBadge: Equatable {
    case none
    case approaching
    case urgent
}

struct RateLimitResetCreditItem: Equatable, Identifiable {
    var id: String { "\(self.accountId)|\(self.creditId)" }
    let accountId: String
    let accountLabel: String
    let creditId: String
    let title: String
    let expiresAt: Date
    let primaryUsedPercent: Double
    let secondaryUsedPercent: Double

    var remaining: TimeInterval {
        self.remaining(now: Date())
    }

    func remaining(now: Date) -> TimeInterval {
        self.expiresAt.timeIntervalSince(now)
    }

    nonisolated func hasMostlyUnusedWindows(
        threshold: Double = RateLimitResetCreditPolicy.emptyWindowUsedPercentThreshold
    ) -> Bool {
        self.primaryUsedPercent < threshold && self.secondaryUsedPercent < threshold
    }
}

enum RateLimitResetCreditPolicy {
    nonisolated static let badgeHorizon: TimeInterval = 72 * 3_600
    nonisolated static let notificationHorizon: TimeInterval = 24 * 3_600
    nonisolated static let emptyWindowUsedPercentThreshold = 5.0

    nonisolated static func parseISO8601Date(_ value: Any?) -> Date? {
        if let timestamp = value as? TimeInterval {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let timestamp = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        if let timestamp = value as? Double {
            return Date(timeIntervalSince1970: timestamp)
        }
        guard let raw = value as? String else { return nil }
        return ISO8601Parsing.parse(raw)
    }

    nonisolated static func parseAvailableCount(_ json: [String: Any]) -> Int {
        let container = json["rate_limit_reset_credits"] as? [String: Any] ?? json
        if let count = container["available_count"] as? Int {
            return max(0, count)
        }
        if let count = container["available_count"] as? Double {
            return max(0, Int(count))
        }
        return 0
    }

    nonisolated static func parseCreditsSnapshot(_ json: [String: Any]) -> RateLimitResetCreditsSnapshot {
        let rawCredits = json["credits"] as? [[String: Any]] ?? []
        let credits = rawCredits.compactMap { self.parseCredit($0) }
        let listedAvailable = credits.filter(\.isAvailable).count
        let availableCount = max(self.parseAvailableCount(json), listedAvailable)
        return RateLimitResetCreditsSnapshot(availableCount: availableCount, credits: credits)
    }

    nonisolated static func parseConsumeResult(_ json: [String: Any]) -> RateLimitResetConsumeResult {
        let rawCode = (json["code"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let code = RateLimitResetConsumeResult.Code(rawValue: rawCode) ?? .unknown
        let windowsReset: Int?
        if let value = json["windows_reset"] as? Int {
            windowsReset = value
        } else if let value = json["windows_reset"] as? Double {
            windowsReset = Int(value)
        } else {
            windowsReset = nil
        }
        return RateLimitResetConsumeResult(code: code, windowsReset: windowsReset)
    }

    nonisolated static func notificationKey(creditId: String, expiresAt: Date) -> String {
        "\(creditId)|\(Int(expiresAt.timeIntervalSince1970))"
    }

    nonisolated private static func parseCredit(_ json: [String: Any]) -> RateLimitResetCredit? {
        let id = (json["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard id.isEmpty == false else { return nil }

        let title = (json["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = (json["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "available"

        return RateLimitResetCredit(
            id: id,
            title: (title?.isEmpty == false ? title : nil) ?? "Full reset",
            status: status.isEmpty ? "available" : status,
            grantedAt: self.parseISO8601Date(json["granted_at"]),
            expiresAt: self.parseISO8601Date(json["expires_at"])
        )
    }
}

enum RateLimitResetCreditPresentation {
    static let collapsedVisibleCount = 1

    static func items(
        from accounts: [TokenAccount],
        now: Date = Date()
    ) -> [RateLimitResetCreditItem] {
        accounts.flatMap { account in
            account.availableRateLimitResetCredits(now: now).compactMap { credit in
                guard let expiresAt = credit.expiresAt else { return nil }
                return RateLimitResetCreditItem(
                    accountId: account.accountId,
                    accountLabel: account.displayIdentifier,
                    creditId: credit.id,
                    title: credit.title,
                    expiresAt: expiresAt,
                    primaryUsedPercent: account.primaryUsedPercent,
                    secondaryUsedPercent: account.secondaryUsedPercent
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.expiresAt != rhs.expiresAt {
                return lhs.expiresAt < rhs.expiresAt
            }
            return lhs.accountLabel.localizedCaseInsensitiveCompare(rhs.accountLabel) == .orderedAscending
        }
    }

    static func soonest(
        from accounts: [TokenAccount],
        now: Date = Date()
    ) -> RateLimitResetCreditItem? {
        self.items(from: accounts, now: now).first
    }

    static func collapsedItems(_ items: [RateLimitResetCreditItem]) -> [RateLimitResetCreditItem] {
        Array(items.prefix(self.collapsedVisibleCount))
    }

    static func canExpand(_ items: [RateLimitResetCreditItem]) -> Bool {
        items.count > self.collapsedVisibleCount
    }

    static func badge(
        from accounts: [TokenAccount],
        now: Date = Date()
    ) -> RateLimitResetCreditBadge {
        guard let remaining = self.soonest(from: accounts, now: now)?.remaining(now: now),
              remaining > 0 else {
            return .none
        }
        if remaining <= RateLimitResetCreditPolicy.notificationHorizon {
            return .urgent
        }
        if remaining <= RateLimitResetCreditPolicy.badgeHorizon {
            return .approaching
        }
        return .none
    }

    static func accountRowSummary(
        for account: TokenAccount,
        now: Date = Date()
    ) -> String? {
        let credits = account.availableRateLimitResetCredits(now: now)
        let count = max(account.rateLimitResetAvailableCount, credits.count)
        guard count > 0 else { return nil }

        let earliest = credits.compactMap(\.expiresAt).min()
        if let earliest {
            return L.resetCreditAccountSummary(count, self.relativeExpiry(earliest, now: now))
        }
        return L.resetCreditCount(count)
    }

    static func banner(
        from accounts: [TokenAccount],
        now: Date = Date()
    ) -> OpenAIStatusBannerPresentation? {
        let badge = self.badge(from: accounts, now: now)
        guard badge != .none, let soonest = self.soonest(from: accounts, now: now) else {
            return nil
        }

        let remainingText = self.relativeExpiry(soonest.expiresAt, now: now)
        return OpenAIStatusBannerPresentation(
            title: badge == .urgent ? L.resetCreditUrgentTitle : L.resetCreditApproachingTitle,
            message: L.resetCreditBannerDetail(soonest.accountLabel, remainingText),
            actionTitle: L.resetCreditUseSoonest,
            tone: .warning
        )
    }

    static func relativeExpiry(_ date: Date, now: Date = Date()) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return L.resetCreditExpired }
        let seconds = Int(remaining)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return L.resetCreditInDay(days, hours) }
        if hours > 0 { return L.resetCreditInHr(hours, minutes) }
        if minutes > 0 { return L.resetCreditInMin(minutes) }
        return L.resetCreditExpiresSoon
    }

    static func pendingNotificationKeys(
        from accounts: [TokenAccount],
        now: Date = Date(),
        alreadyNotified: Set<String>
    ) -> [RateLimitResetCreditItem] {
        self.items(from: accounts, now: now).filter { item in
            let remaining = item.remaining(now: now)
            guard remaining > 0, remaining <= RateLimitResetCreditPolicy.notificationHorizon else {
                return false
            }
            let key = RateLimitResetCreditPolicy.notificationKey(
                creditId: item.creditId,
                expiresAt: item.expiresAt
            )
            return alreadyNotified.contains(key) == false
        }
    }
}
