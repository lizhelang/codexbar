import Foundation
import XCTest

final class RecordsSnapshotServiceTests: XCTestCase {
    func testLoadCurrentReturnsCompleteSortedSnapshot() async throws {
        let loader = RecordsSourceSnapshotLoaderStub()
        await loader.setIncrementalSnapshot(
            RecordsSourceSnapshot(
            generatedAt: self.date("2026-04-21T10:00:00Z"),
            refreshMode: .incremental,
            sessions: [
                HistoricalSessionRecord(
                    sessionID: "session-b",
                    modelID: "gpt-5.4",
                    startedAt: self.date("2026-04-21T08:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T09:00:00Z"),
                    isArchived: false,
                    totalTokens: 230
                ),
                HistoricalSessionRecord(
                    sessionID: "session-a",
                    modelID: "google/gemini-2.5-pro",
                    startedAt: self.date("2026-04-21T07:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T11:00:00Z"),
                    isArchived: true,
                    totalTokens: 120
                ),
                HistoricalSessionRecord(
                    sessionID: "session-c",
                    modelID: "gpt-5.4",
                    startedAt: self.date("2026-04-21T06:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T09:00:00Z"),
                    isArchived: false,
                    totalTokens: 90
                ),
            ],
            warnings: [
                RecordsSnapshotWarning(
                    sessionFilePath: "/tmp/z.jsonl",
                    kind: .incompleteSessionRecord,
                    message: "missing usage"
                ),
                RecordsSnapshotWarning(
                    sessionFilePath: "/tmp/a.jsonl",
                    kind: .unreadableSessionFile,
                    message: "permission denied"
                ),
            ]
        )
        )
        let service = RecordsSnapshotService(sourceLoader: loader)

        let snapshot = try await service.loadCurrent()

        let recordedModes = await loader.recordedModes()
        XCTAssertEqual(recordedModes, [.incremental])
        XCTAssertEqual(snapshot.generatedAt, self.date("2026-04-21T10:00:00Z"))
        XCTAssertEqual(snapshot.refreshMode, .incremental)
        XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["session-a", "session-b", "session-c"])
        XCTAssertEqual(
            snapshot.models,
            [
                HistoricalModelRecord(
                    modelID: "google/gemini-2.5-pro",
                    sessionCount: 1,
                    lastSeenAt: self.date("2026-04-21T11:00:00Z")
                ),
                HistoricalModelRecord(
                    modelID: "gpt-5.4",
                    sessionCount: 2,
                    lastSeenAt: self.date("2026-04-21T09:00:00Z")
                ),
            ]
        )
        XCTAssertEqual(snapshot.warnings.map(\.sessionFilePath), ["/tmp/a.jsonl", "/tmp/z.jsonl"])
    }

    func testRefreshAllRequestsRebuildAndAggregatesModels() async throws {
        let loader = RecordsSourceSnapshotLoaderStub()
        await loader.setRebuildSnapshot(
            RecordsSourceSnapshot(
            generatedAt: self.date("2026-04-21T12:00:00Z"),
            refreshMode: .rebuildAll,
            sessions: [
                HistoricalSessionRecord(
                    sessionID: "session-1",
                    modelID: "gpt-5.4",
                    startedAt: self.date("2026-04-21T08:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T12:00:00Z"),
                    isArchived: false,
                    totalTokens: 300
                ),
                HistoricalSessionRecord(
                    sessionID: "session-2",
                    modelID: "gpt-5.4",
                    startedAt: self.date("2026-04-21T07:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T10:00:00Z"),
                    isArchived: true,
                    totalTokens: 140
                ),
            ],
            warnings: []
        )
        )
        let service = RecordsSnapshotService(sourceLoader: loader)

        let snapshot = try await service.refreshAll(timeout: 1)

        let recordedModes = await loader.recordedModes()
        XCTAssertEqual(recordedModes, [.rebuildAll])
        XCTAssertEqual(snapshot.refreshMode, .rebuildAll)
        XCTAssertEqual(snapshot.models.count, 1)
        XCTAssertEqual(snapshot.models[0].modelID, "gpt-5.4")
        XCTAssertEqual(snapshot.models[0].sessionCount, 2)
        XCTAssertEqual(snapshot.models[0].lastSeenAt, self.date("2026-04-21T12:00:00Z"))
    }

    func testRefreshAllTimesOutWhenLoaderDoesNotFinish() async {
        let loader = RecordsSourceSnapshotLoaderStub()
        await loader.setHangOnRebuild(true)
        let service = RecordsSnapshotService(sourceLoader: loader)

        do {
            _ = try await service.refreshAll(timeout: 0.01)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? RecordsSnapshotServiceError, .timedOut(timeout: 0.01))
        }
    }

    func testLoadCurrentPreservesSourceWarnings() async throws {
        let loader = RecordsSourceSnapshotLoaderStub()
        await loader.setIncrementalSnapshot(
            RecordsSourceSnapshot(
            generatedAt: self.date("2026-04-21T10:00:00Z"),
            refreshMode: .incremental,
            sessions: [],
            warnings: [
                RecordsSnapshotWarning(
                    sessionFilePath: "/tmp/problem.jsonl",
                    kind: .incompleteSessionRecord,
                    message: "missing model"
                ),
            ]
        )
        )
        let service = RecordsSnapshotService(sourceLoader: loader)

        let snapshot = try await service.loadCurrent()

        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertEqual(snapshot.warnings[0].sessionFilePath, "/tmp/problem.jsonl")
        XCTAssertEqual(snapshot.warnings[0].kind, .incompleteSessionRecord)
        XCTAssertEqual(snapshot.warnings[0].message, "missing model")
    }

    private func date(_ value: String) -> Date {
        ISO8601Parsing.parse(value) ?? Date(timeIntervalSince1970: 0)
    }
}

private actor RecordsSourceSnapshotLoaderStub: RecordsSourceSnapshotLoading {
    var incrementalSnapshot = RecordsSourceSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        refreshMode: .incremental,
        sessions: [],
        warnings: []
    )
    var rebuildSnapshot = RecordsSourceSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        refreshMode: .rebuildAll,
        sessions: [],
        warnings: []
    )
    var hangOnRebuild = false
    private(set) var recordedRefreshModes: [RecordsRefreshMode] = []

    func setIncrementalSnapshot(_ snapshot: RecordsSourceSnapshot) {
        self.incrementalSnapshot = snapshot
    }

    func setRebuildSnapshot(_ snapshot: RecordsSourceSnapshot) {
        self.rebuildSnapshot = snapshot
    }

    func setHangOnRebuild(_ value: Bool) {
        self.hangOnRebuild = value
    }

    func recordedModes() -> [RecordsRefreshMode] {
        self.recordedRefreshModes
    }

    func loadRecordsSourceSnapshot(refreshMode: RecordsRefreshMode) async throws -> RecordsSourceSnapshot {
        self.recordedRefreshModes.append(refreshMode)
        if refreshMode == .rebuildAll, self.hangOnRebuild {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        switch refreshMode {
        case .incremental:
            return self.incrementalSnapshot
        case .rebuildAll:
            return self.rebuildSnapshot
        }
    }
}
