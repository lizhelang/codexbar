import Foundation
import XCTest

@MainActor
final class SettingsRecordsViewModelTests: XCTestCase {
    func testPageDidAppearLoadsCurrentSnapshotWithoutForcingFullRefresh() async throws {
        let service = RecordsSnapshotServiceStub()
        await service.enqueueLoadCurrent(self.makeSnapshot(sessionID: "load-current", modelID: "gpt-5.4"))
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.pageDidAppear()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }

        let loadCurrentCallCount = await service.loadCurrentCount()
        let refreshAllCallCount = await service.refreshAllCount()
        XCTAssertEqual(loadCurrentCallCount, 1)
        XCTAssertEqual(refreshAllCallCount, 0)
        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["load-current"])
        XCTAssertFalse(viewModel.isRefreshingAll)
    }

    func testLatestRequestTokenWinsWhenRefreshOverridesInFlightLoad() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) {
            let count = await service.loadCurrentCount()
            return count == 1
        }

        viewModel.refreshAll(timeout: 1)
        try await self.waitUntil(timeout: 1) {
            let count = await service.refreshAllCount()
            return count == 1
        }

        await service.resumeRefreshAll(
            with: .success(self.makeSnapshot(sessionID: "refresh", modelID: "gpt-5.4"))
        )
        try await self.waitUntil(timeout: 1) { viewModel.snapshot?.sessions.first?.sessionID == "refresh" }

        await service.resumeLoadCurrent(
            with: .success(self.makeSnapshot(sessionID: "stale-load", modelID: "gpt-5.4-mini"))
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["refresh"])
        XCTAssertFalse(viewModel.isRefreshingAll)
        XCTAssertFalse(viewModel.isLoadingSnapshot)
    }

    func testSearchFiltersSessionsBySessionIDOrModel() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)

        await service.enqueueLoadCurrent(
            RecordsSnapshot(
                generatedAt: self.date("2026-04-21T10:00:00Z"),
                refreshMode: .incremental,
                models: [
                    HistoricalModelRecord(modelID: "gpt-5.4", sessionCount: 1, lastSeenAt: self.date("2026-04-21T10:00:00Z")),
                    HistoricalModelRecord(modelID: "google/gemini-2.5-pro", sessionCount: 1, lastSeenAt: self.date("2026-04-21T09:00:00Z")),
                ],
                sessions: [
                    HistoricalSessionRecord(
                        sessionID: "session-alpha",
                        modelID: "gpt-5.4",
                        startedAt: self.date("2026-04-21T08:00:00Z"),
                        lastActivityAt: self.date("2026-04-21T10:00:00Z"),
                        isArchived: false,
                        totalTokens: 220
                    ),
                    HistoricalSessionRecord(
                        sessionID: "session-beta",
                        modelID: "google/gemini-2.5-pro",
                        startedAt: self.date("2026-04-21T07:00:00Z"),
                        lastActivityAt: self.date("2026-04-21T09:00:00Z"),
                        isArchived: true,
                        totalTokens: 120
                    ),
                ],
                warnings: []
            )
        )

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }

        viewModel.searchText = "beta"
        XCTAssertEqual(viewModel.filteredSessions.map(\.sessionID), ["session-beta"])
        XCTAssertEqual(viewModel.filteredModels.map(\.modelID), ["google/gemini-2.5-pro"])

        viewModel.searchText = "gpt-5.4"
        XCTAssertEqual(viewModel.filteredSessions.map(\.sessionID), ["session-alpha"])
        XCTAssertEqual(viewModel.filteredModels.map(\.modelID), ["gpt-5.4"])
    }

    func testRefreshButtonStaysDisabledWhileRefreshIsInFlight() async throws {
        let service = RecordsSnapshotServiceStub()
        await service.enqueueLoadCurrent(self.makeSnapshot(sessionID: "initial", modelID: "gpt-5.4"))
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }

        viewModel.refreshAll(timeout: 1)
        try await self.waitUntil(timeout: 1) {
            let count = await service.refreshAllCount()
            return count == 1
        }

        XCTAssertTrue(viewModel.isRefreshingAll)
        viewModel.refreshAll(timeout: 1)
        let refreshCallCount = await service.refreshAllCount()
        XCTAssertEqual(refreshCallCount, 1)

        await service.resumeRefreshAll(
            with: .success(self.makeSnapshot(sessionID: "refreshed", modelID: "gpt-5.4"))
        )
        try await self.waitUntil(timeout: 1) { viewModel.isRefreshingAll == false }
        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["refreshed"])
    }

    func testTimedOutRefreshKeepsOldSnapshotAndDropsLateResult() async throws {
        let sourceLoader = SlowRecordsSourceSnapshotLoader(
            rebuildDelayNanoseconds: 100_000_000
        )
        let service = RecordsSnapshotService(sourceLoader: sourceLoader)
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot?.sessions.first?.sessionID == "initial" }

        viewModel.refreshAll(timeout: 0.01)
        try await self.waitUntil(timeout: 1) { viewModel.isRefreshingAll == false }

        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["initial"])
        XCTAssertEqual(viewModel.errorMessage, L.settingsRecordsRefreshTimeout)

        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["initial"])
        XCTAssertEqual(viewModel.errorMessage, L.settingsRecordsRefreshTimeout)
    }

    private func makeSnapshot(sessionID: String, modelID: String) -> RecordsSnapshot {
        RecordsSnapshot(
            generatedAt: self.date("2026-04-21T10:00:00Z"),
            refreshMode: .incremental,
            models: [
                HistoricalModelRecord(
                    modelID: modelID,
                    sessionCount: 1,
                    lastSeenAt: self.date("2026-04-21T10:00:00Z")
                ),
            ],
            sessions: [
                HistoricalSessionRecord(
                    sessionID: sessionID,
                    modelID: modelID,
                    startedAt: self.date("2026-04-21T09:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T10:00:00Z"),
                    isArchived: false,
                    totalTokens: 200
                ),
            ],
            warnings: []
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601Parsing.parse(value) ?? Date(timeIntervalSince1970: 0)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await condition() == false {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor RecordsSnapshotServiceStub: RecordsSnapshotServing {
    private(set) var loadCurrentCallCount = 0
    private(set) var refreshAllCallCount = 0

    private var pendingLoadCurrentContinuations: [CheckedContinuation<RecordsSnapshot, Error>] = []
    private var pendingRefreshAllContinuations: [CheckedContinuation<RecordsSnapshot, Error>] = []
    private var queuedLoadCurrentResults: [Result<RecordsSnapshot, Error>] = []

    func enqueueLoadCurrent(_ snapshot: RecordsSnapshot) {
        self.queuedLoadCurrentResults.append(.success(snapshot))
    }

    func loadCurrentCount() -> Int {
        self.loadCurrentCallCount
    }

    func refreshAllCount() -> Int {
        self.refreshAllCallCount
    }

    func loadCurrent() async throws -> RecordsSnapshot {
        self.loadCurrentCallCount += 1
        if self.queuedLoadCurrentResults.isEmpty == false {
            return try self.queuedLoadCurrentResults.removeFirst().get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingLoadCurrentContinuations.append(continuation)
        }
    }

    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot {
        _ = timeout
        self.refreshAllCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRefreshAllContinuations.append(continuation)
        }
    }

    func resumeLoadCurrent(with result: Result<RecordsSnapshot, Error>) {
        guard self.pendingLoadCurrentContinuations.isEmpty == false else { return }
        let continuation = self.pendingLoadCurrentContinuations.removeFirst()
        continuation.resume(with: result)
    }

    func resumeRefreshAll(with result: Result<RecordsSnapshot, Error>) {
        guard self.pendingRefreshAllContinuations.isEmpty == false else { return }
        let continuation = self.pendingRefreshAllContinuations.removeFirst()
        continuation.resume(with: result)
    }
}

private actor SlowRecordsSourceSnapshotLoader: RecordsSourceSnapshotLoading {
    private let rebuildDelayNanoseconds: UInt64

    init(rebuildDelayNanoseconds: UInt64) {
        self.rebuildDelayNanoseconds = rebuildDelayNanoseconds
    }

    func loadRecordsSourceSnapshot(refreshMode: RecordsRefreshMode) async throws -> RecordsSourceSnapshot {
        switch refreshMode {
        case .incremental:
            return RecordsSourceSnapshot(
                generatedAt: ISO8601Parsing.parse("2026-04-21T10:00:00Z") ?? Date(timeIntervalSince1970: 0),
                refreshMode: .incremental,
                sessions: [
                    HistoricalSessionRecord(
                        sessionID: "initial",
                        modelID: "gpt-5.4",
                        startedAt: ISO8601Parsing.parse("2026-04-21T09:00:00Z") ?? Date(timeIntervalSince1970: 0),
                        lastActivityAt: ISO8601Parsing.parse("2026-04-21T10:00:00Z") ?? Date(timeIntervalSince1970: 0),
                        isArchived: false,
                        totalTokens: 100
                    ),
                ],
                warnings: []
            )
        case .rebuildAll:
            try? await Task.sleep(nanoseconds: self.rebuildDelayNanoseconds)
            return RecordsSourceSnapshot(
                generatedAt: ISO8601Parsing.parse("2026-04-21T10:30:00Z") ?? Date(timeIntervalSince1970: 0),
                refreshMode: .rebuildAll,
                sessions: [
                    HistoricalSessionRecord(
                        sessionID: "late-refresh",
                        modelID: "gpt-5.4-mini",
                        startedAt: ISO8601Parsing.parse("2026-04-21T10:10:00Z") ?? Date(timeIntervalSince1970: 0),
                        lastActivityAt: ISO8601Parsing.parse("2026-04-21T10:30:00Z") ?? Date(timeIntervalSince1970: 0),
                        isArchived: false,
                        totalTokens: 140
                    ),
                ],
                warnings: []
            )
        }
    }
}
