import Foundation

/// API-equivalent usage value, not the user's subscription bill. Prices checked 2026-10-20.
/// Uses current standard rates for historical records; discounts and historical prices are not reconstructed.
nonisolated enum ToolCostEstimator {
    struct Rates: Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double

        init(_ input: Double, _ output: Double, _ cacheRead: Double, _ cacheWrite: Double) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    // USD per million tokens. Exact model aliases only: no price guessed from a family name.
    // https://platform.claude.com/docs/en/about-claude/pricing
    // https://api-docs.deepseek.com/quick_start/pricing (standard peak rates)
    // https://mimo.mi.com/docs/en-US/price/pay-as-you-go (overseas USD rates)
    // https://platform.minimax.io/subscribe/token-plan?tab=api-enterprise
    // https://ai.google.dev/gemini-api/docs/pricing (standard text token rates, including thinking)
    private static let rates: [String: Rates] = [
        "claude-opus-4-5": Rates(5, 25, 0.5, 6.25),
        "claude-opus-4-6": Rates(5, 25, 0.5, 6.25),
        "claude-opus-4-7": Rates(5, 25, 0.5, 6.25),
        "claude-opus-4-8": Rates(5, 25, 0.5, 6.25),
        "claude-opus-5": Rates(5, 25, 0.5, 6.25),
        // Opus 5.5 cache reads are 0.05x input, not the older 0.1x rate.
        "claude-opus-5-5": Rates(4, 20, 0.2, 5),
        "claude-opus-4": Rates(15, 75, 1.5, 18.75),
        "claude-opus-4-1": Rates(15, 75, 1.5, 18.75),
        "claude-sonnet-4": Rates(3, 15, 0.3, 3.75),
        "claude-sonnet-4-5": Rates(3, 15, 0.3, 3.75),
        "claude-sonnet-4-6": Rates(3, 15, 0.3, 3.75),
        "claude-sonnet-5": Rates(2, 10, 0.2, 2.5),
        "claude-sonnet-5-5": Rates(2, 10, 0.1, 2.5),
        "claude-haiku-4-5": Rates(1, 5, 0.1, 1.25),
        "claude-3-5-haiku": Rates(0.8, 4, 0.08, 1),
        "claude-fable-5": Rates(10, 50, 1, 12.5),
        "claude-fable-5-1": Rates(10, 50, 0.25, 12.5),
        "deepseek-flash": Rates(0.3, 1.2, 0.006, 0.3),
        "deepseek-v4.1-flash": Rates(0.3, 1.2, 0.006, 0.3),
        "deepseek-v4-flash": Rates(0.3, 1.2, 0.006, 0.3),
        "deepseek-v4-flash-vision-exp": Rates(0.3, 1.2, 0.006, 0.3),
        "deepseek-v4-pro": Rates(1.32, 3.96, 0.044, 1.32),
        "deepseek-v4-pro-0813": Rates(1.32, 3.96, 0.044, 1.32),
        "mimo-v2.5-pro": Rates(0.435, 0.87, 0.0036, 0),
        "mimo-v2.5": Rates(0.14, 0.28, 0.0028, 0),
        "mimo-v2.6-pro": Rates(0.435, 0.87, 0.0036, 0),
        "mimo-v2.6-flash": Rates(0.14, 0.28, 0.0028, 0),
        "minimax-m2.7": Rates(0.3, 1.2, 0.06, 0.375),
        "minimax-m2.7-highspeed": Rates(0.6, 2.4, 0.06, 0.375),
        "gemini-4-argon": Rates(2, 10, 0.1, 0),
        "gemini-3.8-flash": Rates(0.75, 3.75, 0.075, 0),
        "gemini-3.6-flash": Rates(0.75, 3.75, 0.075, 0),
    ]

    private static let claudeModelAliases = rates.keys.filter { $0.hasPrefix("claude-") }.sorted { $0.count > $1.count }

    static func estimate(_ record: ToolUsageRecord, pricingDate: Date = Date()) -> Double? {
        guard let model = record.modelID, !isExplicitlyFree(model) else { return nil }
        let normalized = normalizedModel(model)
        guard let rate = rate(for: normalized, on: pricingDate) else { return nil }
        let tokens = [record.inputTokens, record.outputTokens, record.cacheReadTokens, record.cacheWriteTokens]
        guard tokens.allSatisfy({ $0 >= 0 }), record.totalTokens >= 0 else { return nil }
        let oneHourWrites = record.cacheWriteOneHourTokens ?? 0
        guard oneHourWrites >= 0, oneHourWrites <= record.cacheWriteTokens,
              oneHourWrites == 0 || normalized.hasPrefix("claude-") else { return nil }
        // Gemini's explicit cache storage is billed by duration, which these counters
        // do not record. Argon supports implicit caching only. Never price writes as free.
        guard !normalized.hasPrefix("gemini-") || record.cacheWriteTokens == 0 else { return nil }
        // A CSV may contain only a total. Unknown input/output splits cannot be priced safely.
        let covered = tokens.reduce(0.0) { $0 + Double($1) }
        guard covered > 0, covered == Double(record.totalTokens) else { return nil }
        let value = (Double(record.inputTokens) * rate.input + Double(record.outputTokens) * rate.output
                     + Double(record.cacheReadTokens) * rate.cacheRead
                     + Double(record.cacheWriteTokens - oneHourWrites) * rate.cacheWrite
                     + Double(oneHourWrites) * rate.input * 2) / 1_000_000
        return value.isFinite ? value : nil
    }

    static func reprice(
        _ snapshot: ToolUsageSnapshot, calendar: Calendar = .current, pricingDate: Date = Date()
    ) -> ToolUsageSnapshot {
        guard !snapshot.usageRecords.isEmpty else { return snapshot }
        let records = snapshot.usageRecords.map { record in
            let value = usageValue(record, pricingDate: pricingDate)
            return ToolUsageRecord(
                id: record.id, timestamp: record.timestamp, modelID: record.modelID, sessionID: record.sessionID,
                sessionTitle: record.sessionTitle, projectPath: record.projectPath,
                sessionIsRunning: record.sessionIsRunning, contextWindowTokens: record.contextWindowTokens,
                contextUsedTokens: record.contextUsedTokens, inputTokens: record.inputTokens,
                outputTokens: record.outputTokens, cacheReadTokens: record.cacheReadTokens,
                cacheWriteTokens: record.cacheWriteTokens, cacheWriteOneHourTokens: record.cacheWriteOneHourTokens,
                totalTokens: record.totalTokens,
                costUSD: value.cost, costEvidence: value.evidence, billedCostUSD: record.billedCostUSD
            )
        }
        struct Day {
            var tokens = 0.0
            var known = 0.0
            var hasKnown = false
            var complete = true
            var estimated = false
            var billed = 0.0
            var billingComplete = true
        }
        var days: [Date: Day] = [:]
        for record in records {
            let date = calendar.startOfDay(for: record.timestamp)
            var day = days[date, default: Day()]
            day.tokens += Double(max(0, record.totalTokens))
            if let value = valid(record.costUSD) {
                day.known += value
                day.hasKnown = true
            } else { day.complete = false }
            day.estimated = day.estimated || record.costEvidence == .estimated
            if let billed = valid(record.billedCostUSD) { day.billed += billed }
            else { day.billingComplete = false }
            days[date] = day
        }
        let entries = snapshot.dailyEntries.map { entry in
            // Do not discard older daily-only history or claim completeness for a partial record set.
            guard let day = days[calendar.startOfDay(for: entry.date)], day.tokens == Double(entry.totalTokens) else { return entry }
            let known = day.hasKnown && day.known.isFinite ? day.known : nil
            return ToolUsageDailyEntry(
                date: entry.date, inputTokens: entry.inputTokens, outputTokens: entry.outputTokens,
                cacheReadTokens: entry.cacheReadTokens, cacheWriteTokens: entry.cacheWriteTokens,
                totalTokens: entry.totalTokens, costUSD: day.complete ? known : nil, knownCostUSD: known,
                costEvidence: known == nil ? nil : (day.estimated ? .estimated : .reported),
                billedCostUSD: day.billingComplete && day.billed.isFinite ? day.billed : nil
            )
        }
        return ToolUsageSnapshot(client: snapshot.client, availability: snapshot.availability, evidence: snapshot.evidence,
            dailyEntries: entries, usageRecords: records, latestUsageAt: snapshot.latestUsageAt,
            refreshedAt: snapshot.refreshedAt, statusDetail: snapshot.statusDetail)
    }

    private static func usageValue(
        _ record: ToolUsageRecord, pricingDate: Date
    ) -> (cost: Double?, evidence: ToolCostEvidence?) {
        if let value = valid(record.costUSD), value > 0, record.costEvidence != .estimated {
            return (value, .reported)
        }
        if record.costUSD == 0,
           record.costEvidence == .reported
            || (record.modelID.map(isExplicitlyFree) == true && record.costEvidence != .estimated) {
            return (0, .reported)
        }
        if record.modelID.map(isExplicitlyFree) == true {
            // DSH persists token usage without a cost field even for explicitly free models.
            return (0, .estimated)
        }
        if let estimated = estimate(record, pricingDate: pricingDate) { return (estimated, .estimated) }
        // Legacy zeroes in OpenCode meant unpriced custom models; Cursor zeroes meant no extra bill.
        // Keep genuine explicit zero usage values, but never guess zero for an unknown model.
        if let value = valid(record.costUSD), value > 0 { return (value, record.costEvidence) }
        return (nil, nil)
    }

    private static func valid(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    static func isExplicitlyFree(_ raw: String) -> Bool {
        let model = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // OpenRouter's explicit :free route and known OpenCode free model IDs.
        // An arbitrary custom model merely ending in "-free" is not pricing evidence.
        if model.hasSuffix(":free") { return true }
        let name = model.split(separator: "/").last.map(String.init) ?? model
        return ["big-pickle", "deepseek-v4-flash-free", "deepseek-v4.1-flash-free",
                "minimax-m2.5-free", "nemotron-3-super-free", "mimo-v2.6-flash-free"].contains(name)
    }

    private static func rate(for model: String, on date: Date) -> Rates? {
        guard let standard = rates[model] else { return nil }
        // Published introductory rates double on these announced dates. This keeps
        // the existing current-list-price valuation policy, including for older usage.
        let introductoryEnd: TimeInterval?
        switch model {
        case "gemini-4-argon": introductoryEnd = 1_796_083_200 // 2026-12-01 00:00 UTC
        case "gemini-3.6-flash", "gemini-3.8-flash": introductoryEnd = 1_798_761_600 // 2027-01-01 00:00 UTC
        default: introductoryEnd = nil
        }
        guard let introductoryEnd, date.timeIntervalSince1970 >= introductoryEnd else { return standard }
        return Rates(standard.input * 2, standard.output * 2, standard.cacheRead * 2, standard.cacheWrite * 2)
    }

    private static func normalizedModel(_ raw: String) -> String {
        var model = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for provider in ["anthropic/", "deepseek/", "xiaomi/", "minimax/"] where model.hasPrefix(provider) {
            model.removeFirst(provider.count)
            break
        }
        // Exact serving alias observed in Antigravity and independently covered by
        // https://github.com/JingbiaoMei/Tokdash/blob/main/src/tokdash/pricing_db.json
        if model == "gemini-3.8-flash-n" { return "gemini-3.8-flash" }
        if model.hasPrefix("claude-") {
            model = model.replacingOccurrences(of: ".", with: "-")
            // Provider snapshots and Cursor effort suffixes retain the same model's standard price.
            for candidate in claudeModelAliases {
                guard model.hasPrefix(candidate + "-") else { continue }
                let suffix = String(model.dropFirst(candidate.count + 1))
                if ["thinking", "low", "medium", "high"].contains(suffix)
                    || suffix.hasPrefix("thinking-") || (suffix.count == 8 && suffix.allSatisfy(\.isNumber)) { return candidate }
            }
            if model == "claude-4-6-sonnet-medium-thinking" { return "claude-sonnet-4-6" }
        }
        return model
    }
}
