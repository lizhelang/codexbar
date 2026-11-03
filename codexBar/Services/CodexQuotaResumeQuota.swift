import CoreFoundation
import Foundation

/// 仅供自动续跑使用的服务端快照；不复用展示层将缺失用量补成零的兼容逻辑。
struct CodexQuotaResumeQuota: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case allowed
        case blocked(nextCheckAt: Date)
        case unavailable(reason: String)
    }

    private struct Window: Equatable, Sendable {
        let usedPercent: Double
        let resetAt: Date
        let durationSeconds: Double
    }

    nonisolated static let maximumAge: TimeInterval = 60
    nonisolated static let minimumRetryDelay: TimeInterval = 30

    let accountID: String
    let fetchedAt: Date
    private let allowed: Bool?
    private let limitReached: Bool?
    private let windows: [Window]
    private let additionalModelIDs: Set<String>
    private let failure: String?

    private nonisolated init(
        accountID: String,
        fetchedAt: Date,
        allowed: Bool? = nil,
        limitReached: Bool? = nil,
        windows: [Window] = [],
        additionalModelIDs: Set<String> = [],
        failure: String? = nil
    ) {
        self.accountID = accountID
        self.fetchedAt = fetchedAt
        self.allowed = allowed
        self.limitReached = limitReached
        self.windows = windows
        self.additionalModelIDs = additionalModelIDs
        self.failure = failure
    }

    nonisolated static func parse(
        _ json: [String: Any],
        accountID: String,
        fetchedAt: Date = Date()
    ) -> Self {
        func unavailable(_ reason: String) -> Self {
            Self(accountID: accountID, fetchedAt: fetchedAt, failure: reason)
        }

        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable("未能确认额度所属账号")
        }
        // 请求已通过 chatgpt-account-id 绑定账号；响应若也带身份，必须一致。
        if let responseAccountID = json["account_id"], !(responseAccountID is NSNull) {
            guard let responseAccountID = responseAccountID as? String,
                  responseAccountID == accountID else {
                return unavailable("额度响应与线程账号不一致")
            }
        }
        if let spendControl = json["spend_control_reached"], !(spendControl is NSNull) {
            guard Self.boolean(spendControl) == false else {
                return unavailable("账号支出限制尚未解除或状态未知")
            }
        }
        if let reachedType = json["rate_limit_reached_type"], !(reachedType is NSNull) {
            guard let reachedType = reachedType as? String,
                  reachedType.isEmpty || reachedType == "rate_limit_reached" else {
                return unavailable("账号或工作区的其他额度限制尚未解除")
            }
        }
        guard let rateLimit = json["rate_limit"] as? [String: Any],
              let allowed = Self.boolean(rateLimit["allowed"]),
              let limitReached = Self.boolean(rateLimit["limit_reached"]),
              allowed != limitReached else {
            return unavailable("服务端额度许可状态缺失或相互矛盾")
        }
        if let limitID = rateLimit["limit_id"], !(limitID is NSNull) {
            guard limitID as? String == "codex" else {
                return unavailable("无法确认线程对应的额度类型")
            }
        }

        guard let primary = Self.window(rateLimit["primary_window"]) else {
            return unavailable("主额度窗口缺少可信的用量或重置时间")
        }
        var windows = [primary]
        // explicit null 表示服务端确认不存在第二窗口；字段缺失不是零用量。
        guard let secondary = rateLimit["secondary_window"] else {
            return unavailable("次额度窗口状态缺失")
        }
        if !(secondary is NSNull) {
            guard let window = Self.window(secondary) else {
                return unavailable("次额度窗口缺少可信的用量或重置时间")
            }
            windows.append(window)
        }

        var additionalModelIDs: Set<String> = ["gpt-reserve"]
        if let additional = json["additional_rate_limits"], !(additional is NSNull) {
            guard let limits = additional as? [[String: Any]] else {
                return unavailable("额外额度类型无法识别")
            }
            for limit in limits {
                var names: [String] = []
                for key in ["limit_name", "normal_model_slug", "limit_id"] {
                    guard let raw = limit[key], !(raw is NSNull) else { continue }
                    guard let value = raw as? String,
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return unavailable("额外额度的模型归属格式无法识别")
                    }
                    names.append(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                guard names.contains("gpt-reserve") || limit["normal_model_slug"] is String else {
                    return unavailable("额外额度缺少模型归属")
                }
                additionalModelIDs.formUnion(names)
            }
        }
        // 新版多额度桶响应必须另行实现映射，不能悄悄退回旧的单桶视图。
        if let buckets = json["rate_limits_by_limit_id"], !(buckets is NSNull) {
            return unavailable("此多额度类型响应尚未支持自动续跑")
        }

        return Self(
            accountID: accountID,
            fetchedAt: fetchedAt,
            allowed: allowed,
            limitReached: limitReached,
            windows: windows,
            additionalModelIDs: additionalModelIDs
        )
    }

    nonisolated func decision(
        expectedAccountID: String,
        model: String?,
        now: Date = Date()
    ) -> Decision {
        guard expectedAccountID == self.accountID else {
            return .unavailable(reason: "额度快照不属于原线程账号")
        }
        let age = now.timeIntervalSince(self.fetchedAt)
        guard age.isFinite, age >= -5, age <= Self.maximumAge else {
            return .unavailable(reason: "额度快照已过期，需要重新查询")
        }
        if let failure = self.failure { return .unavailable(reason: failure) }
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !model.isEmpty else {
            return .unavailable(reason: "未能确认原线程模型")
        }
        guard !self.additionalModelIDs.contains(model) else {
            return .unavailable(reason: "此模型使用独立额度，尚未支持自动续跑")
        }

        let exhausted = self.windows.filter { $0.usedPercent >= 100 }
        if self.allowed == true, self.limitReached == false, exhausted.isEmpty {
            // 非空且完整的窗口和服务端明确许可必须同时成立。
            return .allowed
        }
        guard self.allowed == false, self.limitReached == true,
              let resetAt = exhausted.map(\.resetAt).max() else {
            return .unavailable(reason: "额度许可与窗口用量不一致，需要重新查询")
        }
        // 五小时窗口和周窗口同时耗尽时，等待最后恢复的窗口。
        // 即使时间已过，仍须重新取到明确许可，不能仅凭本地时钟放行。
        return .blocked(nextCheckAt: max(resetAt, now.addingTimeInterval(Self.minimumRetryDelay)))
    }

    private nonisolated static func window(_ value: Any?) -> Window? {
        guard let raw = value as? [String: Any],
              let used = self.number(raw["used_percent"]), used >= 0,
              let seconds = self.number(raw["limit_window_seconds"]),
              seconds > 0, seconds.rounded(.towardZero) == seconds,
              let resetAt = self.number(raw["reset_at"]), resetAt > 0 else {
            return nil
        }
        return Window(usedPercent: used, resetAt: Date(timeIntervalSince1970: resetAt), durationSeconds: seconds)
    }

    private nonisolated static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
