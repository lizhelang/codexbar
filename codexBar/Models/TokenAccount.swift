import Foundation

enum OpenAIVisualWarningThreshold {
    static let remainingPercent = 20.0
}

struct TokenAccount: Codable, Identifiable {
    private static let degradedRoutingThresholdPercent = 80.0
    private static let exhaustedRoutingThresholdPercent = 100.0
    var id: String { accountId }
    var email: String
    var accountId: String
    var openAIAccountId: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date?
    var planType: String
    var primaryUsedPercent: Double
    var secondaryUsedPercent: Double
    var primaryResetAt: Date?
    var secondaryResetAt: Date?
    var primaryLimitWindowSeconds: Int?
    var secondaryLimitWindowSeconds: Int?
    var lastChecked: Date?
    var isActive: Bool
    var isSuspended: Bool       // 403 = 账号被封禁/停用
    var tokenExpired: Bool       // 401 = token 过期，需重新授权
    var organizationName: String?

    enum CodingKeys: String, CodingKey {
        case email
        case accountId = "account_id"
        case openAIAccountId = "openai_account_id"
        case organizationName = "organization_name"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresAt = "expires_at"
        case planType = "plan_type"
        case primaryUsedPercent = "primary_used_percent"
        case secondaryUsedPercent = "secondary_used_percent"
        case primaryResetAt = "primary_reset_at"
        case secondaryResetAt = "secondary_reset_at"
        case primaryLimitWindowSeconds = "primary_limit_window_seconds"
        case secondaryLimitWindowSeconds = "secondary_limit_window_seconds"
        case lastChecked = "last_checked"
        case isActive = "is_active"
        case isSuspended = "is_suspended"
        case tokenExpired = "token_expired"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        accountId = try c.decode(String.self, forKey: .accountId)
        openAIAccountId = try c.decodeIfPresent(String.self, forKey: .openAIAccountId) ?? accountId
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        idToken = try c.decode(String.self, forKey: .idToken)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        planType = try c.decodeIfPresent(String.self, forKey: .planType) ?? "free"
        primaryUsedPercent = try c.decodeIfPresent(Double.self, forKey: .primaryUsedPercent) ?? 0
        secondaryUsedPercent = try c.decodeIfPresent(Double.self, forKey: .secondaryUsedPercent) ?? 0
        primaryResetAt = try c.decodeIfPresent(Date.self, forKey: .primaryResetAt)
        secondaryResetAt = try c.decodeIfPresent(Date.self, forKey: .secondaryResetAt)
        primaryLimitWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .primaryLimitWindowSeconds)
        secondaryLimitWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .secondaryLimitWindowSeconds)
        lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        isSuspended = try c.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false
        tokenExpired = try c.decodeIfPresent(Bool.self, forKey: .tokenExpired) ?? false
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName)
    }

    init(email: String = "", accountId: String = "", openAIAccountId: String? = nil, accessToken: String = "",
         refreshToken: String = "", idToken: String = "", expiresAt: Date? = nil,
         planType: String = "free", primaryUsedPercent: Double = 0,
         secondaryUsedPercent: Double = 0,
         primaryResetAt: Date? = nil, secondaryResetAt: Date? = nil,
         primaryLimitWindowSeconds: Int? = nil, secondaryLimitWindowSeconds: Int? = nil,
         lastChecked: Date? = nil, isActive: Bool = false, isSuspended: Bool = false, tokenExpired: Bool = false,
         organizationName: String? = nil) {
        self.email = email
        self.accountId = accountId
        self.openAIAccountId = openAIAccountId ?? accountId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.planType = planType
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.primaryLimitWindowSeconds = primaryLimitWindowSeconds
        self.secondaryLimitWindowSeconds = secondaryLimitWindowSeconds
        self.lastChecked = lastChecked
        self.isActive = isActive
        self.isSuspended = isSuspended
        self.tokenExpired = tokenExpired
        self.organizationName = organizationName
    }

    // MARK: - Computed

    nonisolated var remoteAccountId: String {
        self.openAIAccountId.isEmpty ? self.accountId : self.openAIAccountId
    }

    nonisolated var isBanned: Bool { isSuspended }
    nonisolated var primaryExhausted: Bool { primaryUsedPercent >= Self.exhaustedRoutingThresholdPercent }
    nonisolated var secondaryExhausted: Bool { secondaryUsedPercent >= Self.exhaustedRoutingThresholdPercent }
    nonisolated var quotaExhausted: Bool { primaryExhausted || secondaryExhausted }
    nonisolated var isAvailableForNextUseRouting: Bool { isBanned == false && tokenExpired == false && quotaExhausted == false }
    nonisolated var isDegradedForNextUseRouting: Bool {
        self.isAvailableForNextUseRouting && (
            primaryUsedPercent >= Self.degradedRoutingThresholdPercent ||
            secondaryUsedPercent >= Self.degradedRoutingThresholdPercent
        )
    }

    nonisolated var usageStatus: UsageStatus {
        if isBanned { return .banned }
        if quotaExhausted { return .exceeded }
        if primaryUsedPercent >= Self.degradedRoutingThresholdPercent ||
            secondaryUsedPercent >= Self.degradedRoutingThresholdPercent {
            return .warning
        }
        return .ok
    }

    /// 5h 窗口重置倒计时文字
    var primaryResetDescription: String {
        let now = Date()
        return self.resetLabel(
            from: self.effectiveResetAt(
                self.primaryResetAt,
                limitWindowSeconds: self.resolvedPrimaryLimitWindowSeconds(now: now),
                now: now
            ),
            now: now
        )
    }

    /// 周窗口重置倒计时文字
    var secondaryResetDescription: String {
        let now = Date()
        return self.resetLabel(
            from: self.effectiveResetAt(
                self.secondaryResetAt,
                limitWindowSeconds: self.resolvedSecondaryLimitWindowSeconds(now: now),
                now: now
            ),
            now: now
        )
    }

    private func resetLabel(from date: Date?, now: Date) -> String {
        guard let date = date else { return "" }
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return L.resetSoon }
        let seconds = Int(remaining)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return L.resetInDay(days, hours) }
        if hours > 0 { return L.resetInHr(hours, minutes) }
        return L.resetInMin(minutes)
    }

    nonisolated func normalizedQuotaSnapshot(now: Date = Date()) -> TokenAccount {
        var normalized = self
        let primaryWindowSeconds = self.resolvedPrimaryLimitWindowSeconds(now: now)
        let secondaryWindowSeconds = self.resolvedSecondaryLimitWindowSeconds(now: now)

        if normalized.primaryLimitWindowSeconds == nil {
            normalized.primaryLimitWindowSeconds = primaryWindowSeconds
        }
        if normalized.secondaryLimitWindowSeconds == nil {
            normalized.secondaryLimitWindowSeconds = secondaryWindowSeconds
        }

        normalized.primaryResetAt = Self.clampedResetAt(
            self.primaryResetAt,
            limitWindowSeconds: primaryWindowSeconds,
            lastChecked: self.lastChecked,
            now: now
        )
        normalized.secondaryResetAt = Self.clampedResetAt(
            self.secondaryResetAt,
            limitWindowSeconds: secondaryWindowSeconds,
            lastChecked: self.lastChecked,
            now: now
        )
        return normalized
    }

    nonisolated func usageSnapshotAge(now: Date = Date()) -> TimeInterval? {
        guard let lastChecked else { return nil }
        return max(0, now.timeIntervalSince(lastChecked))
    }

    nonisolated func isUsageSnapshotStale(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let age = self.usageSnapshotAge(now: now) else { return true }
        return age >= maxAge
    }
}

struct UsageWindowDisplay: Identifiable, Equatable {
    let label: String
    let usedPercent: Double
    let displayPercent: Double
    let limitWindowSeconds: Int?

    var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    var id: String { "\(label)-\(limitWindowSeconds ?? -1)" }
}

enum UsageStatus: Equatable {
    case ok, warning, exceeded, banned

    var color: String {
        switch self {
        case .ok: return "green"
        case .warning: return "yellow"
        case .exceeded: return "orange"
        case .banned: return "red"
        }
    }

    var label: String {
        switch self {
        case .ok: return "正常"
        case .warning: return "即将用尽"
        case .exceeded: return "额度耗尽"
        case .banned: return "已停用"
        }
    }
}

extension TokenAccount {
    nonisolated private var normalizedPlanType: String {
        self.planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated func planQuotaMultiplier(
        using quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings
    ) -> Double {
        switch self.normalizedPlanType {
        case "plus":
            return quotaSortSettings.plusRelativeWeight
        case "pro":
            return quotaSortSettings.proAbsoluteWeight
        case "team":
            return quotaSortSettings.teamAbsoluteWeight
        default:
            return 1.0
        }
    }

    nonisolated var planQuotaMultiplier: Double {
        self.planQuotaMultiplier(using: CodexBarOpenAISettings.QuotaSortSettings())
    }

    nonisolated var primaryRemainingPercent: Double {
        self.primaryRemainingPercent(now: Date())
    }

    nonisolated var secondaryRemainingPercent: Double {
        self.secondaryRemainingPercent(now: Date())
    }

    nonisolated func primaryRemainingPercent(now: Date) -> Double {
        guard self.resolvedPrimaryLimitWindowSeconds(now: now) != nil else { return 0 }
        return max(0, 100 - primaryUsedPercent)
    }

    nonisolated func secondaryRemainingPercent(now: Date) -> Double {
        guard self.resolvedSecondaryLimitWindowSeconds(now: now) != nil else { return 0 }
        return max(0, 100 - secondaryUsedPercent)
    }

    nonisolated func weightedPrimaryRemainingPercent(
        using quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings
    ) -> Double {
        self.weightedPrimaryRemainingPercent(now: Date(), using: quotaSortSettings)
    }

    nonisolated var weightedPrimaryRemainingPercent: Double {
        self.weightedPrimaryRemainingPercent(using: CodexBarOpenAISettings.QuotaSortSettings())
    }

    nonisolated func weightedPrimaryRemainingPercent(
        now: Date,
        using quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings
    ) -> Double {
        self.primaryRemainingPercent(now: now) * self.planQuotaMultiplier(using: quotaSortSettings)
    }

    nonisolated func weightedSecondaryRemainingPercent(
        using quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings
    ) -> Double {
        self.weightedSecondaryRemainingPercent(now: Date(), using: quotaSortSettings)
    }

    nonisolated var weightedSecondaryRemainingPercent: Double {
        self.weightedSecondaryRemainingPercent(using: CodexBarOpenAISettings.QuotaSortSettings())
    }

    nonisolated func weightedSecondaryRemainingPercent(
        now: Date,
        using quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings
    ) -> Double {
        self.secondaryRemainingPercent(now: now) * self.planQuotaMultiplier(using: quotaSortSettings)
    }

    nonisolated var sortBucket: OpenAIAccountSortBucket {
        if quotaExhausted { return .exhausted }
        if tokenExpired || isBanned { return .unavailableNonExhausted }
        return .usable
    }

    nonisolated func nearestResetAt(now: Date = Date()) -> Date? {
        Self.nearestResetDate(
            in: self.rateLimitWindows(now: now).compactMap(\.resetAt),
            now: now
        )
    }

    nonisolated func availabilityResetAt(now: Date = Date()) -> Date? {
        let exhaustedResets = self.rateLimitWindows(now: now)
            .filter { $0.usedPercent >= 100 }
            .compactMap(\.resetAt)

        if exhaustedResets.isEmpty == false {
            return exhaustedResets.max()
        }

        return self.nearestResetAt(now: now)
    }

    nonisolated func headerQuotaRemark(now: Date = Date()) -> String? {
        guard let resetAt = self.availabilityResetAt(now: now) else { return nil }
        return Self.compactResetRemaining(until: resetAt, now: now)
    }

    nonisolated static func compactResetRemaining(until date: Date, now: Date) -> String {
        let remainingSeconds = max(0, Int(date.timeIntervalSince(now)))
        let days = remainingSeconds / 86_400
        let hours = (remainingSeconds % 86_400) / 3_600
        let minutes = (remainingSeconds % 3_600) / 60

        if days > 0 {
            return L.compactResetDaysHours(days, hours)
        }

        if hours > 0 {
            return L.compactResetHoursMinutes(hours, minutes)
        }

        if minutes > 0 {
            return L.compactResetMinutes(minutes)
        }

        return L.compactResetSoon
    }

    nonisolated static func clampedResetAt(
        _ rawResetAt: Date?,
        limitWindowSeconds: Int?,
        lastChecked: Date?,
        now: Date
    ) -> Date? {
        guard let rawResetAt else { return nil }
        guard let limitWindowSeconds, limitWindowSeconds > 0 else { return rawResetAt }

        let anchor = lastChecked ?? now
        let maxResetAt = anchor.addingTimeInterval(TimeInterval(limitWindowSeconds))
        return min(rawResetAt, maxResetAt)
    }

    nonisolated static func nearestResetDate(in dates: [Date], now: Date) -> Date? {
        let futureDates = dates.filter { $0.timeIntervalSince(now) > 0 }
        if futureDates.isEmpty == false {
            return futureDates.min()
        }

        return dates.max()
    }

    nonisolated var usageWindowDisplays: [UsageWindowDisplay] {
        self.usageWindowDisplays(mode: .used)
    }

    nonisolated func compactUsageSummary(mode: CodexBarUsageDisplayMode) -> String? {
        let windows = self.usageWindowDisplays(mode: mode)
        guard windows.isEmpty == false else { return nil }
        return windows.map { "\($0.label) \(Int($0.displayPercent))%" }.joined(separator: " · ")
    }

    nonisolated func compactPrimaryUsageSummary(mode: CodexBarUsageDisplayMode) -> String? {
        guard let primaryWindow = self.usageWindowDisplays(mode: mode).first else { return nil }
        return "\(Int(primaryWindow.displayPercent))%"
    }

    nonisolated func usageWindowDisplays(mode: CodexBarUsageDisplayMode) -> [UsageWindowDisplay] {
        self.rateLimitWindows(now: Date()).map {
            UsageWindowDisplay(
                label: self.windowLabel(for: $0.limitWindowSeconds),
                usedPercent: $0.usedPercent,
                displayPercent: mode == .remaining ? max(0, 100 - $0.usedPercent) : $0.usedPercent,
                limitWindowSeconds: $0.limitWindowSeconds
            )
        }
    }

    nonisolated func isBelowVisualWarningThreshold() -> Bool {
        guard self.isBanned == false, self.tokenExpired == false else { return false }
        return self.rateLimitWindows(now: Date()).contains {
            max(0, 100 - $0.usedPercent) <= OpenAIVisualWarningThreshold.remainingPercent
        }
    }

    nonisolated private func rateLimitWindows(now: Date) -> [RateLimitWindowSnapshot] {
        let primaryWindowSeconds = self.resolvedPrimaryLimitWindowSeconds(now: now)
        var windows: [RateLimitWindowSnapshot] = [
            RateLimitWindowSnapshot(
                usedPercent: self.primaryUsedPercent,
                resetAt: self.effectiveResetAt(
                    self.primaryResetAt,
                    limitWindowSeconds: primaryWindowSeconds,
                    now: now
                ),
                limitWindowSeconds: primaryWindowSeconds
            )
        ]

        if let secondaryWindowSeconds = self.resolvedSecondaryLimitWindowSeconds(now: now) {
            windows.append(
                RateLimitWindowSnapshot(
                    usedPercent: self.secondaryUsedPercent,
                    resetAt: self.effectiveResetAt(
                        self.secondaryResetAt,
                        limitWindowSeconds: secondaryWindowSeconds,
                        now: now
                    ),
                    limitWindowSeconds: secondaryWindowSeconds
                )
            )
        }

        return windows
    }

    nonisolated private func effectiveResetAt(
        _ rawResetAt: Date?,
        limitWindowSeconds: Int?,
        now: Date
    ) -> Date? {
        Self.clampedResetAt(
            rawResetAt,
            limitWindowSeconds: limitWindowSeconds,
            lastChecked: self.lastChecked,
            now: now
        )
    }

    nonisolated private func resolvedPrimaryLimitWindowSeconds(now: Date) -> Int? {
        if let primaryLimitWindowSeconds {
            return primaryLimitWindowSeconds
        }

        let normalizedPlanType = self.normalizedPlanType
        if normalizedPlanType == "free",
           let primaryResetAt,
           primaryResetAt.timeIntervalSince(now) > 12 * 3_600 {
            return 7 * 86_400
        }

        return 5 * 3_600
    }

    nonisolated private func resolvedSecondaryLimitWindowSeconds(now: Date) -> Int? {
        if let secondaryLimitWindowSeconds {
            return secondaryLimitWindowSeconds
        }

        if self.secondaryResetAt != nil || self.secondaryUsedPercent > 0 {
            return 7 * 86_400
        }

        let normalizedPlanType = self.normalizedPlanType
        if normalizedPlanType == "plus" ||
            normalizedPlanType == "pro" ||
            normalizedPlanType == "team" {
            return 7 * 86_400
        }

        if normalizedPlanType == "free",
           let primaryResetAt,
           primaryResetAt.timeIntervalSince(now) > 12 * 3_600 {
            return nil
        }

        return nil
    }

    nonisolated private func windowLabel(for seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "?" }
        if seconds % 86_400 == 0 {
            return "\(seconds / 86_400)d"
        }
        if seconds % 3_600 == 0 {
            return "\(seconds / 3_600)h"
        }
        return "\(max(1, seconds / 60))m"
    }
}

private struct RateLimitWindowSnapshot {
    let usedPercent: Double
    let resetAt: Date?
    let limitWindowSeconds: Int?
}

struct TokenPool: Codable {
    var accounts: [TokenAccount]

    init(accounts: [TokenAccount] = []) {
        self.accounts = accounts
    }
}
