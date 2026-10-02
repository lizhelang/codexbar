import Foundation
import XCTest
@testable import codexbar

@MainActor
final class ToolQuotaStoreTests: XCTestCase {
    func testQuotaWorkRunsOffMainAndRefreshIsThrottledAndCoalesced() async throws {
        let folder = try self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = QuotaStoreFixtureFetcher()
        let store = ToolUsageStore(collectors: [], quotaFetcher: fetcher, cacheURL: folder.appendingPathComponent("usage.json"))
        let now = Date()
        store.refreshQuotasIfNeeded(now: now)
        store.refreshQuotasIfNeeded(force: true, now: now)
        store.refreshQuotasIfNeeded(force: true, now: now)
        try await self.waitUntil { !store.isRefreshingQuotas }
        let firstCalls = await fetcher.callCount
        let usedMainThread = await fetcher.usedMainThread
        XCTAssertEqual(firstCalls, 8, "Overlapping forced refreshes coalesce into one follow-up for the four clients")
        XCTAssertFalse(usedMainThread, "Credential and network work must never execute on the UI thread")
        XCTAssertEqual(store.quotaSnapshots.count, 4)
        store.refreshQuotasIfNeeded(now: now.addingTimeInterval(299))
        XCTAssertFalse(store.isRefreshingQuotas)
        let throttledCalls = await fetcher.callCount
        XCTAssertEqual(throttledCalls, firstCalls)
        store.refreshQuotasIfNeeded(now: now.addingTimeInterval(301))
        try await self.waitUntil { !store.isRefreshingQuotas }
        let laterCalls = await fetcher.callCount
        XCTAssertEqual(laterCalls, 12)
    }

    func testQuotaCacheLoadsOffInitialUIPathAndInvalidLargeCacheIsIgnored() async throws {
        let folder = try self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = ToolQuotaSnapshot(client: .claudeCode, status: .ready, providerName: "Claude",
            windows: [.init(id: "5h", label: "5 小时", usedPercent: 25)], refreshedAt: Date(), statusDetail: "Fixture")
        let url = folder.appendingPathComponent("tool-quota-summary.json")
        try JSONEncoder().encode([snapshot]).write(to: url)
        let store = ToolUsageStore(collectors: [], cacheURL: folder.appendingPathComponent("usage.json"))
        XCTAssertTrue(store.quotaSnapshots.isEmpty, "Initialization must not synchronously read/decode quota cache")
        try await self.waitUntil { store.quotaSnapshots[.claudeCode] != nil }
        XCTAssertEqual(store.quotaSnapshots[.claudeCode], snapshot)
        try Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1).write(to: url)
        let oversized = ToolUsageStore(collectors: [], cacheURL: folder.appendingPathComponent("other.json"))
        let fetcher = QuotaStoreFixtureFetcher()
        let control = ToolUsageStore(collectors: [], quotaFetcher: fetcher, cacheURL: folder.appendingPathComponent("control.json"))
        control.refreshQuotasIfNeeded(force: true)
        try await self.waitUntil { !control.isRefreshingQuotas }
        XCTAssertTrue(oversized.quotaSnapshots.isEmpty)
    }

    func testOldUsageCacheIsRepricedOffMainWithoutOverwritingNewImport() async throws {
        let folder = try self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Calendar.current.startOfDay(for: Date())
        let old = ToolUsageSnapshot(client: .claudeCode, availability: .ready,
            dailyEntries: [.init(date: date, inputTokens: 1_000_000, totalTokens: 1_000_000)],
            usageRecords: [.init(id: "old", timestamp: date, modelID: "claude-sonnet-4-6", inputTokens: 1_000_000, totalTokens: 1_000_000)])
        let oldCursor = ToolUsageSnapshot(client: .cursor, availability: .ready,
            dailyEntries: [.init(date: date, totalTokens: 20)])
        let url = folder.appendingPathComponent("usage.json")
        try JSONEncoder().encode([old, oldCursor]).write(to: url)
        let store = ToolUsageStore(collectors: [], cacheURL: url)
        XCTAssertTrue(store.snapshots.isEmpty, "Startup history repricing must not block the UI")
        let imported = ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .imported,
            dailyEntries: [.init(date: date, totalTokens: 99)])
        store.updateImportedCursor(imported)
        try await self.waitUntil { store.snapshots[.claudeCode] != nil }
        XCTAssertEqual(store.snapshots[.claudeCode]?.dailyEntries.first?.costUSD, 3)
        XCTAssertEqual(store.snapshots[.claudeCode]?.usageRecords.first?.costEvidence, .estimated)
        XCTAssertEqual(store.snapshots[.cursor], imported, "A late disk cache cannot replace the newer CSV import")
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-quota-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for the observed store state")
    }
}

private actor QuotaStoreFixtureFetcher: ToolQuotaFetching {
    private(set) var callCount = 0
    private(set) var usedMainThread = false
    func fetch(client: ToolUsageClient, preferences: ApplicationPreferences, now: Date) async -> ToolQuotaSnapshot {
        self.callCount += 1
        self.usedMainThread = self.usedMainThread || Thread.isMainThread
        try? await Task.sleep(for: .milliseconds(30))
        return ToolQuotaSnapshot(client: client, status: .ready, providerName: client.displayName,
            windows: [.init(id: "quota", label: "Test", usedPercent: 25)], refreshedAt: now, statusDetail: "Fixture")
    }
}
