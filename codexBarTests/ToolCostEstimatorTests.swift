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

    func testDeepSeekAliasesUseCacheHitRateInsteadOfFullInputRate() throws {
        for model in ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek/deepseek-v4.1-flash"] {
            let record = ToolUsageRecord(id: model, timestamp: date, modelID: model,
                inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000, totalTokens: 3_000_000)
            XCTAssertEqual(try XCTUnwrap(ToolCostEstimator.estimate(record)), 1.506, accuracy: 0.000001, model)
        }
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
