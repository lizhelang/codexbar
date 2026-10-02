import Foundation

nonisolated enum ToolUsageClient: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeCode
    case openCode
    case cursor
    case deepSeekHarness

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        case .cursor: "Cursor"
        case .deepSeekHarness: "DeepSeek Harness"
        }
    }
}

enum ToolUsageAvailability: String, Codable, Sendable {
    case ready
    case partial
    case noRecords
    case sourceMissing
    case needsImport
    case failed
}

enum ToolUsageEvidence: String, Codable, Sendable {
    /// Token counts come from a client transcript or database usage field.
    case reported
    /// Token counts come from an account export supplied by the user.
    case imported
    /// Token counts come from the client's authenticated usage API.
    case server
    /// Token counts were inferred from content rather than reported by the client.
    case estimated
}

nonisolated enum ToolCostEvidence: String, Codable, Sendable {
    case reported, estimated
}

struct ToolUsageDailyEntry: Codable, Equatable, Identifiable, Sendable {
    let date: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let totalTokens: Int
    /// Complete usage value, reported by the source or estimated at standard API prices.
    let costUSD: Double?
    /// Known portion when some requests cannot be priced. Nil is not a zero-cost day.
    var knownCostUSD: Double? = nil
    /// Usage value and money charged are distinct for subscriptions.
    var costEvidence: ToolCostEvidence? = nil
    var billedCostUSD: Double? = nil

    var id: Date { self.date }

    nonisolated init(
        date: Date,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        totalTokens: Int,
        costUSD: Double? = nil,
        knownCostUSD: Double? = nil,
        costEvidence: ToolCostEvidence? = nil,
        billedCostUSD: Double? = nil
    ) {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.knownCostUSD = knownCostUSD
        self.costEvidence = costEvidence
        self.billedCostUSD = billedCostUSD
    }
}

/// Minimal, dated usage metadata for model/session/project breakdowns. Never stores message content.
struct ToolUsageRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let modelID: String?
    let sessionID: String?
    let sessionTitle: String?
    let projectPath: String?
    /// Nil means no persisted turn state is available; recency is not evidence of running.
    let sessionIsRunning: Bool?
    let contextWindowTokens: Int?
    let contextUsedTokens: Int?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let totalTokens: Int
    let costUSD: Double?
    var costEvidence: ToolCostEvidence? = nil
    var billedCostUSD: Double? = nil

    nonisolated init(
        id: String, timestamp: Date, modelID: String? = nil, sessionID: String? = nil,
        sessionTitle: String? = nil, projectPath: String? = nil,
        sessionIsRunning: Bool? = nil, contextWindowTokens: Int? = nil, contextUsedTokens: Int? = nil,
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0, totalTokens: Int, costUSD: Double? = nil,
        costEvidence: ToolCostEvidence? = nil, billedCostUSD: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelID = Self.cleaned(modelID)
        self.sessionID = Self.cleaned(sessionID)
        self.sessionTitle = Self.cleaned(sessionTitle)
        self.projectPath = Self.cleaned(projectPath)
        self.sessionIsRunning = sessionIsRunning
        self.contextWindowTokens = contextWindowTokens
        self.contextUsedTokens = contextUsedTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costEvidence = costEvidence
        self.billedCostUSD = billedCostUSD
    }

    nonisolated private static func cleaned(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

struct ToolUsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    let client: ToolUsageClient
    let availability: ToolUsageAvailability
    let evidence: ToolUsageEvidence
    let dailyEntries: [ToolUsageDailyEntry]
    let usageRecords: [ToolUsageRecord]
    /// Timestamp of the newest usage entry, when known.
    let latestUsageAt: Date?
    /// Timestamp at which this source was last scanned or imported.
    let refreshedAt: Date?
    /// Short status suitable for the interface; must not contain transcript text or credentials.
    let statusDetail: String?

    var id: ToolUsageClient { self.client }

    nonisolated init(
        client: ToolUsageClient,
        availability: ToolUsageAvailability,
        evidence: ToolUsageEvidence = .reported,
        dailyEntries: [ToolUsageDailyEntry] = [],
        usageRecords: [ToolUsageRecord] = [],
        latestUsageAt: Date? = nil,
        refreshedAt: Date? = nil,
        statusDetail: String? = nil
    ) {
        self.client = client
        self.availability = availability
        self.evidence = evidence
        self.dailyEntries = dailyEntries
        self.usageRecords = usageRecords
        self.latestUsageAt = latestUsageAt
        self.refreshedAt = refreshedAt
        self.statusDetail = statusDetail
    }

    private enum CodingKeys: String, CodingKey {
        case client, availability, evidence, dailyEntries, usageRecords, latestUsageAt, refreshedAt, statusDetail
    }

    nonisolated init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.client = try values.decode(ToolUsageClient.self, forKey: .client)
        self.availability = try values.decode(ToolUsageAvailability.self, forKey: .availability)
        self.evidence = try values.decode(ToolUsageEvidence.self, forKey: .evidence)
        self.dailyEntries = try values.decode([ToolUsageDailyEntry].self, forKey: .dailyEntries)
        self.usageRecords = try values.decodeIfPresent([ToolUsageRecord].self, forKey: .usageRecords) ?? []
        self.latestUsageAt = try values.decodeIfPresent(Date.self, forKey: .latestUsageAt)
        self.refreshedAt = try values.decodeIfPresent(Date.self, forKey: .refreshedAt)
        self.statusDetail = try values.decodeIfPresent(String.self, forKey: .statusDetail)
    }

}

protocol ToolUsageCollecting: Sendable {
    nonisolated var client: ToolUsageClient { get }
    nonisolated func collect(now: Date, calendar: Calendar) -> ToolUsageSnapshot
}
