import Foundation

struct TokenAccount: Codable, Identifiable {
    var id: String { accountId }
    var email: String
    var accountId: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date?
    var planType: String
    var primaryUsedPercent: Double   // 5h 窗口已使用%
    var secondaryUsedPercent: Double // 周窗口已使用%
    var primaryResetAt: Date?        // 5h 窗口重置绝对时间
    var secondaryResetAt: Date?      // 周窗口重置绝对时间
    var lastChecked: Date?
    var isActive: Bool
    var isSuspended: Bool       // 403 = 账号被封禁/停用
    var tokenExpired: Bool       // 401 = token 过期，需重新授权
    var organizationName: String?

    enum CodingKeys: String, CodingKey {
        case email
        case accountId = "account_id"
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
        case lastChecked = "last_checked"
        case isActive = "is_active"
        case isSuspended = "is_suspended"
        case tokenExpired = "token_expired"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        accountId = try c.decode(String.self, forKey: .accountId)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        idToken = try c.decode(String.self, forKey: .idToken)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        planType = try c.decodeIfPresent(String.self, forKey: .planType) ?? "free"
        primaryUsedPercent = try c.decodeIfPresent(Double.self, forKey: .primaryUsedPercent) ?? 0
        secondaryUsedPercent = try c.decodeIfPresent(Double.self, forKey: .secondaryUsedPercent) ?? 0
        primaryResetAt = try c.decodeIfPresent(Date.self, forKey: .primaryResetAt)
        secondaryResetAt = try c.decodeIfPresent(Date.self, forKey: .secondaryResetAt)
        lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        isSuspended = try c.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false
        tokenExpired = try c.decodeIfPresent(Bool.self, forKey: .tokenExpired) ?? false
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName)
    }

    init(email: String = "", accountId: String = "", accessToken: String = "",
         refreshToken: String = "", idToken: String = "", expiresAt: Date? = nil,
         planType: String = "free", primaryUsedPercent: Double = 0,
         secondaryUsedPercent: Double = 0,
         primaryResetAt: Date? = nil, secondaryResetAt: Date? = nil,
         lastChecked: Date? = nil, isActive: Bool = false, isSuspended: Bool = false, tokenExpired: Bool = false,
         organizationName: String? = nil) {
        self.email = email
        self.accountId = accountId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.planType = planType
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.lastChecked = lastChecked
        self.isActive = isActive
        self.isSuspended = isSuspended
        self.tokenExpired = tokenExpired
        self.organizationName = organizationName
    }

    // MARK: - Computed

    nonisolated var isBanned: Bool { isSuspended }
    nonisolated var primaryExhausted: Bool { primaryUsedPercent >= 100 }
    nonisolated var secondaryExhausted: Bool { secondaryUsedPercent >= 100 }
    nonisolated var quotaExhausted: Bool { primaryExhausted || secondaryExhausted }

    nonisolated var usageStatus: UsageStatus {
        if isBanned { return .banned }
        if quotaExhausted { return .exceeded }
        if primaryUsedPercent >= 80 || secondaryUsedPercent >= 80 { return .warning }
        return .ok
    }

    /// 5h 窗口重置倒计时文字
    var primaryResetDescription: String {
        resetLabel(from: primaryResetAt)
    }

    /// 周窗口重置倒计时文字
    var secondaryResetDescription: String {
        resetLabel(from: secondaryResetAt)
    }

    private func resetLabel(from date: Date?) -> String {
        guard let date = date else { return "" }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return L.resetSoon }
        let seconds = Int(remaining)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return L.resetInDay(days, hours) }
        if hours > 0 { return L.resetInHr(hours, minutes) }
        return L.resetInMin(minutes)
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

enum UsageStatus {
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
    nonisolated var primaryRemainingPercent: Double {
        max(0, 100 - primaryUsedPercent)
    }

    nonisolated var secondaryRemainingPercent: Double {
        max(0, 100 - secondaryUsedPercent)
    }

    nonisolated var sortBucket: OpenAIAccountSortBucket {
        if quotaExhausted { return .exhausted }
        if tokenExpired || isBanned { return .unavailableNonExhausted }
        return .usable
    }
}

struct TokenPool: Codable {
    var accounts: [TokenAccount]

    init(accounts: [TokenAccount] = []) {
        self.accounts = accounts
    }
}
