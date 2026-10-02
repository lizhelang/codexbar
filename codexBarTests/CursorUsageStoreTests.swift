import Foundation
import Combine
import XCTest
@testable import codexbar

@MainActor
final class CursorUsageStoreTests: XCTestCase {
    func testFailedAutoSyncKeepsImportedCSV() async throws {
        let now = Date(timeIntervalSince1970: 1_782_900_000)
        let imported = ToolUsageSnapshot(
            client: .cursor, availability: .ready, evidence: .imported,
            dailyEntries: [ToolUsageDailyEntry(date: now, totalTokens: 70)],
            usageRecords: [ToolUsageRecord(id: "row", timestamp: now, modelID: "claude-sonnet", totalTokens: 70)],
            latestUsageAt: now, refreshedAt: now, statusDetail: "Imported"
        )
        let store = self.makeStore(result: .failure(.networkFailure))
        store.updateImportedCursor(imported)
        store.refreshIfNeeded(force: true, now: now.addingTimeInterval(60))
        try await self.waitForRefresh(store)

        let snapshot = store.snapshot(for: .cursor)
        XCTAssertEqual(snapshot.availability, .failed)
        XCTAssertEqual(snapshot.evidence, .imported)
        XCTAssertEqual(snapshot.dailyEntries, imported.dailyEntries)
        XCTAssertEqual(snapshot.usageRecords, imported.usageRecords)
        XCTAssertEqual(snapshot.latestUsageAt, imported.latestUsageAt)
    }

    func testEmptyAutoSyncKeepsPriorUsageAndExplainsWhy() async throws {
        let now = Date(timeIntervalSince1970: 1_782_900_000)
        let imported = ToolUsageSnapshot(
            client: .cursor, availability: .ready, evidence: .imported,
            dailyEntries: [ToolUsageDailyEntry(date: now, totalTokens: 70)]
        )
        let empty = ToolUsageSnapshot(
            client: .cursor, availability: .noRecords, evidence: .server,
            refreshedAt: now, statusDetail: "Cursor 账号暂无 Token 用量记录"
        )
        let store = self.makeStore(result: .success(empty))
        store.updateImportedCursor(imported)
        store.refreshIfNeeded(force: true, now: now)
        try await self.waitForRefresh(store)

        let snapshot = store.snapshot(for: .cursor)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.evidence, .imported)
        XCTAssertEqual(snapshot.dailyEntries, imported.dailyEntries)
        XCTAssertTrue(snapshot.statusDetail?.contains("保留上次用量") == true)
    }

    func testEmptyAutoSyncWithoutPriorUsageShowsNoRecords() async throws {
        let now = Date(timeIntervalSince1970: 1_782_900_000)
        let empty = ToolUsageSnapshot(
            client: .cursor, availability: .noRecords, evidence: .server,
            refreshedAt: now, statusDetail: "Cursor 账号暂无 Token 用量记录"
        )
        let store = self.makeStore(result: .success(empty))
        store.refreshIfNeeded(force: true, now: now)
        try await self.waitForRefresh(store)
        XCTAssertEqual(store.snapshot(for: .cursor), empty)
    }

    func testDecodesOldAggregateOnlyCacheAndRoundTripsNewDetail() throws {
        let legacy = Data(#"{"client":"openCode","availability":"ready","evidence":"reported","dailyEntries":[{"date":0,"inputTokens":1,"outputTokens":2,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":3}]}"#.utf8)
        let old = try JSONDecoder().decode(ToolUsageSnapshot.self, from: legacy)
        XCTAssertTrue(old.usageRecords.isEmpty)
        XCTAssertEqual(old.dailyEntries.first?.totalTokens, 3)
        let detailed = ToolUsageSnapshot(client: .openCode, availability: .ready, dailyEntries: old.dailyEntries,
                                        usageRecords: [ToolUsageRecord(id: "record", timestamp: Date(timeIntervalSince1970: 0), modelID: "mimo", sessionID: "session", totalTokens: 3)])
        XCTAssertEqual(try JSONDecoder().decode(ToolUsageSnapshot.self, from: JSONEncoder().encode(detailed)), detailed)
    }

    func testRefreshPublishesAllSourcesOnceAndSkipsIdenticalSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_782_900_000)
        let cursor = ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .server,
                                       dailyEntries: [.init(date: now, totalTokens: 40)])
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-batch-test-\(UUID().uuidString)/summary.json")
        let store = ToolUsageStore(
            collectors: [BatchUsageFixture(client: .claudeCode), BatchUsageFixture(client: .openCode), BatchUsageFixture(client: .deepSeekHarness)],
            cursorSyncer: CursorStubSyncer(result: .success(cursor)), cacheURL: cache
        )
        var publications: [[ToolUsageClient: ToolUsageSnapshot]] = []
        let subscription = store.$snapshots.dropFirst().sink { publications.append($0) }
        defer { subscription.cancel() }
        store.refreshIfNeeded(force: true, now: now)
        try await self.waitForRefresh(store)
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.count, 4)
        store.refreshIfNeeded(force: true, now: now)
        try await self.waitForRefresh(store)
        XCTAssertEqual(publications.count, 1, "The same data should not trigger another projection of every dashboard page")
        XCTAssertEqual(store.snapshots.count, 4)
    }

    private func makeStore(result: Result<ToolUsageSnapshot, CursorUsageSyncError>) -> ToolUsageStore {
        ToolUsageStore(
            collectors: [],
            cursorSyncer: CursorStubSyncer(result: result),
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-cursor-store-test-\(UUID().uuidString)/summary.json")
        )
    }

    private func waitForRefresh(_ store: ToolUsageStore) async throws {
        for _ in 0..<100 {
            if !store.isRefreshing { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the fixture sync")
    }
}

private nonisolated struct CursorStubSyncer: CursorUsageSyncing {
    let result: Result<ToolUsageSnapshot, CursorUsageSyncError>

    func sync(now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        try self.result.get()
    }
}

private nonisolated struct BatchUsageFixture: ToolUsageCollecting {
    let client: ToolUsageClient
    func collect(now: Date, calendar: Calendar) -> ToolUsageSnapshot {
        ToolUsageSnapshot(client: self.client, availability: .ready, dailyEntries: [.init(date: now, totalTokens: 10)])
    }
}
