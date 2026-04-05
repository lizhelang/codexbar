import Foundation

struct LocalCostSummaryService {
    private struct SummaryAccumulator {
        var today: Double = 0
        var last30: Double = 0
        var lifetime: Double = 0
        var todayTokens = 0
        var last30Tokens = 0
        var lifetimeTokens = 0
        var daily: [Date: (cost: Double, tokens: Int)] = [:]
    }

    private struct Pricing {
        let input: Double
        let output: Double
        let cachedInput: Double?
    }

    private let sessionLogStore: SessionLogStore
    private let calendar: Calendar

    private let pricingByModel: [String: Pricing] = [
        "gpt-5": Pricing(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5-codex": Pricing(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5-mini": Pricing(input: 2.5e-7, output: 2e-6, cachedInput: 2.5e-8),
        "gpt-5-nano": Pricing(input: 5e-8, output: 4e-7, cachedInput: 5e-9),
        "gpt-5.1": Pricing(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5.1-codex": Pricing(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5.1-codex-max": Pricing(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5.1-codex-mini": Pricing(input: 2.5e-7, output: 2e-6, cachedInput: 2.5e-8),
        "gpt-5.2": Pricing(input: 1.75e-6, output: 1.4e-5, cachedInput: 1.75e-7),
        "gpt-5.2-codex": Pricing(input: 1.75e-6, output: 1.4e-5, cachedInput: 1.75e-7),
        "gpt-5.3-codex": Pricing(input: 1.75e-6, output: 1.4e-5, cachedInput: 1.75e-7),
        "gpt-5.4": Pricing(input: 2.5e-6, output: 1.5e-5, cachedInput: 2.5e-7),
        "gpt-5.4-mini": Pricing(input: 7.5e-7, output: 4.5e-6, cachedInput: 7.5e-8),
        "gpt-5.4-nano": Pricing(input: 2e-7, output: 1.25e-6, cachedInput: 2e-8),
        "qwen35_4b": Pricing(input: 0, output: 0, cachedInput: 0),
    ]

    init(
        sessionLogStore: SessionLogStore = .shared,
        calendar: Calendar = .current
    ) {
        self.sessionLogStore = sessionLogStore
        self.calendar = calendar
    }

    func load(now: Date = Date()) -> LocalCostSummary {
        let todayStart = self.calendar.startOfDay(for: now)
        let last30Start = self.calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        let summary = self.sessionLogStore.reduceSessions(into: SummaryAccumulator()) { accumulator, record in
            guard let cost = self.costUSD(model: record.model, usage: record.usage) else { return }

            let totalTokens = record.usage.inputTokens + record.usage.outputTokens
            let day = self.calendar.startOfDay(for: record.startedAt)

            if record.startedAt >= last30Start {
                accumulator.last30 += cost
                accumulator.last30Tokens += totalTokens
            }
            if record.startedAt >= todayStart {
                accumulator.today += cost
                accumulator.todayTokens += totalTokens
            }

            accumulator.lifetime += cost
            accumulator.lifetimeTokens += totalTokens

            let current = accumulator.daily[day] ?? (0, 0)
            accumulator.daily[day] = (current.cost + cost, current.tokens + totalTokens)
        }

        let dailyEntries = summary.daily.map { date, value in
            DailyCostEntry(
                id: ISO8601DateFormatter().string(from: date),
                date: date,
                costUSD: value.cost,
                totalTokens: value.tokens
            )
        }.sorted { $0.date > $1.date }

        return LocalCostSummary(
            todayCostUSD: summary.today,
            todayTokens: summary.todayTokens,
            last30DaysCostUSD: summary.last30,
            last30DaysTokens: summary.last30Tokens,
            lifetimeCostUSD: summary.lifetime,
            lifetimeTokens: summary.lifetimeTokens,
            dailyEntries: dailyEntries,
            updatedAt: now
        )
    }

    private func costUSD(model: String, usage: SessionLogStore.Usage) -> Double? {
        guard let pricing = self.pricingByModel[model] else { return nil }
        let cached = min(max(0, usage.cachedInputTokens), max(0, usage.inputTokens))
        let nonCached = max(0, usage.inputTokens - cached)
        return Double(nonCached) * pricing.input +
            Double(cached) * (pricing.cachedInput ?? pricing.input) +
            Double(usage.outputTokens) * pricing.output
    }
}
