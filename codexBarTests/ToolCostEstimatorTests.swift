import Foundation
import XCTest

final class ToolCostEstimatorTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_812_800)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testClaudePricesDisjointInputOutputAndCacheBuckets() throws {
        let record = ToolUsageRecord(id: "opus", timestamp: date, modelID: "claude-opus-4-7",
            inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000,
            cacheWriteTokens: 1_000_000, totalTokens: 4_000_000)
        XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(record)), 36.75, accuracy: 0.000001)
        let snapshot = ToolCostEstimator.reprice(makeSnapshot(.claudeCode, [record]), calendar: calendar)
        XCTAssertEqual(snapshot.usageRecords[0].costEvidence, .estimated)
        XCTAssertEqual(snapshot.dailyEntries[0].costUSD, 36.75)
        XCTAssertNil(snapshot.usageRecords[0].billedCostUSD)
    }

    func testClaudeOpus55AndSonnet55UsePublishedRates() throws {
        let opus = ToolUsageRecord(id: "opus-55", timestamp: date, modelID: "claude-opus-5-5-20250922",
            inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000,
            cacheWriteTokens: 1_000_000, totalTokens: 4_000_000)
        XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(opus)), 29.2, accuracy: 0.000001)
        let sonnet = ToolUsageRecord(id: "sonnet-55", timestamp: date, modelID: "claude-sonnet-5-5",
            inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000,
            cacheWriteTokens: 1_000_000, totalTokens: 4_000_000)
        XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(sonnet)), 14.6, accuracy: 0.000001)
    }

    func testAntigravityClaudeThinkingAndEffortAliasesUseSameModelRates() throws {
        for (alias, expected) in [
            ("claude-opus-4-6-thinking", 30.5),
            ("claude-opus-5-5-medium", 24.2),
            ("claude-opus-5-5-high", 24.2),
        ] {
            let record = ToolUsageRecord(id: alias, timestamp: date, modelID: alias,
                inputTokens: 1_000_000, outputTokens: 1_000_000,
                cacheReadTokens: 1_000_000, totalTokens: 3_000_000)
            XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(record)), expected, accuracy: 0.000001)
        }
        XCTAssertNil(ToolCostEstimator.estimate(record("claude-opus-5-5-unknown-variant", cost: nil)))
    }

    func testGeminiTokenValuationUsesPublishedPaidRatesAndExactServingAliases() throws {
        let october = ISO8601Parsing.parse("2026-10-20T00:00:00Z")!
        for (model, expected) in [
            ("gemini-4-argon", 12.1),
            ("gemini-3.8-flash", 4.575),
            ("gemini-3.8-flash-n", 4.575),
            ("gemini-3.6-flash", 4.575),
        ] {
            let record = ToolUsageRecord(id: model, timestamp: date, modelID: model,
                inputTokens: 1_000_000, outputTokens: 1_000_000,
                cacheReadTokens: 1_000_000, totalTokens: 3_000_000)
            XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(record, pricingDate: october)), expected, accuracy: 0.000001)
            let result = ToolCostEstimator.reprice(makeSnapshot(.antigravity, [record]), calendar: calendar, pricingDate: october)
            XCTAssertEqual(result.usageRecords[0].costEvidence, .estimated)
            XCTAssertNil(result.usageRecords[0].billedCostUSD, "API equivalent value is not the Antigravity subscription bill")
        }
        XCTAssertNil(ToolCostEstimator.estimate(record("gemini-3.8-flash-unknown", cost: nil), pricingDate: october))
        XCTAssertNil(ToolCostEstimator.estimate(record("gemini-future-flash-n", cost: nil), pricingDate: october))
        XCTAssertNil(ToolCostEstimator.estimate(record("gemini-4-argon-trial", cost: nil), pricingDate: october),
                     "No verified pricing equivalence exists for this internal serving variant")
        let writes = ToolUsageRecord(id: "storage", timestamp: date, modelID: "gemini-3.8-flash",
            cacheWriteTokens: 100, totalTokens: 100)
        XCTAssertNil(ToolCostEstimator.estimate(writes, pricingDate: october), "Storage duration is unavailable")
    }

    func testGeminiPublishedIntroductoryPriceBoundaries() throws {
        let argon = record("gemini-4-argon", cost: nil)
        let flash = record("gemini-3.8-flash-n", cost: nil)
        for (value, boundary, before, after) in [
            (argon, "2026-12-01T00:00:00Z", 2.0, 4.0),
            (flash, "2027-01-01T00:00:00Z", 0.75, 1.5),
        ] {
            let transition = ISO8601Parsing.parse(boundary)!
            XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(value, pricingDate: transition.addingTimeInterval(-1))),
                           before, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(value, pricingDate: transition)),
                           after, accuracy: 0.000001)
        }
    }

    func testAntigravityPartialPricingKeepsUnmappedAndMissingModelsUnknown() throws {
        let october = ISO8601Parsing.parse("2026-10-20T00:00:00Z")!
        let records = [
            record("claude-opus-5-5-medium", cost: nil),
            record("gemini-3.8-flash-n", cost: nil),
            record("gemini-4-argon-trial", cost: nil),
            ToolUsageRecord(id: "old-regeneration", timestamp: date, inputTokens: 100, totalTokens: 100),
        ]
        let snapshot = ToolCostEstimator.reprice(makeSnapshot(.antigravity, records),
                                                 calendar: calendar, pricingDate: october)
        XCTAssertEqual(snapshot.usageRecords.map(\.costUSD), [4, 0.75, nil, nil])
        XCTAssertNil(snapshot.dailyEntries[0].costUSD)
        XCTAssertEqual(snapshot.dailyEntries[0].knownCostUSD, 4.75)
        XCTAssertEqual(snapshot.dailyEntries[0].costEvidence, .estimated)
        XCTAssertNil(snapshot.dailyEntries[0].billedCostUSD)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 3_000_100)
        XCTAssertEqual(ToolCostEstimator.reprice(snapshot, calendar: calendar, pricingDate: october), snapshot)
    }

    func testDeepSeekAliasesUseCacheHitRateInsteadOfFullInputRate() throws {
        for model in ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek/deepseek-v4.1-flash"] {
            let record = ToolUsageRecord(id: model, timestamp: date, modelID: model,
                inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000, totalTokens: 3_000_000)
            XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(record)), 1.506, accuracy: 0.000001, model)
        }
    }

    func testKnownFreeDSHModelWithoutReportedCostHasCompleteZeroEstimate() throws {
        let free = record("deepseek-v4.1-flash-free", cost: nil)
        let paid = record("deepseek-flash", cost: nil)
        let result = ToolCostEstimator.reprice(makeSnapshot(.deepSeekHarness, [free, paid]), calendar: calendar)
        XCTAssertEqual(result.usageRecords[0].costUSD, 0)
        XCTAssertEqual(result.usageRecords[0].costEvidence, .estimated)
        XCTAssertEqual(try XCTUnwrap(result.dailyEntries[0].costUSD), 0.3, accuracy: 0.000001)
        XCTAssertEqual(ToolCostEstimator.reprice(result, calendar: calendar), result)
        XCTAssertNil(ToolCostEstimator.reprice(
            makeSnapshot(.deepSeekHarness, [record("custom-unknown-free", cost: nil)]), calendar: calendar
        ).usageRecords[0].costUSD)
    }

    func testOneHourCacheWriteSubsetUsesTwoTimesInputRateWithoutAddingTokens() throws {
        let record = ToolUsageRecord(id: "one-hour", timestamp: date, modelID: "claude-opus-5-5",
            inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000,
            cacheWriteTokens: 1_000_000, cacheWriteOneHourTokens: 750_000, totalTokens: 4_000_000)
        XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(record)), 31.45, accuracy: 0.000001)
        let invalid = ToolUsageRecord(id: "invalid-one-hour", timestamp: date, modelID: "claude-opus-5-5",
            cacheWriteTokens: 100, cacheWriteOneHourTokens: 101, totalTokens: 100)
        XCTAssertNil(ToolCostEstimator.estimate(invalid))
    }

    func testOpenCodeUnpricedZeroIsEstimatedButExplicitFreeAndReportedCostsArePreserved() throws {
        let records = [
            record("mimo-v2.5-pro", cost: 0),
            record("deepseek-v4-flash-free", cost: 0),
            record("unknown-model", cost: 0),
            record("unknown-reported", cost: 1.25),
        ]
        let result = ToolCostEstimator.reprice(makeSnapshot(.openCode, records), calendar: calendar)
        XCTAssertEqual(result.usageRecords[0].costUSD ?? 0, 0.435, accuracy: 0.000001)
        XCTAssertEqual(result.usageRecords[0].costEvidence, .estimated)
        XCTAssertEqual(result.usageRecords[1].costUSD, 0)
        XCTAssertNil(result.usageRecords[2].costUSD)
        XCTAssertEqual(result.usageRecords[3].costUSD, 1.25)
        XCTAssertEqual(result.usageRecords[3].costEvidence, .reported)
        XCTAssertNil(result.dailyEntries[0].costUSD)
        XCTAssertEqual(result.dailyEntries[0].knownCostUSD ?? 0, 1.685, accuracy: 0.000001)
        XCTAssertEqual(result.dailyEntries[0].totalTokens, 4_000_000)
        XCTAssertEqual(ToolCostEstimator.reprice(result, calendar: calendar), result)
    }

    func testReportedZeroUsageValueIsDistinctFromZeroBill() {
        let reported = ToolUsageRecord(id: "free-request", timestamp: date, modelID: "claude-opus-4-7",
            inputTokens: 1_000_000, totalTokens: 1_000_000, costUSD: 0, costEvidence: .reported, billedCostUSD: 0)
        let included = ToolUsageRecord(id: "included-request", timestamp: date, modelID: "claude-opus-4-7",
            inputTokens: 1_000_000, totalTokens: 1_000_000, billedCostUSD: 0)
        let result = ToolCostEstimator.reprice(makeSnapshot(.cursor, [reported, included]), calendar: calendar)
        XCTAssertEqual(result.usageRecords.map(\.costUSD), [0, 5])
        XCTAssertEqual(result.dailyEntries[0].costUSD, 5)
        XCTAssertEqual(result.dailyEntries[0].billedCostUSD, 0)
    }

    func testOpenCodeMiMoFreeAliasRepairsAlreadyCachedUnknownCost() {
        let snapshot = makeSnapshot(.openCode, [
            record("deepseek-v4.1-flash-free", cost: 0),
            record("mimo-v2.6-flash-free", cost: nil),
        ])
        let result = ToolCostEstimator.reprice(snapshot, calendar: calendar)
        XCTAssertEqual(result.usageRecords.map(\.costUSD), [0, 0])
        XCTAssertEqual(result.dailyEntries.first?.costUSD, 0)
        XCTAssertEqual(result.dailyEntries.first?.knownCostUSD, 0)
        XCTAssertNil(ToolCostEstimator.reprice(
            makeSnapshot(.openCode, [record("unverified-mimo-free", cost: 0)]), calendar: calendar
        ).usageRecords.first?.costUSD)
    }

    func testUnknownModelOrIncompleteTokenSplitIsNotFabricated() {
        XCTAssertNil(ToolCostEstimator.estimate(record("claude-opus-999", cost: nil)))
        let totalOnly = ToolUsageRecord(id: "csv", timestamp: date, modelID: "claude-opus-4-7", totalTokens: 200)
        XCTAssertNil(ToolCostEstimator.estimate(totalOnly))
        let partial = ToolUsageRecord(id: "partial", timestamp: date, modelID: "claude-opus-4-7", inputTokens: 10, totalTokens: 200)
        XCTAssertNil(ToolCostEstimator.estimate(partial))
    }

    func testCacheMigrationRetainsOldDailyOnlyHistoryAndDecodesAbsentNewFields() throws {
        let old = #"{"client":"openCode","availability":"ready","evidence":"reported","dailyEntries":[{"date":0,"inputTokens":10,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":10,"costUSD":0}],"usageRecords":[{"id":"old","timestamp":0,"modelID":"mimo-v2.5-pro","inputTokens":10,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":10,"costUSD":0}]}"#
        let decoded = try JSONDecoder().decode(ToolUsageSnapshot.self, from: Data(old.utf8))
        let migrated = ToolCostEstimator.reprice(decoded, calendar: calendar)
        XCTAssertEqual(migrated.usageRecords[0].costEvidence, .estimated)
        XCTAssertGreaterThan(migrated.dailyEntries[0].costUSD ?? 0, 0)
        let dayOnly = ToolUsageSnapshot(client: .cursor, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: date, totalTokens: 2_000_000, costUSD: 1.8)],
            usageRecords: [record("mimo-v2.5-pro", cost: 0)])
        let preserved = ToolCostEstimator.reprice(dayOnly, calendar: calendar)
        XCTAssertEqual(preserved.dailyEntries, dayOnly.dailyEntries)
    }

    private func record(_ model: String, cost: Double?) -> ToolUsageRecord {
        ToolUsageRecord(id: model, timestamp: date, modelID: model,
            inputTokens: 1_000_000, totalTokens: 1_000_000, costUSD: cost)
    }

    private func makeSnapshot(_ client: ToolUsageClient, _ records: [ToolUsageRecord]) -> ToolUsageSnapshot {
        ToolUsageSnapshot(client: client, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: calendar.startOfDay(for: date),
                totalTokens: records.reduce(0) { $0 + $1.totalTokens })], usageRecords: records)
    }
}
