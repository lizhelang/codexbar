import Foundation
import XCTest

final class LocalCostSummaryServiceTests: CodexBarTestCase {
    private struct LegacyPersistedCache: Codable {
        let version: Int
        let files: [String: LegacyCachedSessionRecord]
    }

    private struct LegacyCachedSessionRecord: Codable {
        let fingerprint: LegacyFileFingerprint
        let record: LegacySessionRecord?
        let usageEvents: [LegacyUsageEvent]
    }

    private struct LegacyFileFingerprint: Codable {
        let fileSize: Int
        let modificationDate: Date
    }

    private struct LegacySessionRecord: Codable {
        let id: String
        let startedAt: Date
        let lastActivityAt: Date
        let isArchived: Bool
        let model: String
        let usage: LegacyUsage
        let taskLifecycleState: String?
    }

    private struct LegacyUsageEvent: Codable {
        let timestamp: Date
        let usage: LegacyUsage
    }

    private struct LegacyUsage: Codable {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
    }

    private struct PersistedLedger: Codable {
        let version: Int
        let didSeedFromSessionCache: Bool
        let sessions: [String: PersistedLedgerSession]
    }

    private struct PersistedLedgerSession: Codable {
        let model: String?
        let events: [PersistedLedgerEvent]
    }

    private struct PersistedLedgerEvent: Codable {
        let timestamp: Date
        let usage: LegacyUsage
        let costUSD: Double
    }

    func testLoadAggregatesSessionsAcrossFastAndSlowPaths() throws {
        let home = try self.makeCodexHome()
        let service = self.makeService(home: home)

        try self.writeFastSession(
            directory: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            fileName: "today-fast.jsonl",
            id: "today-fast",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 50
        )
        try self.writeSlowSession(
            directory: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            fileName: "recent-slow.jsonl",
            id: "recent-slow",
            timestamp: "2026-04-03T09:00:00Z",
            model: "gpt-5-mini",
            inputTokens: 200,
            cachedInputTokens: 50,
            outputTokens: 40
        )
        try self.writeFastSession(
            directory: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            fileName: "unsupported.jsonl",
            id: "unsupported",
            timestamp: "2026-03-01T09:00:00Z",
            model: "unknown-model",
            inputTokens: 999,
            cachedInputTokens: 0,
            outputTokens: 999
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 170)
        XCTAssertEqual(summary.last30DaysTokens, 460)
        XCTAssertEqual(summary.lifetimeTokens, 2_458)
        XCTAssertEqual(summary.dailyEntries.count, 3)

        XCTAssertEqual(summary.todayCostUSD, 0.000955, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0.00107375, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.00107375, accuracy: 1e-12)

        XCTAssertEqual(summary.dailyEntries[0].date, self.date("2026-04-05T00:00:00Z"))
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 170)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0.000955, accuracy: 1e-12)

        XCTAssertEqual(summary.dailyEntries[1].date, self.date("2026-04-03T00:00:00Z"))
        XCTAssertEqual(summary.dailyEntries[1].totalTokens, 290)
        XCTAssertEqual(summary.dailyEntries[1].costUSD, 0.00011875, accuracy: 1e-12)

        XCTAssertEqual(summary.dailyEntries[2].date, self.date("2026-03-01T00:00:00Z"))
        XCTAssertEqual(summary.dailyEntries[2].totalTokens, 1_998)
        XCTAssertEqual(summary.dailyEntries[2].costUSD, 0, accuracy: 1e-12)
    }

    func testLoadRefreshesChangedSessionFileInsteadOfServingStaleCache() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let cacheURL = home.appendingPathComponent(".codexbar/test-cost-session-cache.json")
        let ledgerURL = home.appendingPathComponent(".codexbar/test-cost-event-ledger.json")
        let store = SessionLogStore(
            codexRootURL: codexRoot,
            persistedCacheURL: cacheURL,
            persistedUsageLedgerURL: ledgerURL
        )
        let service = LocalCostSummaryService(sessionLogStore: store, calendar: self.utcCalendar())

        try self.writeFastSession(
            directory: sessionDirectory,
            fileName: "mutable.jsonl",
            id: "mutable",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4-mini",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 20,
            modificationDate: self.date("2026-04-05T08:05:00Z")
        )

        let initialSummary = service.load(now: self.date("2026-04-05T12:00:00Z"))
        XCTAssertEqual(initialSummary.todayTokens, 130)
        XCTAssertEqual(initialSummary.todayCostUSD, 0.00015825, accuracy: 1e-12)

        try self.writeFastSession(
            directory: sessionDirectory,
            fileName: "mutable.jsonl",
            id: "mutable",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4-mini",
            inputTokens: 200,
            cachedInputTokens: 10,
            outputTokens: 50,
            modificationDate: self.date("2026-04-05T10:05:00Z")
        )

        let updatedSummary = service.load(now: self.date("2026-04-05T12:00:00Z"))
        XCTAssertEqual(updatedSummary.todayTokens, 260)
        XCTAssertEqual(updatedSummary.todayCostUSD, 0.00036825, accuracy: 1e-12)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testLoadDoesNotDropRepeatedEqualDeltasFromSnapshotOnlySessions() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let service = self.makeService(home: home)

        try self.writeFastSession(
            directory: sessionDirectory,
            fileName: "equal-deltas.jsonl",
            id: "equal-deltas",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20,
            modificationDate: self.date("2026-04-05T08:05:00Z")
        )

        let initialSummary = service.load(now: self.date("2026-04-05T12:00:00Z"))
        XCTAssertEqual(initialSummary.todayTokens, 140)
        XCTAssertEqual(initialSummary.todayCostUSD, 0.000505, accuracy: 1e-12)

        try self.writeFastSession(
            directory: sessionDirectory,
            fileName: "equal-deltas.jsonl",
            id: "equal-deltas",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 200,
            cachedInputTokens: 40,
            outputTokens: 40,
            modificationDate: self.date("2026-04-05T09:05:00Z")
        )

        let updatedSummary = service.load(now: self.date("2026-04-05T12:30:00Z"))
        XCTAssertEqual(updatedSummary.todayTokens, 280)
        XCTAssertEqual(updatedSummary.todayCostUSD, 0.00101, accuracy: 1e-12)
        XCTAssertEqual(updatedSummary.dailyEntries.count, 1)
        XCTAssertEqual(updatedSummary.dailyEntries[0].totalTokens, 280)
        XCTAssertEqual(updatedSummary.dailyEntries[0].costUSD, 0.00101, accuracy: 1e-12)
    }

    func testLoadDoesNotDoubleCountDuplicateTokenCountLines() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)

        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "duplicate-token-counts.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"duplicate-token-counts","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
                #"{"timestamp":"2026-04-05T09:10:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
            ]
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 230)
        XCTAssertEqual(summary.last30DaysTokens, 230)
        XCTAssertEqual(summary.lifetimeTokens, 230)
        XCTAssertEqual(summary.todayCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 230)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0.0008075, accuracy: 1e-12)
    }

    func testLoadDoesNotDoubleCountReplayedTokenCountBlocksAfterTotalDrops() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)

        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "replayed-token-blocks.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"replayed-token-blocks","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
                #"{"timestamp":"2026-04-05T10:15:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T10:15:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
                #"{"timestamp":"2026-04-05T11:20:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":220,"cached_input_tokens":40,"output_tokens":40},"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":10}}}}"#,
            ]
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 300)
        XCTAssertEqual(summary.last30DaysTokens, 300)
        XCTAssertEqual(summary.lifetimeTokens, 300)
        XCTAssertEqual(summary.todayCostUSD, 0.00106, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0.00106, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.00106, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 300)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0.00106, accuracy: 1e-12)
    }

    func testLoadDoesNotDoubleCountSameSessionAcrossCurrentAndArchivedDirectories() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)

        let detailedLines = [
            #"{"payload":{"type":"session_meta","id":"shared-session","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
        ]
        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "shared-current.jsonl",
            lines: detailedLines
        )
        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "shared-archived.jsonl",
            id: "shared-session",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 170,
            cachedInputTokens: 30,
            outputTokens: 30
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 230)
        XCTAssertEqual(summary.last30DaysTokens, 230)
        XCTAssertEqual(summary.lifetimeTokens, 230)
        XCTAssertEqual(summary.todayCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 230)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0.0008075, accuracy: 1e-12)
    }

    func testLoadKeepsObservedTotalsAfterArchivedTokenOnlyRewrite() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let currentDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let archivedDirectory = codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        let service = self.makeService(home: home)

        try self.writeSession(
            directory: currentDirectory,
            fileName: "rollback.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"rollback-session","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
            ]
        )

        let initialSummary = service.load(now: self.date("2026-04-05T12:00:00Z"))
        XCTAssertEqual(initialSummary.todayTokens, 230)
        XCTAssertEqual(initialSummary.todayCostUSD, 0.0008075, accuracy: 1e-12)

        try FileManager.default.removeItem(at: currentDirectory.appendingPathComponent("rollback.jsonl"))
        try self.writeTokenOnlySession(
            directory: archivedDirectory,
            fileName: "rollback.jsonl",
            id: "rollback-session",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            eventTimestamp: "2026-04-05T10:30:00Z"
        )

        let updatedSummary = service.load(now: self.date("2026-04-05T12:30:00Z"))
        self.assertSummary(
            updatedSummary,
            matches: initialSummary,
            comparingUpdatedAt: false
        )
    }

    func testLoadSeedsLedgerFromLegacyCostSessionCacheBeforeCutoverAndDoesNotDoubleSeedOnRestart() throws {
        let referenceHome = try self.makeCodexHome()
        let referenceCodexRoot = referenceHome.appendingPathComponent(".codex", isDirectory: true)
        let referenceService = self.makeService(home: referenceHome)

        let referenceEvents = [
            SessionLogStore.UsageEvent(
                timestamp: self.date("2026-04-05T08:05:00Z"),
                usage: SessionLogStore.Usage(inputTokens: 100, cachedInputTokens: 20, outputTokens: 20)
            ),
            SessionLogStore.UsageEvent(
                timestamp: self.date("2026-04-05T09:10:00Z"),
                usage: SessionLogStore.Usage(inputTokens: 70, cachedInputTokens: 10, outputTokens: 10)
            ),
        ]

        try self.writeSession(
            directory: referenceCodexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "seed-reference.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"seed-reference","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
            ]
        )

        let referenceSummary = referenceService.load(now: self.date("2026-04-05T12:00:00Z"))

        let seededHome = try self.makeCodexHome()
        let seededCodexRoot = seededHome.appendingPathComponent(".codex", isDirectory: true)
        try self.writeTokenOnlySession(
            directory: seededCodexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "seed-reference.jsonl",
            id: "seed-reference",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            eventTimestamp: "2026-04-05T10:30:00Z"
        )
        try self.writeLegacyCostSessionCache(
            home: seededHome,
            filePath: seededCodexRoot.appendingPathComponent("sessions/seed-reference.jsonl").path,
            sessionID: "seed-reference",
            startedAt: self.date("2026-04-05T08:00:00Z"),
            lastActivityAt: self.date("2026-04-05T10:00:00Z"),
            isArchived: false,
            model: "gpt-5.4",
            finalUsage: SessionLogStore.Usage(inputTokens: 170, cachedInputTokens: 30, outputTokens: 30),
            usageEvents: referenceEvents
        )

        let seededService = self.makeService(home: seededHome)
        let seededSummary = seededService.load(now: self.date("2026-04-05T12:00:00Z"))
        self.assertSummary(seededSummary, matches: referenceSummary)

        let restartedService = self.makeService(home: seededHome)
        let restartedSummary = restartedService.load(now: self.date("2026-04-05T12:00:00Z"))
        self.assertSummary(restartedSummary, matches: seededSummary)
    }

    func testLoadDoesNotDoubleCountLegacySeededEventsWhenCurrentFileHasFractionalTimestamps() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)

        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "fractional-seed.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"fractional-seed","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00.123Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T09:10:00.456Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
            ]
        )

        try self.writeLegacyCostSessionCache(
            home: home,
            filePath: codexRoot.appendingPathComponent("sessions/fractional-seed.jsonl").path,
            sessionID: "fractional-seed",
            startedAt: self.date("2026-04-05T08:00:00Z"),
            lastActivityAt: self.date("2026-04-05T09:10:00Z"),
            isArchived: false,
            model: "gpt-5.4",
            finalUsage: SessionLogStore.Usage(inputTokens: 170, cachedInputTokens: 30, outputTokens: 30),
            usageEvents: [
                SessionLogStore.UsageEvent(
                    timestamp: self.date("2026-04-05T08:05:00Z"),
                    usage: SessionLogStore.Usage(inputTokens: 100, cachedInputTokens: 20, outputTokens: 20)
                ),
                SessionLogStore.UsageEvent(
                    timestamp: self.date("2026-04-05T09:10:00Z"),
                    usage: SessionLogStore.Usage(inputTokens: 70, cachedInputTokens: 10, outputTokens: 10)
                ),
            ]
        )

        let summary = self.makeService(home: home).load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 230)
        XCTAssertEqual(summary.last30DaysTokens, 230)
        XCTAssertEqual(summary.lifetimeTokens, 230)
        XCTAssertEqual(summary.todayCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 230)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0.0008075, accuracy: 1e-12)
    }

    func testLoadRepairsCurrentSessionLedgerWhenPersistedLedgerContainsDuplicates() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)

        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "ledger-repair.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"ledger-repair","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
            ]
        )

        try self.writePersistedLedger(
            home: home,
            sessionID: "ledger-repair",
            events: [
                .init(
                    timestamp: self.date("2026-04-05T08:05:00Z"),
                    usage: .init(inputTokens: 100, cachedInputTokens: 20, outputTokens: 20),
                    costUSD: 0.000505
                ),
                .init(
                    timestamp: self.date("2026-04-05T08:05:00.500Z"),
                    usage: .init(inputTokens: 100, cachedInputTokens: 20, outputTokens: 20),
                    costUSD: 0.000505
                ),
                .init(
                    timestamp: self.date("2026-04-05T09:10:00Z"),
                    usage: .init(inputTokens: 70, cachedInputTokens: 10, outputTokens: 10),
                    costUSD: 0.0003025
                ),
            ]
        )

        let summary = self.makeService(home: home).load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 230)
        XCTAssertEqual(summary.last30DaysTokens, 230)
        XCTAssertEqual(summary.lifetimeTokens, 230)
        XCTAssertEqual(summary.todayCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 230)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0.0008075, accuracy: 1e-12)
    }

    func testLoadAttributesCrossDaySessionUsageToEventDayAndPreservesBucketsAfterRewrite() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)

        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "cross-day.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"cross-day","timestamp":"2026-04-04T23:50:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
                #"{"timestamp":"2026-04-04T23:55:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T01:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
            ]
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 90)
        XCTAssertEqual(summary.last30DaysTokens, 230)
        XCTAssertEqual(summary.lifetimeTokens, 230)
        XCTAssertEqual(summary.dailyEntries.count, 2)

        XCTAssertEqual(summary.dailyEntries[0].date, self.date("2026-04-05T00:00:00Z"))
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 90)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0.0003025, accuracy: 1e-12)

        XCTAssertEqual(summary.dailyEntries[1].date, self.date("2026-04-04T00:00:00Z"))
        XCTAssertEqual(summary.dailyEntries[1].totalTokens, 140)
        XCTAssertEqual(summary.dailyEntries[1].costUSD, 0.000505, accuracy: 1e-12)

        XCTAssertEqual(summary.todayCostUSD, 0.0003025, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.0008075, accuracy: 1e-12)

        try self.writeTokenOnlySession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "cross-day.jsonl",
            id: "cross-day",
            timestamp: "2026-04-04T23:50:00Z",
            model: "gpt-5.4",
            eventTimestamp: "2026-04-05T02:00:00Z"
        )
        try FileManager.default.removeItem(
            at: codexRoot.appendingPathComponent("sessions/cross-day.jsonl")
        )

        let rewrittenSummary = service.load(now: self.date("2026-04-05T12:30:00Z"))
        self.assertSummary(
            rewrittenSummary,
            matches: summary,
            comparingUpdatedAt: false
        )
    }

    func testLoadRepricesHistoricalUsageWhenPricingChanges() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)

        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "pricing.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"pricing","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            ]
        )

        let initialService = self.makeService(home: home)
        let initialSummary = initialService.load(now: self.date("2026-04-05T12:00:00Z"))
        XCTAssertEqual(initialSummary.todayCostUSD, 0.000505, accuracy: 1e-12)

        let repricedSummary = initialService.load(
            now: self.date("2026-04-05T12:00:00Z"),
            modelPricingOverrides: [
                "gpt-5.4": CodexBarModelPricing(
                    inputUSDPerToken: 1,
                    cachedInputUSDPerToken: 0.5,
                    outputUSDPerToken: 2
                ),
            ]
        )

        XCTAssertEqual(repricedSummary.todayTokens, 140)
        XCTAssertEqual(repricedSummary.last30DaysTokens, 140)
        XCTAssertEqual(repricedSummary.lifetimeTokens, 140)
        XCTAssertEqual(repricedSummary.todayCostUSD, 130, accuracy: 1e-9)
        XCTAssertEqual(repricedSummary.last30DaysCostUSD, 130, accuracy: 1e-9)
        XCTAssertEqual(repricedSummary.lifetimeCostUSD, 130, accuracy: 1e-9)
        XCTAssertEqual(repricedSummary.dailyEntries.count, 1)
        XCTAssertEqual(repricedSummary.dailyEntries[0].totalTokens, 140)
        XCTAssertEqual(repricedSummary.dailyEntries[0].costUSD, 130, accuracy: 1e-9)
    }

    func testLoadUsesKnownOpenAIPricingForModelVariants() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)
        let usage = SessionLogStore.Usage(
            inputTokens: 100,
            cachedInputTokens: 25,
            outputTokens: 30
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "spark-variant.jsonl",
            id: "spark-variant",
            timestamp: "2026-04-05T08:00:00Z",
            model: "openai/gpt-5.3-codex-spark",
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            outputTokens: usage.outputTokens
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))
        let expectedCost = LocalCostPricing.costUSD(model: "gpt-5.3-codex", usage: usage)

        XCTAssertEqual(summary.todayTokens, 155)
        XCTAssertEqual(summary.last30DaysTokens, 155)
        XCTAssertEqual(summary.lifetimeTokens, 155)
        XCTAssertEqual(summary.todayCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, expectedCost, accuracy: 1e-12)
    }

    func testLoadAppliesGPT54LongContextPremiumForSessionsAbove272KInputTokens() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)
        let usage = SessionLogStore.Usage(
            inputTokens: 300_000,
            cachedInputTokens: 20_000,
            outputTokens: 1_000
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "gpt54-long-context.jsonl",
            id: "gpt54-long-context",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            outputTokens: usage.outputTokens
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))
        let expectedCost = LocalCostPricing.costUSD(
            model: "gpt-5.4",
            usage: usage,
            sessionUsage: usage
        )
        let baselineCost = LocalCostPricing.costUSD(model: "gpt-5.4", usage: usage)

        XCTAssertGreaterThan(expectedCost, baselineCost)
        XCTAssertEqual(summary.todayTokens, 321_000)
        XCTAssertEqual(summary.last30DaysTokens, 321_000)
        XCTAssertEqual(summary.lifetimeTokens, 321_000)
        XCTAssertEqual(summary.todayCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 321_000)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, expectedCost, accuracy: 1e-12)
    }

    func testLoadBackfillsBlankArchivedLedgerModelBeforeRepricingEvents() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let usage = SessionLogStore.Usage(
            inputTokens: 100,
            cachedInputTokens: 25,
            outputTokens: 30
        )
        let eventTimestamp = self.date("2026-04-05T08:05:00Z")

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "spark-archived.jsonl",
            id: "spark-archived",
            timestamp: "2026-04-05T08:00:00Z",
            model: "openai/gpt-5.3-codex-spark",
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            outputTokens: usage.outputTokens,
            modificationDate: eventTimestamp
        )
        try self.writePersistedLedger(
            home: home,
            sessionID: "spark-archived",
            model: "",
            events: [
                .init(
                    timestamp: eventTimestamp,
                    usage: LegacyUsage(
                        inputTokens: usage.inputTokens,
                        cachedInputTokens: usage.cachedInputTokens,
                        outputTokens: usage.outputTokens
                    ),
                    costUSD: 0
                ),
            ]
        )

        let summary = self.makeService(home: home).load(now: self.date("2026-04-05T12:00:00Z"))
        let expectedCost = LocalCostPricing.costUSD(
            model: "openai/gpt-5.3-codex-spark",
            usage: usage,
            sessionUsage: usage
        )

        XCTAssertEqual(summary.todayTokens, 155)
        XCTAssertEqual(summary.last30DaysTokens, 155)
        XCTAssertEqual(summary.lifetimeTokens, 155)
        XCTAssertEqual(summary.todayCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, expectedCost, accuracy: 1e-12)

        let data = try Data(contentsOf: home.appendingPathComponent(".codexbar/test-cost-event-ledger.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(PersistedLedger.self, from: data)
        XCTAssertEqual(
            persisted.sessions["spark-archived"]?.model,
            "gpt-5.3-codex-spark"
        )
    }

    func testLoadKeepsUnknownModelTokensAndUsesZeroCost() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "unknown-model.jsonl",
            id: "unknown-model",
            timestamp: "2026-04-05T08:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 100,
            cachedInputTokens: 25,
            outputTokens: 30
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 155)
        XCTAssertEqual(summary.last30DaysTokens, 155)
        XCTAssertEqual(summary.lifetimeTokens, 155)
        XCTAssertEqual(summary.todayCostUSD, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 155)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0, accuracy: 1e-12)
    }

    func testHistoricalModelsAreStableAndDeduplicated() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5
        )
        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-04T08:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5
        )
        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "gamma.jsonl",
            id: "gamma",
            timestamp: "2026-04-03T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5
        )

        _ = service.load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(
            service.historicalModels(),
            ["google/gemini-2.5-pro", "gpt-5.4"]
        )
    }

    func testHistoricalModelsCanBeReadFromPersistedCacheWithoutScanningSessions() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let service = self.makeService(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5
        )
        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-04T08:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5
        )

        _ = service.load(now: self.date("2026-04-05T12:00:00Z"))
        try FileManager.default.removeItem(at: codexRoot.appendingPathComponent("sessions/alpha.jsonl"))
        try FileManager.default.removeItem(at: codexRoot.appendingPathComponent("archived_sessions/beta.jsonl"))

        XCTAssertEqual(
            service.historicalModels(),
            ["google/gemini-2.5-pro", "gpt-5.4"]
        )
    }

    func testLoadCanUsePersistedLedgerWithoutRefreshingSessionFiles() throws {
        let home = try self.makeCodexHome()

        try self.writePersistedLedger(
            home: home,
            sessionID: "persisted-only",
            model: "gpt-5.4",
            events: [
                .init(
                    timestamp: self.date("2026-04-05T08:05:00Z"),
                    usage: .init(inputTokens: 100, cachedInputTokens: 20, outputTokens: 20),
                    costUSD: 0.000505
                ),
                .init(
                    timestamp: self.date("2026-04-05T09:10:00Z"),
                    usage: .init(inputTokens: 70, cachedInputTokens: 10, outputTokens: 10),
                    costUSD: 0.0003025
                ),
            ]
        )

        let summary = self.makeService(home: home).load(
            now: self.date("2026-04-05T12:00:00Z"),
            refreshSessionCache: false
        )

        XCTAssertEqual(summary.todayTokens, 230)
        XCTAssertEqual(summary.last30DaysTokens, 230)
        XCTAssertEqual(summary.lifetimeTokens, 230)
        XCTAssertEqual(summary.todayCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(summary.dailyEntries.count, 1)
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 230)
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

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601Parsing.parse(value) ?? Date(timeIntervalSince1970: 0)
    }

    private func writeFastSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        modificationDate: Date? = nil
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":\#(cachedInputTokens),"output_tokens":\#(outputTokens)}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate ?? self.date(timestamp)],
            ofItemAtPath: fileURL.path
        )
    }

    private func makeStore(
        home: URL,
        billableCostCalculator: @escaping (String, SessionLogStore.Usage, SessionLogStore.Usage) -> Double? = { model, usage, sessionUsage in
            LocalCostPricing.costUSD(model: model, usage: usage, sessionUsage: sessionUsage)
        }
    ) -> SessionLogStore {
        SessionLogStore(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            persistedCacheURL: home.appendingPathComponent(".codexbar/test-cost-session-cache.json"),
            persistedUsageLedgerURL: home.appendingPathComponent(".codexbar/test-cost-event-ledger.json"),
            billableCostCalculator: billableCostCalculator
        )
    }

    private func makeService(home: URL) -> LocalCostSummaryService {
        LocalCostSummaryService(
            sessionLogStore: self.makeStore(home: home),
            calendar: self.utcCalendar()
        )
    }

    private func assertSummary(
        _ summary: LocalCostSummary,
        matches expected: LocalCostSummary,
        comparingUpdatedAt: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(summary.todayTokens, expected.todayTokens, file: file, line: line)
        XCTAssertEqual(summary.last30DaysTokens, expected.last30DaysTokens, file: file, line: line)
        XCTAssertEqual(summary.lifetimeTokens, expected.lifetimeTokens, file: file, line: line)
        XCTAssertEqual(summary.todayCostUSD, expected.todayCostUSD, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(summary.last30DaysCostUSD, expected.last30DaysCostUSD, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(summary.lifetimeCostUSD, expected.lifetimeCostUSD, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(summary.dailyEntries.count, expected.dailyEntries.count, file: file, line: line)

        for (actualEntry, expectedEntry) in zip(summary.dailyEntries, expected.dailyEntries) {
            XCTAssertEqual(actualEntry.date, expectedEntry.date, file: file, line: line)
            XCTAssertEqual(actualEntry.totalTokens, expectedEntry.totalTokens, file: file, line: line)
            XCTAssertEqual(actualEntry.costUSD, expectedEntry.costUSD, accuracy: 1e-12, file: file, line: line)
        }

        if comparingUpdatedAt {
            XCTAssertEqual(summary.updatedAt, expected.updatedAt, file: file, line: line)
        }
    }

    private func writeTokenOnlySession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        eventTimestamp: String
    ) throws {
        try self.writeSession(
            directory: directory,
            fileName: fileName,
            lines: [
                #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
                #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
                #"{"timestamp":"\#(eventTimestamp)","type":"event_msg","payload":{"type":"thread_rolled_back"}}"#,
                #"{"timestamp":"\#(eventTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last":{"total_tokens":999}}}}"#,
            ]
        )
    }

    private func writeLegacyCostSessionCache(
        home: URL,
        filePath: String,
        sessionID: String,
        startedAt: Date,
        lastActivityAt: Date,
        isArchived: Bool,
        model: String,
        finalUsage: SessionLogStore.Usage,
        usageEvents: [SessionLogStore.UsageEvent]
    ) throws {
        let payload = LegacyPersistedCache(
            version: 4,
            files: [
                filePath: LegacyCachedSessionRecord(
                    fingerprint: LegacyFileFingerprint(
                        fileSize: 1024,
                        modificationDate: lastActivityAt
                    ),
                    record: LegacySessionRecord(
                        id: sessionID,
                        startedAt: startedAt,
                        lastActivityAt: lastActivityAt,
                        isArchived: isArchived,
                        model: model,
                        usage: LegacyUsage(
                            inputTokens: finalUsage.inputTokens,
                            cachedInputTokens: finalUsage.cachedInputTokens,
                            outputTokens: finalUsage.outputTokens
                        ),
                        taskLifecycleState: nil
                    ),
                    usageEvents: usageEvents.map { event in
                        LegacyUsageEvent(
                            timestamp: event.timestamp,
                            usage: LegacyUsage(
                                inputTokens: event.usage.inputTokens,
                                cachedInputTokens: event.usage.cachedInputTokens,
                                outputTokens: event.usage.outputTokens
                            )
                        )
                    }
                ),
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try CodexPaths.writeSecureFile(
            data,
            to: home.appendingPathComponent(".codexbar/test-cost-session-cache.json")
        )
    }

    private func writePersistedLedger(
        home: URL,
        sessionID: String,
        model: String? = nil,
        events: [PersistedLedgerEvent]
    ) throws {
        let payload = PersistedLedger(
            version: 2,
            didSeedFromSessionCache: true,
            sessions: [
                sessionID: PersistedLedgerSession(model: model, events: events),
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try CodexPaths.writeSecureFile(
            data,
            to: home.appendingPathComponent(".codexbar/test-cost-event-ledger.json")
        )
    }

    private func writeSlowSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        modificationDate: Date? = nil
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
            #"{"wrapper":{"type":"event_msg"},"payload":{"type":"token_count","kind":"token_count","info":{"total_token_usage": {"input_tokens": \#(inputTokens), "cached_input_tokens": \#(cachedInputTokens), "output_tokens": \#(outputTokens)}}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate ?? self.date(timestamp)],
            ofItemAtPath: fileURL.path
        )
    }

    private func writeSession(
        directory: URL,
        fileName: String,
        lines: [String]
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
    }
}
