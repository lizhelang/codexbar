import Foundation

enum LocalCostPricing {
    private static let gpt54LongContextInputThreshold = 272_000

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
        let cached = min(max(0, usage.cachedInputTokens), max(0, usage.inputTokens))
        let nonCached = max(0, usage.inputTokens - cached)
        let longContextRateMultiplier = self.usesGPT54LongContextPremium(
            model: normalizedModel,
            sessionUsage: sessionUsage
        )
        ? 2.0
        : 1.0
        let outputRateMultiplier = longContextRateMultiplier > 1 ? 1.5 : 1.0

        return Double(nonCached) * pricing.inputUSDPerToken * longContextRateMultiplier +
            Double(cached) * pricing.cachedInputUSDPerToken +
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

    private static func usesGPT54LongContextPremium(
        model: String,
        sessionUsage: SessionLogStore.Usage?
    ) -> Bool {
        guard let sessionUsage,
              sessionUsage.inputTokens > self.gpt54LongContextInputThreshold else {
            return false
        }

        return model == "gpt-5.4" || self.modelID(model, isVariantOf: "gpt-5.4")
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

struct LocalCostSummaryService {
    private let sessionLogStore: SessionLogStore

    init(
        sessionLogStore: SessionLogStore = .shared,
        calendar _: Calendar = .current
    ) {
        self.sessionLogStore = sessionLogStore
    }

    func historicalModels() -> [String] {
        self.sessionLogStore.historicalModels()
    }

    func load(
        now: Date = Date(),
        modelPricingOverrides: [String: CodexBarModelPricing] = [:],
        refreshSessionCache: Bool = true
    ) -> LocalCostSummary {
        let events = self.sessionLogStore.reduceBillableEvents(
            into: [PortableCoreLocalCostEvent](),
            refreshSessionCache: refreshSessionCache
        ) { partialResult, event in
            partialResult.append(
                PortableCoreLocalCostEvent(
                    model: event.model,
                    timestamp: event.timestamp.timeIntervalSince1970,
                    usage: .legacy(from: event.usage),
                    sessionUsage: .legacy(from: event.sessionUsage)
                )
            )
        }
        let summary =
            (try? RustPortableCoreAdapter.shared.summarizeLocalCost(
            PortableCoreLocalCostSummaryRequest(
                now: now.timeIntervalSince1970,
                pricingOverrides: modelPricingOverrides.mapValues(PortableCoreModelPricing.legacy(from:)),
                events: events
            ),
            buildIfNeeded: false
        )) ?? PortableCoreLocalCostSummarySnapshot.failClosed(now: now.timeIntervalSince1970)
        return summary.localCostSummary()
    }
}
