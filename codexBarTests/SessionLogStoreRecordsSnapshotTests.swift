import Foundation
import XCTest

final class SessionLogStoreRecordsSnapshotTests: CodexBarTestCase {
    func testCachedSnapshotDoesNotReadChangedLogsOrWriteLedger() async throws {
        let home = try self.makeCodexHome()
        let directory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let store = self.makeStore(home: home)
        try self.writeFastSession(directory: directory, fileName: "alpha.jsonl", id: "alpha",
            timestamp: "2026-04-21T08:00:00Z", model: "gpt-5.5", inputTokens: 100, cachedInputTokens: 20, outputTokens: 20)
        let original = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        let ledgerURL = home.appendingPathComponent(".codexbar/test-records-ledger.json")
        let ledgerBefore = try Data(contentsOf: ledgerURL)
        try self.writeFastSession(directory: directory, fileName: "alpha.jsonl", id: "alpha",
            timestamp: "2026-04-21T09:00:00Z", model: "gpt-5.5", inputTokens: 3000, cachedInputTokens: 20, outputTokens: 50)
        let cached = try await store.loadCachedRecordsSourceSnapshot()
        XCTAssertEqual(cached.sessions, original.sessions)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), ledgerBefore)
        let refreshed = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        XCTAssertEqual(refreshed.sessions.first?.totalTokens, 3050, "Explicit incremental scans must retain their existing behavior")
    }

    func testCachedSnapshotUsesPersistedProjectionWithoutEnumeratingBrokenSessionsDirectory() async throws {
        let home = try self.makeCodexHome()
        let directory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let store = self.makeStore(home: home)
        try self.writeFastSession(directory: directory, fileName: "alpha.jsonl", id: "alpha",
            timestamp: "2026-04-21T08:00:00Z", model: "gpt-5.5", inputTokens: 100, cachedInputTokens: 20, outputTokens: 20)
        let original = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        let reloaded = self.makeStore(home: home)
        let cached = try await reloaded.loadCachedRecordsSourceSnapshot()
        XCTAssertEqual(cached.sessions, original.sessions)
        do {
            let scanned = try await reloaded.loadRecordsSourceSnapshot(refreshMode: .incremental)
            XCTAssertTrue(scanned.sessions.isEmpty, "Explicit scan must notice the removed source records")
            XCTAssertFalse(scanned.warnings.isEmpty, "Broken source directories must not look like complete scans")
        } catch { }
    }

    func testColdCachedSnapshotDoesNotScanExistingSessions() async throws {
        let home = try self.makeCodexHome()
        let directory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try self.writeFastSession(directory: directory, fileName: "alpha.jsonl", id: "alpha",
            timestamp: "2026-04-21T08:00:00Z", model: "gpt-5.5", inputTokens: 100, cachedInputTokens: 20, outputTokens: 20)
        let store = self.makeStore(home: home)
        let cached = try await store.loadCachedRecordsSourceSnapshot()
        XCTAssertTrue(cached.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codexbar/test-records-ledger.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codexbar/test-records-session-cache.json").path))
    }

    func testHistoricalModelsRefreshSessionCacheIncludesNewSessionModel() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: true), ["gpt-5.5"])

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 50,
            cachedInputTokens: 0,
            outputTokens: 10
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: false), ["gpt-5.5"])
        XCTAssertEqual(
            store.historicalModels(refreshSessionCache: true),
            ["google/gemini-2.5-pro", "gpt-5.5"]
        )
    }

    func testReduceBillableEventsRefreshSessionCacheRebuildsLedgerForNewSessionFiles() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home) { _, usage, _ in
            Double(usage.totalTokens)
        }

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: true),
            ["alpha"]
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 30,
            cachedInputTokens: 10,
            outputTokens: 10
        )

        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: false),
            ["alpha"]
        )
        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: true),
            ["alpha", "beta"]
        )
    }

    func testModelLessUsageIsKeptAndReportedAsMissingAttribution() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "valid.jsonl",
            id: "valid",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let incompleteURL = codexRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("incomplete.jsonl")
        let incompleteContent = [
            #"{"payload":{"type":"session_meta","id":"broken","timestamp":"2026-04-21T09:00:00Z"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":90,"cached_input_tokens":10,"output_tokens":10}}}"#,
        ].joined(separator: "\n") + "\n"
        try incompleteContent.write(to: incompleteURL, atomically: true, encoding: .utf8)

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)

        XCTAssertEqual(snapshot.refreshMode, .incremental)
        XCTAssertEqual(Set(snapshot.sessions.map(\.sessionID)), ["valid", "broken"])
        XCTAssertEqual(snapshot.sessions.first { $0.sessionID == "broken" }?.totalTokens, 100)
        XCTAssertEqual(snapshot.sessions.first { $0.sessionID == "broken" }?.modelID, "unknown")
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].sessionFilePath.hasSuffix("/incomplete.jsonl"))
        XCTAssertEqual(snapshot.warnings[0].kind, .missingModel)
        XCTAssertEqual(store.historicalModels(), ["gpt-5.5"])
    }

    func testCancelledSessionWithoutModelRemainsReadableWithoutWarning() async throws {
        let home = try self.makeCodexHome()
        let file = home.appendingPathComponent(".codex/sessions/cancelled.jsonl")
        try [
            #"{"type":"session_meta","payload":{"id":"cancelled","timestamp":"2026-04-21T09:00:00Z"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#,
        ].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try await self.makeStore(home: home).loadRecordsSourceSnapshot(refreshMode: .incremental)
        XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["cancelled"])
        XCTAssertEqual(snapshot.sessions.first?.totalTokens, 0)
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testMalformedCompleteLineStillReportsReadWarning() async throws {
        let home = try self.makeCodexHome()
        let file = home.appendingPathComponent(".codex/sessions/damaged.jsonl")
        try [
            #"{"type":"session_meta","payload":{"id":"damaged","timestamp":"2026-04-21T09:00:00Z"}}"#,
            #"{"type":"event_msg","payload":broken}"#,
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try await self.makeStore(home: home).loadRecordsSourceSnapshot(refreshMode: .incremental)
        XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["damaged"])
        XCTAssertEqual(snapshot.warnings.map(\.kind), [.incompleteSessionRecord])
    }

    func testZeroTokenMarkerWithoutModelDoesNotBecomeAnUnreadableSession() async throws {
        let home = try self.makeCodexHome()
        let file = home.appendingPathComponent(".codex/sessions/zero-marker.jsonl")
        try [
            #"{"type":"session_meta","payload":{"id":"zero-marker","timestamp":"2026-04-21T09:00:00Z"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try await self.makeStore(home: home).loadRecordsSourceSnapshot(refreshMode: .incremental)
        XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["zero-marker"])
        XCTAssertEqual(snapshot.sessions.first?.totalTokens, 0)
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testRebuildAllReturnsFreshRecordsSourceSnapshot() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let firstSnapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        XCTAssertEqual(firstSnapshot.sessions.map(\.sessionID), ["alpha"])

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 30,
            cachedInputTokens: 10,
            outputTokens: 10
        )

        let rebuiltSnapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .rebuildAll)

        XCTAssertEqual(rebuiltSnapshot.refreshMode, .rebuildAll)
        XCTAssertEqual(rebuiltSnapshot.sessions.map(\.sessionID), ["beta", "alpha"])
        XCTAssertEqual(
            rebuiltSnapshot.sessions.map(\.modelID),
            ["google/gemini-2.5-pro", "gpt-5.5"]
        )
    }

    private func billableSessionIDs(from store: SessionLogStore, refreshSessionCache: Bool) -> [String] {
        store.reduceBillableEvents(into: Set<String>(), refreshSessionCache: refreshSessionCache) { partialResult, event in
            partialResult.insert(event.sessionID)
        }
        .sorted()
    }

    private func makeCodexHome() throws -> URL {
        let home = try XCTUnwrap(self.temporaryHomeURL())
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func temporaryHomeURL() -> URL? {
        let home = ProcessInfo.processInfo.environment["CODEXBAR_HOME"]
        guard let home, home.isEmpty == false else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private func makeStore(
        home: URL,
        billableCostCalculator: @escaping (String, SessionLogStore.Usage, SessionLogStore.Usage) -> Double? = { model, usage, sessionUsage in
            LocalCostPricing.costUSD(model: model, usage: usage, sessionUsage: sessionUsage)
        }
    ) -> SessionLogStore {
        SessionLogStore(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            persistedCacheURL: home.appendingPathComponent(".codexbar/test-records-session-cache.json"),
            persistedUsageLedgerURL: home.appendingPathComponent(".codexbar/test-records-ledger.json"),
            billableCostCalculator: billableCostCalculator
        )
    }

    private func writeFastSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":\#(cachedInputTokens),"output_tokens":\#(outputTokens)}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
