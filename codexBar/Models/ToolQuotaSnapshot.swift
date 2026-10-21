import Foundation

nonisolated enum ToolQuotaStatus: String, Codable, Sendable {
    case loading, ready, notConfigured, unsupported, authenticationRequired, failed
}

nonisolated struct ToolQuotaWindow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Double?
    var used: Double? = nil
    var limit: Double? = nil
    var unit: String? = nil
    var resetsAt: Date? = nil
}

nonisolated struct ToolQuotaBalance: Codable, Equatable, Sendable {
    let amount: Double
    let currency: String
}

nonisolated enum ToolQuotaEvidence: String, Codable, Sendable {
    case accountService, localSnapshot
}

/// Claude's reset offers are distinct from paid extra-usage credits.
nonisolated struct ClaudeResetCreditGrant: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let remaining: Int
    var startsAt: Date? = nil
    var expiresAt: Date? = nil
    var paused = false
    var usableNow: Bool? = nil
    var clears: [String] = []

    func isAvailable(at now: Date) -> Bool {
        !self.paused && self.remaining > 0 && self.remaining <= 50
            && (self.startsAt.map { $0 <= now } ?? true)
            && (self.expiresAt.map { $0 > now } ?? true)
    }
}

nonisolated struct ClaudeResetCredits: Codable, Equatable, Sendable {
    let eligible: Bool
    var ineligibleReason: String? = nil
    var grants: [ClaudeResetCreditGrant] = []
    var hasMalformedGrants = false

    func activeGrants(at now: Date) -> [ClaudeResetCreditGrant] {
        guard self.eligible else { return [] }
        return self.grants.filter { $0.isAvailable(at: now) }.sorted {
            if $0.expiresAt != $1.expiresAt { return ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            return $0.id < $1.id
        }
    }

    func availableCount(at now: Date) -> Int {
        self.activeGrants(at: now).reduce(0) { $0 + $1.remaining }
    }
}

/// Account quota is independent from the selected local usage period and never inferred from token counts.
nonisolated struct ToolQuotaSnapshot: Codable, Equatable, Sendable {
    let client: ToolUsageClient
    let status: ToolQuotaStatus
    let providerName: String
    var windows: [ToolQuotaWindow] = []
    var balance: ToolQuotaBalance? = nil
    var refreshedAt: Date? = nil
    let statusDetail: String
    var evidence: ToolQuotaEvidence? = nil
    /// Nil means the source did not provide an inventory (including older caches), not zero cards.
    var resetCredits: ClaudeResetCredits? = nil

    var isLocalSnapshot: Bool {
        if let evidence { return evidence == .localSnapshot }
        // Older quota caches predate evidence, but DSH snapshot providers had this dedicated prefix.
        return self.client == .deepSeekHarness && self.providerName.hasPrefix("DSH · ")
    }
}
