import Foundation
import XCTest

final class OpenAIRunningThreadAttributionServiceTests: CodexBarTestCase {
    func testLoadPrefersAggregateRouteJournalOverSwitchJournal() throws {
        let now = self.date("2026-04-05T12:00:00Z")
        let runtimeStore = self.makeRuntimeStore()
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let journalStore = SwitchJournalStore(fileURL: CodexPaths.switchJournalURL)
        try journalStore.appendActivation(
            providerID: "openai-oauth",
            accountID: "acct-switch",
            timestamp: self.date("2026-04-05T11:59:50Z")
        )
        routeJournalStore.recordRoute(
            threadID: "thread-aggregate-1",
            accountID: "acct-routed",
            timestamp: self.date("2026-04-05T11:59:58Z")
        )

        try RuntimeSQLiteFixtureSupport.writeStateDatabase(
            at: CodexPaths.stateSQLiteURL,
            threads: [
                .init(
                    id: "thread-aggregate-1",
                    source: "vscode",
                    cwd: "/repo/app",
                    title: "Aggregate thread",
                    createdAt: 1_775_389_000,
                    updatedAt: 1_775_390_399
                ),
            ]
        )
        try RuntimeSQLiteFixtureSupport.writeLogsDatabase(
            at: CodexPaths.logsSQLiteURL,
            logs: [
                .init(
                    threadID: "thread-aggregate-1",
                    timestamp: 1_775_390_399,
                    target: "codex_api::endpoint::responses_websocket"
                ),
            ]
        )

        let attribution = OpenAIRunningThreadAttributionService(
            runtimeStore: runtimeStore,
            switchJournalStore: journalStore,
            aggregateRouteJournalStore: routeJournalStore
        ).load(
            now: now,
            recentActivityWindow: 5
        )

        XCTAssertEqual(attribution.summary.runningThreadCount(for: "acct-routed"), 1)
        XCTAssertEqual(attribution.summary.runningThreadCount(for: "acct-switch"), 0)
        XCTAssertEqual(attribution.summary.unknownThreadCount, 0)
        XCTAssertEqual(attribution.threads.first?.accountID, "acct-routed")
    }

    func testLoadAttributesRunningThreadsByLatestRuntimeLogTime() throws {
        let now = self.date("2026-04-05T12:00:00Z")
        let runtimeStore = self.makeRuntimeStore()
        let journalStore = SwitchJournalStore(fileURL: CodexPaths.switchJournalURL)
        try journalStore.appendActivation(
            providerID: "openai-oauth",
            accountID: "acct_a",
            timestamp: self.date("2026-04-05T11:59:50Z")
        )
        try journalStore.appendActivation(
            providerID: "custom-provider",
            accountID: "custom",
            timestamp: self.date("2026-04-05T11:59:55Z")
        )
        try journalStore.appendActivation(
            providerID: "openai-oauth",
            accountID: "acct_b",
            previousAccountID: "acct_a",
            reason: .autoThreshold,
            automatic: true,
            timestamp: self.date("2026-04-05T11:59:57Z")
        )

        try RuntimeSQLiteFixtureSupport.writeStateDatabase(
            at: CodexPaths.stateSQLiteURL,
            threads: [
                .init(
                    id: "thread-old-but-running-now",
                    source: "vscode",
                    cwd: "/repo/app",
                    title: "App thread",
                    createdAt: 1_775_389_000,
                    updatedAt: 1_775_390_399
                ),
                .init(
                    id: "thread-unknown",
                    source: "cli",
                    cwd: "/repo/cli",
                    title: "CLI thread",
                    createdAt: 1_775_389_100,
                    updatedAt: 1_775_390_396
                ),
                .init(
                    id: "thread-subagent",
                    source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"root","depth":1}}}"#,
                    cwd: "/repo/subagent",
                    title: "Subagent thread",
                    createdAt: 1_775_389_200,
                    updatedAt: 1_775_390_398
                ),
                .init(
                    id: "thread-stale",
                    source: "cli",
                    cwd: "/repo/stale",
                    title: "Stale thread",
                    createdAt: 1_775_389_300,
                    updatedAt: 1_775_390_390
                ),
            ]
        )
        try RuntimeSQLiteFixtureSupport.writeLogsDatabase(
            at: CodexPaths.logsSQLiteURL,
            logs: [
                .init(
                    threadID: "thread-old-but-running-now",
                    timestamp: 1_775_390_399,
                    target: "codex_api::endpoint::responses_websocket"
                ),
                .init(
                    threadID: "thread-unknown",
                    timestamp: 1_775_390_396,
                    target: "codex_api::sse::responses"
                ),
                .init(
                    threadID: "thread-subagent",
                    timestamp: 1_775_390_398,
                    target: "log",
                    body: "session_task.turn active"
                ),
                .init(
                    threadID: "thread-stale",
                    timestamp: 1_775_390_390,
                    target: "codex_api::endpoint::responses_websocket"
                ),
            ]
        )

        let attribution = OpenAIRunningThreadAttributionService(
            runtimeStore: runtimeStore,
            switchJournalStore: journalStore
        ).load(
            now: now,
            recentActivityWindow: 5
        )

        XCTAssertEqual(attribution.threads.map(\.threadID), [
            "thread-old-but-running-now",
            "thread-subagent",
            "thread-unknown",
        ])
        XCTAssertEqual(attribution.summary.runningThreadCount(for: "acct_b"), 2)
        XCTAssertEqual(attribution.summary.runningThreadCount(for: "acct_a"), 0)
        XCTAssertEqual(attribution.summary.unknownThreadCount, 1)
        XCTAssertEqual(attribution.summary.totalRunningThreadCount, 3)
    }

    func testLoadMarksUnavailableWhenRuntimeStoreCannotReadSqlite() {
        let unavailableStore = CodexThreadRuntimeStore(
            stateDBURL: CodexPaths.stateSQLiteURL,
            logsDBURL: CodexPaths.logsSQLiteURL
        )
        let attribution = OpenAIRunningThreadAttributionService(
            runtimeStore: unavailableStore,
            switchJournalStore: SwitchJournalStore(fileURL: CodexPaths.switchJournalURL)
        )
        .load(
            now: self.date("2026-04-05T12:00:00Z"),
            recentActivityWindow: 5
        )

        XCTAssertTrue(attribution.summary.isUnavailable)
        XCTAssertTrue(attribution.threads.isEmpty)
        XCTAssertNotNil(attribution.diagnosticMessage)
    }

    func testLoadExcludesThreadsOutsideRunningWindow() throws {
        try RuntimeSQLiteFixtureSupport.writeStateDatabase(
            at: CodexPaths.stateSQLiteURL,
            threads: [
                .init(
                    id: "thread-stale",
                    source: "vscode",
                    cwd: "/repo/stale",
                    title: "Stale thread",
                    createdAt: 1,
                    updatedAt: 1
                ),
            ]
        )
        try RuntimeSQLiteFixtureSupport.writeLogsDatabase(
            at: CodexPaths.logsSQLiteURL,
            logs: [
                .init(
                    threadID: "thread-stale",
                    timestamp: 1_775_390_390,
                    target: "codex_api::endpoint::responses_websocket"
                ),
            ]
        )

        let journalStore = SwitchJournalStore(fileURL: CodexPaths.switchJournalURL)
        try journalStore.appendActivation(
            providerID: "openai-oauth",
            accountID: "acct_a",
            timestamp: self.date("2026-04-05T11:59:50Z")
        )

        let attribution = OpenAIRunningThreadAttributionService(
            switchJournalStore: journalStore
        )
        .load(
            now: self.date("2026-04-05T12:00:00Z"),
            recentActivityWindow: 5
        )

        XCTAssertEqual(attribution.summary.totalRunningThreadCount, 0)
        XCTAssertEqual(attribution.summary.runningThreadCount(for: "acct_a"), 0)
        XCTAssertEqual(attribution.summary.unknownThreadCount, 0)
        XCTAssertTrue(attribution.threads.isEmpty)
    }

    func testLoadExcludesRecentlyCompletedSessionDespiteFreshRuntimeLog() throws {
        let now = self.date("2026-04-05T12:00:00Z")
        try RuntimeSQLiteFixtureSupport.writeStateDatabase(
            at: CodexPaths.stateSQLiteURL,
            threads: [
                .init(
                    id: "thread-completed",
                    source: "vscode",
                    cwd: "/repo/completed",
                    title: "Completed thread",
                    createdAt: 1,
                    updatedAt: 1
                ),
            ]
        )
        try RuntimeSQLiteFixtureSupport.writeLogsDatabase(
            at: CodexPaths.logsSQLiteURL,
            logs: [
                .init(
                    threadID: "thread-completed",
                    timestamp: 1_775_390_399,
                    target: "codex_api::endpoint::responses_websocket"
                ),
            ]
        )

        let sessionStore = self.makeSessionLogStore()
        try self.writeSession(
            id: "thread-completed",
            fileName: "thread-completed.jsonl",
            startedAt: "2026-04-05T11:59:50Z",
            taskStartedAt: "2026-04-05T11:59:56Z",
            taskCompletedAt: "2026-04-05T11:59:59Z",
            modificationDate: self.date("2026-04-05T11:59:59Z")
        )

        let attribution = OpenAIRunningThreadAttributionService(
            runtimeStore: self.makeRuntimeStore(),
            sessionLogStore: sessionStore,
            switchJournalStore: SwitchJournalStore(fileURL: CodexPaths.switchJournalURL)
        )
        .load(
            now: now,
            recentActivityWindow: 5
        )

        XCTAssertEqual(attribution.summary.totalRunningThreadCount, 0)
        XCTAssertEqual(attribution.summary.unknownThreadCount, 0)
        XCTAssertTrue(attribution.threads.isEmpty)
    }

    func testLoadKeepsThreadWhenLatestSessionLifecycleIsStillRunning() throws {
        let now = self.date("2026-04-05T12:00:00Z")
        try RuntimeSQLiteFixtureSupport.writeStateDatabase(
            at: CodexPaths.stateSQLiteURL,
            threads: [
                .init(
                    id: "thread-running",
                    source: "vscode",
                    cwd: "/repo/running",
                    title: "Running thread",
                    createdAt: 1,
                    updatedAt: 1
                ),
            ]
        )
        try RuntimeSQLiteFixtureSupport.writeLogsDatabase(
            at: CodexPaths.logsSQLiteURL,
            logs: [
                .init(
                    threadID: "thread-running",
                    timestamp: 1_775_390_399,
                    target: "codex_api::endpoint::responses_websocket"
                ),
            ]
        )

        let sessionStore = self.makeSessionLogStore()
        try self.writeSession(
            id: "thread-running",
            fileName: "thread-running.jsonl",
            startedAt: "2026-04-05T11:59:50Z",
            taskStartedAt: "2026-04-05T11:59:56Z",
            taskCompletedAt: nil,
            modificationDate: self.date("2026-04-05T11:59:59Z")
        )

        let attribution = OpenAIRunningThreadAttributionService(
            runtimeStore: self.makeRuntimeStore(),
            sessionLogStore: sessionStore,
            switchJournalStore: SwitchJournalStore(fileURL: CodexPaths.switchJournalURL)
        )
        .load(
            now: now,
            recentActivityWindow: 5
        )

        XCTAssertEqual(attribution.summary.totalRunningThreadCount, 1)
        XCTAssertEqual(attribution.threads.map(\.threadID), ["thread-running"])
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
    }

    private func makeRuntimeStore() -> CodexThreadRuntimeStore {
        CodexThreadRuntimeStore(
            stateDBURL: CodexPaths.stateSQLiteURL,
            logsDBURL: CodexPaths.logsSQLiteURL
        )
    }

    private func makeSessionLogStore() -> SessionLogStore {
        SessionLogStore(
            codexRootURL: CodexPaths.codexRoot,
            persistedCacheURL: CodexPaths.costSessionCacheURL
        )
    }

    private func writeSession(
        id: String,
        fileName: String,
        startedAt: String,
        taskStartedAt: String,
        taskCompletedAt: String?,
        modificationDate: Date
    ) throws {
        let directory = CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let fileURL = directory.appendingPathComponent(fileName)
        var lines = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(startedAt)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"\#(taskStartedAt)","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-\#(id)"}}"#,
            #"{"timestamp":"\#(taskStartedAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50}}}}"#,
        ]
        if let taskCompletedAt {
            lines.append(
                #"{"timestamp":"\#(taskCompletedAt)","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-\#(id)","last_agent_message":null}}"#
            )
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: fileURL.path
        )
    }
}
