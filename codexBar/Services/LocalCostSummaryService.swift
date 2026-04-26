import Foundation

enum LocalCostPricing {
    static func defaultPricing(for model: String) -> CodexBarModelPricing? {
        let result = self.resolvePricing(
            model: model,
            customPricingByModel: [:],
            usage: nil,
            sessionUsage: nil
        )
        return result.hasDefaultPricing ? result.defaultPricing.modelPricing() : nil
    }

    static func effectivePricing(
        for model: String,
        customPricingByModel: [String: CodexBarModelPricing] = [:]
    ) -> CodexBarModelPricing {
        self.resolvePricing(
            model: model,
            customPricingByModel: customPricingByModel,
            usage: nil,
            sessionUsage: nil
        ).effectivePricing.modelPricing()
    }

    static func costUSD(
        model: String,
        usage: SessionLogStore.Usage,
        sessionUsage: SessionLogStore.Usage? = nil,
        customPricingByModel: [String: CodexBarModelPricing] = [:]
    ) -> Double {
        self.resolvePricing(
            model: model,
            customPricingByModel: customPricingByModel,
            usage: usage,
            sessionUsage: sessionUsage
        ).costUsd ?? 0
    }

    private static func resolvePricing(
        model: String,
        customPricingByModel: [String: CodexBarModelPricing],
        usage: SessionLogStore.Usage?,
        sessionUsage: SessionLogStore.Usage?
    ) -> PortableCoreLocalCostPricingResult {
        let request = PortableCoreLocalCostPricingRequest(
            model: model,
            pricingOverrides: customPricingByModel.mapValues(PortableCoreModelPricing.legacy(from:)),
            usage: usage.map(PortableCoreTokenUsage.legacy(from:)),
            sessionUsage: sessionUsage.map(PortableCoreTokenUsage.legacy(from:))
        )
        do {
            return try RustPortableCoreAdapter.shared.resolveLocalCostPricing(
                request,
                buildIfNeeded: true
            )
        } catch {
            return PortableCoreLocalCostPricingResult(
                hasDefaultPricing: false,
                defaultPricing: .legacy(from: .zero),
                effectivePricing: .legacy(from: .zero),
                costUsd: 0,
                rustOwner: "swift.failClosedLocalCostPricing"
            )
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
