import Foundation

struct DailyCostEntry: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let date: Date
    let costUSD: Double
    let totalTokens: Int
    let costIsComplete: Bool

    init(id: String, date: Date, costUSD: Double, totalTokens: Int, costIsComplete: Bool = true) {
        self.id = id
        self.date = date
        self.costUSD = costUSD
        self.totalTokens = totalTokens
        self.costIsComplete = costIsComplete
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, costUSD, totalTokens, costIsComplete
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.date = try values.decode(Date.self, forKey: .date)
        self.costUSD = try values.decode(Double.self, forKey: .costUSD)
        self.totalTokens = try values.decode(Int.self, forKey: .totalTokens)
        self.costIsComplete = try values.decodeIfPresent(Bool.self, forKey: .costIsComplete) ?? true
    }
}

struct LocalCostSummary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var todayCostUSD: Double
    var todayTokens: Int
    var last30DaysCostUSD: Double
    var last30DaysTokens: Int
    var lifetimeCostUSD: Double
    var lifetimeTokens: Int
    var dailyEntries: [DailyCostEntry]
    var updatedAt: Date?

    static let empty = LocalCostSummary(
        todayCostUSD: 0,
        todayTokens: 0,
        last30DaysCostUSD: 0,
        last30DaysTokens: 0,
        lifetimeCostUSD: 0,
        lifetimeTokens: 0,
        dailyEntries: [],
        updatedAt: nil
    )

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case todayCostUSD
        case todayTokens
        case last30DaysCostUSD
        case last30DaysTokens
        case lifetimeCostUSD
        case lifetimeTokens
        case dailyEntries
        case updatedAt
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        todayCostUSD: Double,
        todayTokens: Int,
        last30DaysCostUSD: Double,
        last30DaysTokens: Int,
        lifetimeCostUSD: Double,
        lifetimeTokens: Int,
        dailyEntries: [DailyCostEntry],
        updatedAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.todayCostUSD = todayCostUSD
        self.todayTokens = todayTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.last30DaysTokens = last30DaysTokens
        self.lifetimeCostUSD = lifetimeCostUSD
        self.lifetimeTokens = lifetimeTokens
        self.dailyEntries = dailyEntries
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.todayCostUSD = try container.decode(Double.self, forKey: .todayCostUSD)
        self.todayTokens = try container.decode(Int.self, forKey: .todayTokens)
        self.last30DaysCostUSD = try container.decode(Double.self, forKey: .last30DaysCostUSD)
        self.last30DaysTokens = try container.decode(Int.self, forKey: .last30DaysTokens)
        self.lifetimeCostUSD = try container.decode(Double.self, forKey: .lifetimeCostUSD)
        self.lifetimeTokens = try container.decode(Int.self, forKey: .lifetimeTokens)
        self.dailyEntries = try container.decode([DailyCostEntry].self, forKey: .dailyEntries)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}
