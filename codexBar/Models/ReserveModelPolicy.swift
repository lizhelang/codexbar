import Foundation

enum ReserveModelPolicy {
    static let modelID = "gpt-reserve"
    static let reasoningEfforts = ["low", "medium", "high", "xhigh", "max"]

    static func isReserve(_ modelID: String) -> Bool {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == self.modelID
    }

    static func displayName(for modelID: String) -> String {
        self.isReserve(modelID) ? "GPT Reserve" : modelID
    }

    static func normalizedReasoningEffort(_ effort: String) -> String {
        self.reasoningEfforts.contains(effort) ? effort : "medium"
    }

    static func isAvailable(account: TokenAccount?, now: Date = Date()) -> Bool {
        guard let account, !account.tokenExpired, !account.isBanned,
              let used = account.lunaReserveUsedPercent, used.isFinite, used >= 0 else {
            return false
        }
        return used < 100 || (account.lunaReserveResetAt.map { $0 <= now } ?? false)
    }
}
