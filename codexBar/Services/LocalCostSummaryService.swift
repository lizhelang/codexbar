import Foundation

enum LocalCostPricing {
    private static let longContextInputThreshold = 272_000
    private static let longContextPremiumBaseModels = ["gpt-5.4", "gpt-5.5", "gpt-5.6", "gpt-6-astra"]

    private static let defaultPricingByModel: [String: CodexBarModelPricing] = [
        "gpt-5": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5-codex": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5-pro": CodexBarModelPricing(inputUSDPerToken: 1.5e-5, cachedInputUSDPerToken: 1.5e-5, outputUSDPerToken: 1.2e-4),
        "gpt-5-mini": CodexBarModelPricing(inputUSDPerToken: 2.5e-7, cachedInputUSDPerToken: 2.5e-8, outputUSDPerToken: 2e-6),
        "gpt-5-nano": CodexBarModelPricing(inputUSDPerToken: 5e-8, cachedInputUSDPerToken: 5e-9, outputUSDPerToken: 4e-7),
        "gpt-5.1": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5.1-codex": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5.1-codex-max": CodexBarModelPricing(inputUSDPerToken: 1.25e-6, cachedInputUSDPerToken: 1.25e-7, outputUSDPerToken: 1e-5),
        "gpt-5.1-codex-mini": CodexBarModelPricing(inputUSDPerToken: 2.5e-7, cachedInputUSDPerToken: 2.5e-8, outputUSDPerToken: 2e-6),
        "gpt-5.2": CodexBarModelPricing(inputUSDPerToken: 1.75e-6, cachedInputUSDPerToken: 1.75e-7, outputUSDPerToken: 1.4e-5),
        "gpt-5.2-codex": CodexBarModelPricing(inputUSDPerToken: 1.75e-6, cachedInputUSDPerToken: 1.75e-7, outputUSDPerToken: 1.4e-5),
        "gpt-5.2-pro": CodexBarModelPricing(inputUSDPerToken: 2.1e-5, cachedInputUSDPerToken: 2.1e-5, outputUSDPerToken: 1.68e-4),
        "gpt-5.3-codex": CodexBarModelPricing(inputUSDPerToken: 1.75e-6, cachedInputUSDPerToken: 1.75e-7, outputUSDPerToken: 1.4e-5),
        "gpt-5.3-codex-spark": .zero,
        "gpt-5.4": CodexBarModelPricing(inputUSDPerToken: 2.5e-6, cachedInputUSDPerToken: 2.5e-7, outputUSDPerToken: 1.5e-5),
        "gpt-5.4-mini": CodexBarModelPricing(inputUSDPerToken: 7.5e-7, cachedInputUSDPerToken: 7.5e-8, outputUSDPerToken: 4.5e-6),
        "gpt-5.4-nano": CodexBarModelPricing(inputUSDPerToken: 2e-7, cachedInputUSDPerToken: 2e-8, outputUSDPerToken: 1.25e-6),
        "gpt-5.4-pro": CodexBarModelPricing(inputUSDPerToken: 3e-5, cachedInputUSDPerToken: 3e-5, outputUSDPerToken: 1.8e-4),
        "gpt-5.5": CodexBarModelPricing(inputUSDPerToken: 5e-6, cachedInputUSDPerToken: 5e-7, outputUSDPerToken: 3e-5),
        "gpt-5.5-pro": CodexBarModelPricing(inputUSDPerToken: 3e-5, cachedInputUSDPerToken: 3e-5, outputUSDPerToken: 1.8e-4),
        "gpt-5.6": CodexBarModelPricing(inputUSDPerToken: 5e-6, cachedInputUSDPerToken: 5e-7, outputUSDPerToken: 3e-5),
        "gpt-5.6-sol": CodexBarModelPricing(inputUSDPerToken: 5e-6, cachedInputUSDPerToken: 5e-7, outputUSDPerToken: 3e-5),
        "gpt-5.6-terra": CodexBarModelPricing(inputUSDPerToken: 2.5e-6, cachedInputUSDPerToken: 2.5e-7, outputUSDPerToken: 1.5e-5),
        "gpt-5.6-luna": CodexBarModelPricing(inputUSDPerToken: 1e-6, cachedInputUSDPerToken: 1e-7, outputUSDPerToken: 6e-6),
        // https://developers.openai.com/api/docs/models/gpt-6-astra (2026-09-09)
        "gpt-6-astra": CodexBarModelPricing(
            inputUSDPerToken: 1e-5, cachedInputUSDPerToken: 1e-6, outputUSDPerToken: 5e-5
        ),
        "qwen35_4b": .zero,
    ]

    private static let priorityPricingByModel: [String: CodexBarModelPricing] = [
        "gpt-5.4": CodexBarModelPricing(inputUSDPerToken: 5e-6, cachedInputUSDPerToken: 5e-7, outputUSDPerToken: 3e-5),
        "gpt-5.4-mini": CodexBarModelPricing(inputUSDPerToken: 1.5e-6, cachedInputUSDPerToken: 1.5e-7, outputUSDPerToken: 9e-6),
        "gpt-5.5": CodexBarModelPricing(inputUSDPerToken: 1.25e-5, cachedInputUSDPerToken: 1.25e-6, outputUSDPerToken: 7.5e-5),
        "gpt-5.6": CodexBarModelPricing(inputUSDPerToken: 1e-5, cachedInputUSDPerToken: 1e-6, outputUSDPerToken: 6e-5),
        "gpt-5.6-sol": CodexBarModelPricing(inputUSDPerToken: 1e-5, cachedInputUSDPerToken: 1e-6, outputUSDPerToken: 6e-5),
        "gpt-5.6-terra": CodexBarModelPricing(inputUSDPerToken: 5e-6, cachedInputUSDPerToken: 5e-7, outputUSDPerToken: 3e-5),
        "gpt-5.6-luna": CodexBarModelPricing(inputUSDPerToken: 2e-6, cachedInputUSDPerToken: 2e-7, outputUSDPerToken: 1.2e-5),
        "gpt-6-astra": CodexBarModelPricing(
            inputUSDPerToken: 2e-5, cachedInputUSDPerToken: 2e-6, outputUSDPerToken: 1e-4
        ),
    ]

    static func defaultPricing(for model: String) -> CodexBarModelPricing? {
        let normalizedModel = self.normalizedModelID(model)
        if let pricing = self.defaultPricingByModel[normalizedModel] {
            return pricing
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
        sessionUsage _: SessionLogStore.Usage? = nil,
        serviceTier: SessionLogStore.ServiceTier = .unknown,
        customPricingByModel: [String: CodexBarModelPricing] = [:],
        forceLongContextPremium: Bool? = nil,
        forcePriorityPricing: Bool? = nil
    ) -> Double {
        let normalizedModel = self.normalizedModelID(model)
        let input = max(0, usage.inputTokens)
        let cached = min(max(0, usage.cachedInputTokens), input)
        let billableInput = input - cached
        let customPricing = customPricingByModel[normalizedModel]
            ?? customPricingByModel.first(where: {
                self.normalizedModelID($0.key) == normalizedModel
            })?.value
        let priorityPricing: CodexBarModelPricing? = if let forcePriorityPricing {
            forcePriorityPricing ? self.priorityPricingByModel[normalizedModel] : nil
        } else {
            self.priorityPricing(
                for: normalizedModel,
                serviceTier: serviceTier,
                inputTokens: input
            )
        }
        let pricing = customPricing
            ?? priorityPricing
            ?? self.effectivePricing(for: normalizedModel)
        let usesLongContextPremium = forceLongContextPremium ?? self.usesLongContextPremium(
            model: normalizedModel,
            usage: usage
        )
        let longContextRateMultiplier = usesLongContextPremium && customPricing == nil &&
            (priorityPricing == nil || normalizedModel == "gpt-6-astra")
        ? 2.0
        : 1.0
        let outputRateMultiplier = longContextRateMultiplier > 1 ? 1.5 : 1.0

        return Double(billableInput) * pricing.inputUSDPerToken * longContextRateMultiplier +
            Double(cached) * pricing.cachedInputUSDPerToken * longContextRateMultiplier +
            Double(max(0, usage.outputTokens)) * pricing.outputUSDPerToken * outputRateMultiplier
    }

    private static func priorityPricing(
        for model: String,
        serviceTier: SessionLogStore.ServiceTier,
        inputTokens: Int
    ) -> CodexBarModelPricing? {
        guard serviceTier == .priority,
              inputTokens <= self.longContextInputThreshold || model == "gpt-6-astra" else {
            return nil
        }
        return self.priorityPricingByModel[model]
    }

    private static func normalizedModelID(_ model: String) -> String {
        var trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }
        if trimmed == "gpt-5.6" {
            return "gpt-5.6-sol"
        }
        if trimmed == "gpt-6" {
            return "gpt-6-astra"
        }
        if let datedSuffix = trimmed.range(
            of: #"-\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if base == "gpt-6" {
                return "gpt-6-astra"
            }
            if self.defaultPricingByModel[base] != nil {
                return base
            }
        }
        return trimmed
    }

    static func usesLongContextPremium(
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

        let model = self.normalizedModelID(model)
        return self.longContextPremiumBaseModels.contains { base in
            model == base || self.modelID(model, isVariantOf: base)
        }
    }

    static func usesPriorityPricing(
        model: String,
        serviceTier: SessionLogStore.ServiceTier,
        usage: SessionLogStore.Usage
    ) -> Bool {
        let normalizedModel = self.normalizedModelID(model)
        return self.priorityPricing(
            for: normalizedModel,
            serviceTier: serviceTier,
            inputTokens: max(0, usage.inputTokens)
        ) != nil
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
    /// True when every discovered session was parsed without warnings.
    let isComplete: Bool
    /// True when the summary is backed by a safely persisted ledger.
    let isUsable: Bool
}

struct LocalCostSummaryService: @unchecked Sendable {
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
    private let useIncrementalIndex: Bool

    init(
        sessionLogStore: SessionLogStore,
        calendar: Calendar = .current,
        useIncrementalIndex: Bool = false
    ) {
        self.sessionLogStoreProvider = { sessionLogStore }
        self.calendar = calendar
        self.useIncrementalIndex = useIncrementalIndex
    }

    init(
        sessionLogStoreProvider: @escaping () -> SessionLogStore = { .shared },
        calendar: Calendar = .current,
        useIncrementalIndex: Bool = true
    ) {
        self.sessionLogStoreProvider = sessionLogStoreProvider
        self.calendar = calendar
        self.useIncrementalIndex = useIncrementalIndex
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
        if self.useIncrementalIndex,
           let indexed = self.readIncrementalIndexSummary(
               sessionLogStore: sessionLogStore,
               now: now,
               modelPricingOverrides: modelPricingOverrides
           ),
           indexed.isUsable {
            return indexed
        }

        return self.loadLegacySummary(
            sessionLogStore: sessionLogStore,
            now: now,
            modelPricingOverrides: modelPricingOverrides,
            refreshSessionCache: refreshSessionCache
        )
    }

    func refreshWithStatus(
        strength: LocalCostRefreshStrength = .incremental,
        now: Date = Date(),
        modelPricingOverrides: [String: CodexBarModelPricing] = [:],
        progressHandler: LocalCostIncrementalScanner.ProgressHandler? = nil
    ) -> LocalCostRefreshOutcome {
        if self.useIncrementalIndex {
            do {
                return try self.refreshIncrementalIndex(
                    strength: strength,
                    now: now,
                    modelPricingOverrides: modelPricingOverrides,
                    progressHandler: progressHandler
                )
            } catch {
                let legacy = self.loadLegacySummary(
                    sessionLogStore: self.sessionLogStoreProvider(),
                    now: now,
                    modelPricingOverrides: modelPricingOverrides,
                    refreshSessionCache: false
                )
                return LocalCostRefreshOutcome(
                    summary: legacy.summary,
                    isComplete: false,
                    mayReplaceLastKnownGood: false,
                    warningCount: 1,
                    lastRawSessionScanAt: nil,
                    latestUsageEventAt: legacy.summary.dailyEntries.first?.date,
                    progress: .zero,
                    errorMessage: error.localizedDescription
                )
            }
        }

        let legacy = self.loadLegacySummary(
            sessionLogStore: self.sessionLogStoreProvider(),
            now: now,
            modelPricingOverrides: modelPricingOverrides,
            refreshSessionCache: strength != .snapshotOnly
        )
        return LocalCostRefreshOutcome(
            summary: legacy.summary,
            isComplete: legacy.isComplete,
            mayReplaceLastKnownGood: legacy.isUsable,
            warningCount: legacy.isComplete ? 0 : 1,
            lastRawSessionScanAt: legacy.summary.updatedAt,
            latestUsageEventAt: legacy.summary.dailyEntries.first?.date,
            progress: .zero,
            errorMessage: nil
        )
    }

    private func refreshIncrementalIndex(
        strength: LocalCostRefreshStrength,
        now: Date,
        modelPricingOverrides: [String: CodexBarModelPricing],
        progressHandler: LocalCostIncrementalScanner.ProgressHandler?
    ) throws -> LocalCostRefreshOutcome {
        let sessionLogStore = self.sessionLogStoreProvider()
        let store = try LocalCostIndexStore(
            databaseURL: sessionLogStore.costUsageIndexURL,
            calendar: self.calendar
        )
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: sessionLogStore.costIndexCodexRootURL,
            store: store
        )
        let budget: LocalCostScanBudget
        switch strength {
        case .snapshotOnly:
            budget = .interactive
        case .incremental:
            budget = .accelerated
        case .rebuildAll:
            budget = .unbounded
        }
        let scan = try scanner.scan(
            budget: budget,
            forceRebuild: strength == .rebuildAll,
            progressHandler: progressHandler
        )
        let indexed = try store.summary(now: now, modelPricingOverrides: modelPricingOverrides)
        return LocalCostRefreshOutcome(
            summary: indexed.summary,
            isComplete: scan.progress.state == .idle,
            mayReplaceLastKnownGood: scan.progress.state == .idle,
            warningCount: scan.progress.state == .idle ? 0 : 1,
            lastRawSessionScanAt: scan.progress.lastSuccessfulScanAt,
            latestUsageEventAt: scan.progress.latestUsageEventAt,
            progress: LocalCostRefreshProgress(
                processedBytes: scan.progress.processedBytes,
                totalBytes: scan.progress.totalBytes,
                completedFiles: scan.progress.completedFiles,
                totalFiles: scan.progress.totalFiles
            ),
            errorMessage: nil
        )
    }

    private func readIncrementalIndexSummary(
        sessionLogStore: SessionLogStore,
        now: Date,
        modelPricingOverrides: [String: CodexBarModelPricing]
    ) -> LocalCostSummaryLoadResult? {
        do {
            let store = try LocalCostIndexStore(
                databaseURL: sessionLogStore.costUsageIndexURL,
                calendar: self.calendar
            )
            let indexed = try store.summary(
                now: now,
                modelPricingOverrides: modelPricingOverrides
            )
            return LocalCostSummaryLoadResult(
                summary: indexed.summary,
                isComplete: indexed.progress.state == .idle,
                isUsable: indexed.isUsable
            )
        } catch {
            return nil
        }
    }

    private func loadLegacySummary(
        sessionLogStore: SessionLogStore,
        now: Date,
        modelPricingOverrides: [String: CodexBarModelPricing],
        refreshSessionCache: Bool
    ) -> LocalCostSummaryLoadResult {
        let todayStart = self.calendar.startOfDay(for: now)
        let last30Start = self.calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        let reduction = sessionLogStore.reduceBillableEventsWithStatus(
            into: SummaryAccumulator(),
            refreshSessionCache: refreshSessionCache,
            costCalculator: { model, serviceTier, usage, sessionUsage in
                LocalCostPricing.costUSD(
                    model: model,
                    usage: usage,
                    sessionUsage: sessionUsage,
                    serviceTier: serviceTier,
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
            isComplete: reduction.isComplete,
            isUsable: reduction.isUsable
        )
    }
}
