import Foundation

nonisolated enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case thisWeek
    case thisMonth
    case last7Days
    case last30Days
    case allTime

    var id: String { self.rawValue }

    static let primaryCases: [Self] = [.today, .thisWeek, .thisMonth, .allTime]
    static let additionalCases: [Self] = [.last7Days, .last30Days]

    var title: String {
        switch self {
        case .today: L.zh ? "今天" : "Day"
        case .thisWeek: L.zh ? "本周" : "Week"
        case .thisMonth: L.zh ? "本月" : "Month"
        case .last7Days: L.zh ? "7 天" : "7d"
        case .last30Days: L.zh ? "30 天" : "30d"
        case .allTime: L.zh ? "全部" : "All"
        }
    }

    var numberOfDays: Int? {
        switch self {
        case .today: 1
        case .thisWeek, .thisMonth: nil
        case .last7Days: 7
        case .last30Days: 30
        case .allTime: nil
        }
    }

    func firstDay(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)?.start
        case .allTime:
            return nil
        default:
            return self.numberOfDays.flatMap {
                calendar.date(byAdding: .day, value: 1 - $0, to: calendar.startOfDay(for: now))
            }
        }
    }

    func chartDayCount(now: Date, calendar: Calendar) -> Int {
        switch self {
        case .thisWeek:
            guard let start = self.firstDay(now: now, calendar: calendar) else { return 7 }
            return (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0) + 1
        case .thisMonth:
            return calendar.component(.day, from: now)
        case .allTime:
            return 30
        default:
            return self.numberOfDays ?? 30
        }
    }
}

nonisolated enum UsageMetric: String, CaseIterable, Identifiable, Sendable {
    case tokens
    case cost

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .tokens: L.zh ? "Token" : "Tokens"
        case .cost: L.zh ? "费用" : "Cost"
        }
    }
}

nonisolated enum UsageRateUnit: String, Sendable {
    case perSecond
    case perMinute

    var shortLabel: String {
        switch self {
        case .perSecond: "tok/s"
        case .perMinute: "tok/min"
        }
    }

    var next: Self { self == .perSecond ? .perMinute : .perSecond }
}

nonisolated enum UsageRatePresentation {
    /// 所选时间范围的全部 Token 平均值，不能作为实时生成速度使用。
    static func intervalAverage(
        aggregate: UsageAggregate,
        period: UsagePeriod,
        unit: UsageRateUnit,
        now: Date,
        calendar: Calendar
    ) -> Double? {
        guard aggregate.tokens > 0 else { return nil }
        let start = period.firstDay(now: now, calendar: calendar)
            ?? aggregate.dailyEntries.first?.date
        guard let start, start < now else { return nil }
        let seconds = max(now.timeIntervalSince(start), 1)
        let multiplier = unit == .perMinute ? 60.0 : 1.0
        return Double(aggregate.tokens) / seconds * multiplier
    }
}

nonisolated enum UsageScope: Hashable, Identifiable, Sendable {
    case all
    case codex
    case client(ToolUsageClient)

    static var allCases: [Self] {
        [.all, .codex] + ToolUsageClient.allCases.map(Self.client)
    }

    var id: String {
        switch self {
        case .all: "all"
        case .codex: "codex"
        case .client(let client): client.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: L.zh ? "全部工具" : "All tools"
        case .codex: "Codex"
        case .client(let client): client.displayName
        }
    }
}

nonisolated struct UsageChartEntry: Identifiable, Equatable, Sendable {
    let date: Date
    let tokens: Int
    let knownCostUSD: Double
    let costIsComplete: Bool

    var id: Date { self.date }
}

nonisolated struct UsageAggregate: Equatable, Sendable {
    let tokens: Int
    let knownCostUSD: Double
    let costIsComplete: Bool
    let dailyEntries: [UsageChartEntry]
    let latestUsageAt: Date?

    static let empty = Self(
        tokens: 0,
        knownCostUSD: 0,
        costIsComplete: true,
        dailyEntries: [],
        latestUsageAt: nil
    )
}

nonisolated enum UsagePresentation {
    static func aggregate(
        codex: LocalCostSummary,
        external: [ToolUsageClient: ToolUsageSnapshot],
        scope: UsageScope,
        period: UsagePeriod,
        now: Date,
        calendar: Calendar
    ) -> UsageAggregate {
        let firstDay = period.firstDay(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: UsageChartEntry] = [:]
        var latestUsageAt: Date?

        func include(date: Date, tokens: Int, costUSD: Double?, costIsComplete: Bool = true) {
            let day = calendar.startOfDay(for: date)
            guard day <= today, firstDay.map({ day >= $0 }) ?? true else { return }
            let existing = byDay[day]
            let positiveTokens = max(0, tokens)
            let safeCost = costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            byDay[day] = UsageChartEntry(
                date: day,
                tokens: Self.saturatingAdd(existing?.tokens ?? 0, positiveTokens),
                knownCostUSD: Self.saturatingAdd(existing?.knownCostUSD ?? 0, safeCost ?? 0),
                costIsComplete: (existing?.costIsComplete ?? true) && costIsComplete && (safeCost != nil || positiveTokens == 0)
            )
        }

        if scope == .all || scope == .codex {
            for entry in codex.dailyEntries {
                include(date: entry.date, tokens: entry.totalTokens, costUSD: entry.costUSD, costIsComplete: entry.costIsComplete)
            }
            latestUsageAt = codex.updatedAt
        }

        for client in ToolUsageClient.allCases {
            guard scope == .all || scope == .client(client),
                  let snapshot = external[client] else { continue }
            for entry in snapshot.dailyEntries {
                include(date: entry.date, tokens: entry.totalTokens, costUSD: entry.costUSD ?? entry.knownCostUSD,
                        costIsComplete: entry.costUSD != nil || entry.totalTokens == 0)
            }
            if let observed = snapshot.latestUsageAt,
               latestUsageAt.map({ observed > $0 }) ?? true {
                latestUsageAt = observed
            }
        }

        let entries = byDay.values.sorted { $0.date < $1.date }
        let hasIncompleteSource: Bool = {
            switch scope {
            case .codex:
                return false
            case .client(let client):
                return external[client]?.availability != .ready
            case .all:
                return ToolUsageClient.allCases.contains { external[$0]?.availability != .ready }
            }
        }()
        return UsageAggregate(
            tokens: entries.reduce(0) { Self.saturatingAdd($0, $1.tokens) },
            knownCostUSD: entries.reduce(0) { Self.saturatingAdd($0, $1.knownCostUSD) },
            costIsComplete: !hasIncompleteSource && entries.allSatisfy(\.costIsComplete),
            dailyEntries: entries,
            latestUsageAt: latestUsageAt
        )
    }

    private static func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int.max : sum
    }

    private static func saturatingAdd(_ left: Double, _ right: Double) -> Double {
        let sum = left + right
        return sum.isFinite ? sum : Double.greatestFiniteMagnitude
    }

    static func chartEntries(
        aggregate: UsageAggregate,
        period: UsagePeriod,
        now: Date,
        calendar: Calendar
    ) -> [UsageChartEntry] {
        let numberOfDays = period.chartDayCount(now: now, calendar: calendar)
        return Self.chartEntries(dailyEntries: aggregate.dailyEntries, numberOfDays: numberOfDays, now: now, calendar: calendar)
    }

    static func chartEntries(dailyEntries: [UsageChartEntry], numberOfDays: Int, now: Date, calendar: Calendar) -> [UsageChartEntry] {
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(uniqueKeysWithValues: dailyEntries.map { ($0.date, $0) })
        return (0..<max(0, numberOfDays)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset + 1 - numberOfDays, to: today) else {
                return nil
            }
            return byDay[day] ?? UsageChartEntry(
                date: day,
                tokens: 0,
                knownCostUSD: 0,
                costIsComplete: true
            )
        }
    }
}
