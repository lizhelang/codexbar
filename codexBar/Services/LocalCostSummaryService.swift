import Foundation

enum LocalCostPricing {
    private static let longContextInputThreshold = 272_000
    private static let longContextPremiumBaseModels = ["gpt-5.4", "gpt-5.5", "gpt-5.6"]

    private static let defaultPricingByModel: [String: CodexBarModelPricing] = [
        "gpt-5": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5-codex": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5-mini": CodexBarModelPricing(inputUSDPerToken: 2.5e-7, cachedInputUSDPerToken: 2.5e-8, outputUSDPerToken: 2e-6),
        "gpt-5-nano": CodexBarModelPricing(inputUSDPerToken: 5e-8, cachedInputUSDPerToken: 5e-9, outputUSDPerToken: 4e-7),
        "gpt-5.1": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5.1-codex": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5.1-codex-max": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5.1-codex-mini": CodexBarModelPricing(inputUSDPerToken: 2.5e-7, cachedInputUSDPerToken: 2.5e-8, outputUSDPerToken: 2e-6),
        "gpt-5.2": CodexBarModelPricing(inputUSDPerToken: 1.75e-6, cachedInputUSDPerToken: 1.75e-7, outputUSDPerToken: 1.4e-5),
        "gpt-5.2-codex": CodexBarModelPricing(inputUSDPerToken: 1.75e-6, cachedInputUSDPerToken: 1.75e-7, outputUSDPerToken: 1.4e-5),
        "gpt-5.3-codex": CodexBarModelPricing(inputUSDPerToken: 1.75e-6, cachedInputUSDPerToken: 1.75e-7, outputUSDPerToken: 1.4e-5),
        "gpt-5.4": CodexBarModelPricing(inputUSDPerToken: 2.5e-6, cachedInputUSDPerToken: 2.5e-7, outputUSDPerToken: 1.5e-5),
        "gpt-5.4-mini": CodexBarModelPricing(inputUSDPerToken: 7.5e-7, cachedInputUSDPerToken: 7.5e-8, outputUSDPerToken: 4.5e-6),
        "gpt-5.4-nano": CodexBarModelPricing(inputUSDPerToken: 2e-7, cachedInputUSDPerToken: 2e-8, outputUSDPerToken: 1.25e-6),
        "gpt-5.5": CodexBarModelPricing(inputUSDPerToken: 5e-6, cachedInputUSDPerToken: 5e-7, outputUSDPerToken: 3e-5),
        "gpt-5.6": CodexBarModelPricing(inputUSDPerToken: 5e-6, cachedInputUSDPerToken: 5e-7, outputUSDPerToken: 3e-5),
        "gpt-5.6-sol": CodexBarModelPricing(inputUSDPerToken: 5e-6, cachedInputUSDPerToken: 5e-7, outputUSDPerToken: 3e-5),
        "gpt-5.6-terra": CodexBarModelPricing(inputUSDPerToken: 2.5e-6, cachedInputUSDPerToken: 2.5e-7, outputUSDPerToken: 1.5e-5),
        "gpt-5.6-luna": CodexBarModelPricing(inputUSDPerToken: 1e-6, cachedInputUSDPerToken: 1e-7, outputUSDPerToken: 6e-6),
        "qwen35_4b": .zero,
    ]

    static func defaultPricing(for model: String) -> CodexBarModelPricing? {
        let normalizedModel = self.normalizedModelID(model)
        if let pricing = self.defaultPricingByModel[normalizedModel] {
            return pricing
        }

        for key in self.defaultPricingKeysBySpecificity
            where self.modelID(normalizedModel, isVariantOf: key) {
            return self.defaultPricingByModel[key]
        }

        return nil
    }

    static func effectivePricing(
        for model: String,
        customPricingByModel: [String: CodexBarModelPricing] = [:]
    ) -> CodexBarModelPricing {
        let normalizedModel = self.normalizedModelID(model)
        return customPricingByModel[normalizedModel] ?? self.defaultPricing(for: normalizedModel) ?? .zero
    }

    static func costUSD(
        model: String,
        usage: SessionLogStore.Usage,
        sessionUsage: SessionLogStore.Usage? = nil,
        customPricingByModel: [String: CodexBarModelPricing] = [:]
    ) -> Double {
        let normalizedModel = self.normalizedModelID(model)
        let pricing = self.effectivePricing(for: normalizedModel, customPricingByModel: customPricingByModel)
        let input = max(0, usage.inputTokens)
        let cached = max(0, usage.cachedInputTokens)
        let billableInput = max(0, input - cached)
        let longContextRateMultiplier = self.usesLongContextPremium(
            model: normalizedModel,
            usage: usage
        )
        ? 2.0
        : 1.0
        let outputRateMultiplier = longContextRateMultiplier > 1 ? 1.5 : 1.0

        return Double(billableInput) * pricing.inputUSDPerToken * longContextRateMultiplier +
            Double(cached) * pricing.cachedInputUSDPerToken * longContextRateMultiplier +
            Double(usage.outputTokens) * pricing.outputUSDPerToken * outputRateMultiplier
    }

    private static let defaultPricingKeysBySpecificity = defaultPricingByModel.keys.sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }

    private static func normalizedModelID(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            return String(trimmed.dropFirst("openai/".count))
        }
        return trimmed
    }

    private static func usesLongContextPremium(
        model: String,
        usage: SessionLogStore.Usage
    ) -> Bool {
        guard usage.inputTokens > self.longContextInputThreshold else {
            return false
        }

        guard model.hasSuffix("-mini") == false,
              model.hasSuffix("-nano") == false else {
            return false
        }

        return self.longContextPremiumBaseModels.contains { base in
            model == base || self.modelID(model, isVariantOf: base)
        }
    }

    private static func modelID(_ model: String, isVariantOf baseModel: String) -> Bool {
        guard model.count > baseModel.count,
              model.hasPrefix(baseModel) else {
            return false
        }

        let delimiterIndex = model.index(model.startIndex, offsetBy: baseModel.count)
        switch model[delimiterIndex] {
        case "-", ".", "_", ":":
            return true
        default:
            return false
        }
    }
}

struct LocalCostSummaryLoadResult {
    let summary: LocalCostSummary
    let isComplete: Bool
}

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

    private let sessionLogStoreProvider: () -> SessionLogStore
    private let calendar: Calendar

    init(
        sessionLogStore: SessionLogStore,
        calendar: Calendar = .current
    ) {
        self.sessionLogStoreProvider = { sessionLogStore }
        self.calendar = calendar
    }

    init(
        sessionLogStoreProvider: @escaping () -> SessionLogStore = { .shared },
        calendar: Calendar = .current
    ) {
        self.sessionLogStoreProvider = sessionLogStoreProvider
        self.calendar = calendar
    }

    func historicalModels(refreshSessionCache: Bool = false) -> [String] {
        self.sessionLogStoreProvider().historicalModels(refreshSessionCache: refreshSessionCache)
    }

    func load(
        now: Date = Date(),
        modelPricingOverrides: [String: CodexBarModelPricing] = [:],
        refreshSessionCache: Bool = true
    ) -> LocalCostSummary {
        self.loadWithStatus(
            now: now,
            modelPricingOverrides: modelPricingOverrides,
            refreshSessionCache: refreshSessionCache
        ).summary
    }

    func loadWithStatus(
        now: Date = Date(),
        modelPricingOverrides: [String: CodexBarModelPricing] = [:],
        refreshSessionCache: Bool = true
    ) -> LocalCostSummaryLoadResult {
        let sessionLogStore = self.sessionLogStoreProvider()
        let todayStart = self.calendar.startOfDay(for: now)
        let last30Start = self.calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        let reduction = sessionLogStore.reduceBillableEventsWithStatus(
            into: SummaryAccumulator(),
            refreshSessionCache: refreshSessionCache,
            costCalculator: { model, usage, sessionUsage in
                LocalCostPricing.costUSD(
                    model: model,
                    usage: usage,
                    sessionUsage: sessionUsage,
                    customPricingByModel: modelPricingOverrides
                )
            }
        ) { accumulator, event in
            let totalTokens = event.usage.totalTokens
            let day = self.calendar.startOfDay(for: event.timestamp)

            if event.timestamp >= last30Start {
                accumulator.last30 += event.costUSD
                accumulator.last30Tokens += totalTokens
            }
            if event.timestamp >= todayStart {
                accumulator.today += event.costUSD
                accumulator.todayTokens += totalTokens
            }

            accumulator.lifetime += event.costUSD
            accumulator.lifetimeTokens += totalTokens

            let current = accumulator.daily[day] ?? (0, 0)
            accumulator.daily[day] = (current.cost + event.costUSD, current.tokens + totalTokens)
        }

        let summary = reduction.result
        let dailyEntries = summary.daily.map { date, value in
            DailyCostEntry(
                id: ISO8601DateFormatter().string(from: date),
                date: date,
                costUSD: value.cost,
                totalTokens: value.tokens
            )
        }.sorted { $0.date > $1.date }

        return LocalCostSummaryLoadResult(
            summary: LocalCostSummary(
                todayCostUSD: summary.today,
                todayTokens: summary.todayTokens,
                last30DaysCostUSD: summary.last30,
                last30DaysTokens: summary.last30Tokens,
                lifetimeCostUSD: summary.lifetime,
                lifetimeTokens: summary.lifetimeTokens,
                dailyEntries: dailyEntries,
                updatedAt: now
            ),
            isComplete: reduction.isComplete
        )
    }
}
