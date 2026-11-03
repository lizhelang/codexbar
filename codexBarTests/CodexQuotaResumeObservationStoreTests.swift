import Foundation
import SQLite3
import XCTest

final class CodexQuotaResumeObservationStoreTests: XCTestCase {
    private var fixtures: [QuotaObservationFixture] = []
    private let operationID = "7a2042ef-a1bc-44d7-890a-8415ac8a8518"

    override func tearDownWithError() throws {
        for fixture in self.fixtures { try FileManager.default.removeItem(at: fixture.root) }
        self.fixtures = []
        try super.tearDownWithError()
    }

    func testStructuredQuotaFailureUsesCurrentProjectionAndLeavesSourcesUnchanged() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        let before = try fixture.sourceBytes()

        let observation = try fixture.observe()

        XCTAssertEqual(observation.phase, .quotaBlocked)
        XCTAssertEqual(observation.turnID, "turn-1")
        XCTAssertEqual(observation.quotaFailureAt, fixture.now)
        XCTAssertTrue(observation.isCurrent)
        XCTAssertEqual(observation.queuedMessageCount, 0)
        XCTAssertEqual(observation.source, "vscode")
        XCTAssertEqual(observation.originator, "Codex Desktop")
        XCTAssertEqual(observation.modelProvider, "codexbar.openai-oauth")
        XCTAssertEqual(observation.creatorAccountID, "creator-account")
        XCTAssertNil(observation.executionAccountID, "创建身份不能冒充执行身份")
        XCTAssertEqual(try fixture.sourceBytes(), before)
    }

    func testLatestManualInterruptionSupersedesPreviousQuotaFailure() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        try fixture.writeTurn(id: "turn-2", ordinal: 20, status: "interrupted")

        let observation = try fixture.observe()

        XCTAssertEqual(observation.turnID, "turn-2")
        XCTAssertEqual(observation.phase, .interrupted)
        XCTAssertNil(observation.quotaFailureAt)
        XCTAssertTrue(observation.isCurrent)
    }

    func testErrorCodeDoesNotOverrideNonFailedTurnStatusOrUnknownCodes() throws {
        for (status, code, expected) in [
            ("completed", "usageLimitExceeded", CodexQuotaResumeObservationStore.Phase.completed),
            ("inProgress", "usageLimitExceeded", .inProgress),
            ("interrupted", "usageLimitExceeded", .interrupted),
            ("failed", "rateLimitExceeded", .failed),
            ("failed", "unauthorized", .failed),
            ("newFutureStatus", "usageLimitExceeded", .unknown),
        ] {
            let fixture = try self.fixture()
            try fixture.writeTurn(status: status, errorCode: code)
            let observation = try fixture.observe()
            XCTAssertEqual(observation.phase, expected, status + "/" + code)
            XCTAssertNil(observation.quotaFailureAt)
        }
    }

    func testQuotaFailureWithoutCompletionTimeCannotBecomeCandidate() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded", completed: false)
        XCTAssertEqual(try fixture.observe().phase, .failed)
    }

    func testMissingQueueIsUnavailableRatherThanEmpty() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        try FileManager.default.removeItem(at: fixture.queueURL)

        let observation = try fixture.observe()

        XCTAssertEqual(observation.phase, .quotaBlocked)
        XCTAssertNil(observation.queuedMessageCount)
        XCTAssertFalse(observation.isCurrent)
        XCTAssertNotNil(observation.unavailableReason)
    }

    func testExistingQueuedMessageAndRevisionAreVisible() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        let before = try fixture.observe()
        try fixture.queueMessage()

        let after = try fixture.observe()

        XCTAssertEqual(after.queuedMessageCount, 1)
        XCTAssertNotEqual(before.revision, after.revision)
    }

    func testLaggingProjectionCannotActOnAnOldQuotaFailure() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        try fixture.appendEvent("task_started", turnID: "turn-2", updateProjection: false)

        let observation = try fixture.observe()

        XCTAssertFalse(observation.isCurrent)
        XCTAssertNotNil(observation.unavailableReason)
    }

    func testFullyProjectedStopAfterTurnStillCancelsQuotaFailure() throws {
        for event in ["turn_aborted", "task_cancelled"] {
            let fixture = try self.fixture()
            try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
            try fixture.appendEvent(event, turnID: "turn-1")

            let observation = try fixture.observe()

            XCTAssertEqual(observation.phase, .interrupted)
            XCTAssertNil(observation.quotaFailureAt)
        }
    }

    func testPausedGoalAfterTurnCannotResume() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        try fixture.appendRecord(fixture.event("thread_goal_updated", extra: ["goal": ["status": "paused"]]))
        try fixture.projectAll()

        XCTAssertEqual(try fixture.observe().phase, .interrupted)
    }

    func testPersistedGoalStopsOverrideQuotaFailureWithoutReadingObjective() throws {
        for status in ["paused", "blocked", "budget_limited", "complete"] {
            let fixture = try self.fixture()
            try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
            try fixture.writeGoal(status: status)
            let observation = try fixture.observe()
            XCTAssertEqual(observation.phase, .interrupted, status)
            XCTAssertNil(observation.quotaFailureAt)
        }
    }

    func testGoalAndThreadMetadataChangesInvalidateObservationRevision() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        let initial = try fixture.observe()
        try fixture.writeGoal(status: "usage_limited")
        let withGoal = try fixture.observe()
        XCTAssertEqual(withGoal.phase, .quotaBlocked)
        XCTAssertNotEqual(initial.revision, withGoal.revision)
        try fixture.execute("DELETE FROM thread_goals", database: fixture.goalsURL)
        let cleared = try fixture.observe()
        XCTAssertNotEqual(withGoal.revision, cleared.revision)
        try fixture.execute("UPDATE threads SET model = 'gpt-reserve'", database: fixture.stateURL)
        XCTAssertNotEqual(cleared.revision, try fixture.observe().revision)
    }

    func testUnreadableGoalSchemaPreventsAutomaticContinuation() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        try fixture.execute("CREATE TABLE future_goal_store (id TEXT)", database: fixture.goalsURL)
        XCTAssertFalse(try fixture.observe().isCurrent)
    }

    func testNewInputAfterProjectedTurnPreventsSending() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        try fixture.appendEvent("user_message", turnID: "turn-2")

        XCTAssertFalse(try fixture.observe().isCurrent)
    }

    func testMissingOrOutOfBoundsEndPositionIsUnavailable() throws {
        for value in ["NULL", "-1", "99999999"] {
            let fixture = try self.fixture()
            try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
            try fixture.execute("UPDATE thread_turns SET rollout_end_byte_offset = \(value)", database: fixture.historyURL)
            XCTAssertFalse(try fixture.observe().isCurrent, value)
        }
    }

    func testContinuationMarkerIsBoundToLatestTurnsFirstUserItem() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "completed", firstUserItemID: "old-input")
        try fixture.writeItem(id: "old-input", text: "恢复标记：codexbar-resume:\(self.operationID)")
        XCTAssertEqual(try fixture.observe().continuationOperationID, self.operationID)

        try fixture.writeTurn(id: "turn-2", ordinal: 20, status: "completed", firstUserItemID: "new-input")
        try fixture.writeItem(id: "new-input", turnID: "turn-2", text: "普通的后续问题")
        try fixture.writeItem(id: "assistant-output", turnID: "turn-2", type: "agentMessage", text: "codexbar-resume:\(self.operationID)")

        XCTAssertNil(try fixture.observe().continuationOperationID, "旧轮次和助手复述不证明新轮次接收了续跑")
    }

    func testMarkerAcceptsCaseNormalizedUUIDButRejectsAmbiguousOrMalformedMarkers() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "completed", firstUserItemID: "user-input")
        try fixture.writeItem(id: "user-input", text: "恢复标记：codexbar-resume:\(self.operationID.uppercased())")
        XCTAssertEqual(try fixture.observe().continuationOperationID, self.operationID)

        try fixture.writeItem(id: "user-input", text: "codexbar-resume:\(self.operationID)\ncodexbar-resume:80be7d11-b498-4c42-a672-5fb0ffce4204")
        XCTAssertNil(try fixture.observe().continuationOperationID)
        try fixture.writeItem(id: "user-input", text: "codexbar-resume:invalid")
        XCTAssertNil(try fixture.observe().continuationOperationID)
    }

    func testTextMentionOfQuotaNeverCreatesQuotaFailure() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "completed", firstUserItemID: "user-input")
        try fixture.writeItem(id: "user-input", text: "usageLimitExceeded: 请在五小时后继续")

        XCTAssertEqual(try fixture.observe().phase, .completed)
    }

    func testLatestTurnAgentTextAndCompletedWorkItemsReportProgress() throws {
        for item in [
            ["type": "agentMessage", "text": "已检查相关文件"],
            ["type": "commandExecution", "status": "completed"],
            ["type": "fileChange", "status": "completed"],
            ["type": "mcpToolCall", "status": "completed"],
            ["type": "dynamicToolCall", "status": "completed"],
        ] {
            let fixture = try self.fixture()
            try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
            try fixture.writeRawItem(id: "progress", item: item)
            let observation = try fixture.observe()
            XCTAssertTrue(observation.hasAgentProgress, item["type"] ?? "")
            XCTAssertEqual(observation.phase, .quotaBlocked, "进展只用于续跑周期判定，不能改写失败原因")
        }
    }

    func testEmptyAgentTextQueuedInputReasoningAndUnfinishedWorkAreNotProgress() throws {
        for item: [String: Any] in [
            ["type": "agentMessage", "text": " \t\r\n"],
            ["type": "agentMessage", "text": 1],
            ["type": "userMessage", "text": "继续"],
            ["type": "reasoning", "text": "分析中"],
            ["type": "commandExecution", "status": "inProgress"],
            ["type": "fileChange", "status": "declined"],
            ["type": "mcpToolCall", "status": "failed"],
            ["type": "futureItem", "status": "completed"],
        ] {
            let fixture = try self.fixture()
            try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
            try fixture.writeRawItem(id: "no-progress", item: item)
            XCTAssertFalse(try fixture.observe().hasAgentProgress)
        }
    }

    func testProgressCannotLeakFromAnEarlierTurnAndUnavailableItemsStayFalse() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "completed")
        try fixture.writeRawItem(id: "old-progress", item: ["type": "agentMessage", "text": "已完成检查"])
        try fixture.writeTurn(id: "turn-2", ordinal: 20, status: "failed", errorCode: "usageLimitExceeded")
        XCTAssertFalse(try fixture.observe().hasAgentProgress)
        try fixture.execute("DROP TABLE thread_items", database: fixture.historyURL)
        XCTAssertFalse(try fixture.observe().hasAgentProgress)
    }

    func testArchivedAndSubagentMetadataRemainExplicit() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        try fixture.execute("UPDATE threads SET archived = 1, source = '{\"subagent\":\"compact\"}'", database: fixture.stateURL)

        let observation = try fixture.observe()

        XCTAssertEqual(observation.phase, .archived)
        XCTAssertTrue(observation.isSubagent)
        XCTAssertNil(observation.quotaFailureAt)
    }

    func testLookbackIncludesExplicitlyTrackedOldThreads() throws {
        let fixture = try self.fixture()
        try fixture.writeTurn(status: "completed")
        let store = fixture.store
        XCTAssertTrue(try store.load(since: fixture.now.addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(try store.load(since: fixture.now.addingTimeInterval(60), includingThreadIDs: [fixture.threadID]).count, 1)
    }

    func testLegacyRequiresMatchingStructuredErrorAndFailedTerminalEvent() throws {
        let fixture = try self.fixture(historyMode: "legacy")
        try fixture.replaceRecords([
            fixture.event("task_started", turnID: "legacy-turn"),
            fixture.event("user_message", extra: ["message": "恢复标记：codexbar-resume:\(self.operationID)"]),
            fixture.event("error", turnID: "legacy-turn", extra: ["codex_error_info": "usage_limit_exceeded", "will_retry": false]),
            fixture.event("task_failed", turnID: "legacy-turn"),
        ])

        let observation = try fixture.observe()

        XCTAssertEqual(observation.phase, .quotaBlocked)
        XCTAssertTrue(observation.isCurrent)
        XCTAssertEqual(observation.continuationOperationID, self.operationID)
        try fixture.appendEvent("task_cancelled", turnID: "legacy-turn")
        XCTAssertEqual(try fixture.observe().phase, .interrupted)
    }

    func testLegacyRetryOrUnrelatedErrorIsNotQuotaFailure() throws {
        for (errorTurn, retry) in [("legacy-turn", true), ("other-turn", false)] {
            let fixture = try self.fixture(historyMode: "legacy")
            try fixture.replaceRecords([
                fixture.event("task_started", turnID: "legacy-turn"),
                fixture.event("error", turnID: errorTurn, extra: ["codex_error_info": "usage_limit_exceeded", "will_retry": retry]),
                fixture.event("task_failed", turnID: "legacy-turn"),
            ])
            XCTAssertEqual(try fixture.observe().phase, .failed)
        }
    }

    func testLegacyCurrentTurnAgentMessagesAndCompletedWorkReportProgress() throws {
        let cases: [(String, [String: Any])] = [
            ("agent_message", ["message": "已检查输入文件"]),
            ("item_completed", ["item": ["type": "AgentMessage", "content": [["type": "Text", "text": "已完成检查"]]]]),
            ("item_completed", ["item": ["type": "CommandExecution", "status": "completed"]]),
            ("item_completed", ["item": ["type": "FileChange", "status": "completed"]]),
            ("item_completed", ["item": ["type": "McpToolCall", "status": "completed"]]),
        ]
        for (event, extra) in cases {
            let fixture = try self.fixture(historyMode: "legacy")
            try fixture.replaceRecords(fixture.legacyQuotaTurnRecords(
                operationID: self.operationID,
                progress: [fixture.event(event, turnID: "legacy-turn", extra: extra)]))

            let observation = try fixture.observe()

            XCTAssertTrue(observation.hasAgentProgress, String(describing: extra))
            XCTAssertEqual(observation.phase, .quotaBlocked, "识别进展不能改写结构化额度失败")
            XCTAssertTrue(observation.isCurrent)
            XCTAssertEqual(observation.continuationOperationID, self.operationID)
        }
    }

    func testLegacyAgentMessageWithoutIDRequiresAnActiveTurn() throws {
        let fixture = try self.fixture(historyMode: "legacy")
        let message = fixture.event("agent_message", extra: ["message": "已检查输入文件"])
        try fixture.replaceRecords(fixture.legacyQuotaTurnRecords(progress: [message]))
        XCTAssertTrue(try fixture.observe().hasAgentProgress)

        try fixture.replaceRecords([message] + fixture.legacyQuotaTurnRecords())
        XCTAssertFalse(try fixture.observe().hasAgentProgress, "轮次开始前的消息没有当前轮次归属")
        try fixture.replaceRecords(fixture.legacyQuotaTurnRecords() + [message])
        XCTAssertFalse(try fixture.observe().hasAgentProgress, "终态之后的无身份消息不能冒充本轮工作")

        var malformed = message
        malformed["payload"] = ["type": "agent_message", "message": "未知轮次消息", "turn_id": 1]
        try fixture.replaceRecords(fixture.legacyQuotaTurnRecords(progress: [malformed]))
        XCTAssertFalse(try fixture.observe().hasAgentProgress, "无法识别的轮次身份不等于省略身份")
    }

    func testLegacyEmptyMessagesReasoningAndUnfinishedWorkAreNotProgress() throws {
        let cases: [(String, [String: Any])] = [
            ("agent_message", ["message": " \t\r\n"]),
            ("agent_message", ["message": 1]),
            ("agent_reasoning", ["text": "分析中"]),
            ("user_message", ["message": "继续"]),
            ("item_completed", ["item": ["type": "AgentMessage", "content": [["type": "Text", "text": " \n"]]]]),
            ("item_completed", ["item": ["type": "AgentMessage", "content": [["type": "Image", "text": "非文本"]]]]),
            ("item_completed", ["item": ["type": "Reasoning", "summary_text": ["分析中"]]]),
            ("item_completed", ["item": ["type": "UserMessage", "content": [["type": "text", "text": "继续"]]]]),
            ("item_started", ["item": ["type": "CommandExecution", "status": "completed"]]),
            ("item_completed", ["item": ["type": "CommandExecution", "status": "in_progress"]]),
            ("item_completed", ["item": ["type": "CommandExecution", "status": "failed"]]),
            ("item_completed", ["item": ["type": "CommandExecution"]]),
            ("item_completed", ["item": ["type": "McpToolCall", "status": "failed"]]),
            ("item_completed", ["item": ["type": "FileChange", "status": "declined"]]),
            ("item_completed", ["item": ["type": "FunctionCallOutput", "output": "queued"]]),
            ("item_completed", ["item": ["type": "FutureItem", "status": "completed"]]),
        ]
        for (event, extra) in cases {
            let fixture = try self.fixture(historyMode: "legacy")
            try fixture.replaceRecords(fixture.legacyQuotaTurnRecords(
                progress: [fixture.event(event, turnID: "legacy-turn", extra: extra)]))
            XCTAssertFalse(try fixture.observe().hasAgentProgress, String(describing: extra))
        }
    }

    func testLegacyProgressCannotLeakFromEarlierTurnOrMismatchedEvents() throws {
        for boundary in ["task_started", "turn_context"] {
            let fixture = try self.fixture(historyMode: "legacy")
            let start = boundary == "task_started"
                ? fixture.event("task_started", turnID: "legacy-turn")
                : ["timestamp": fixture.now.formatted(.iso8601), "type": "turn_context", "payload": ["turn_id": "legacy-turn"]]
            let oldProgress = fixture.event("agent_message", turnID: "old-turn", extra: ["message": "上一轮已完成工作"])
            let lateWork = fixture.event("item_completed", turnID: "old-turn", extra: ["item": ["type": "CommandExecution", "status": "completed"]])
            try fixture.replaceRecords([
                fixture.event("task_started", turnID: "old-turn"), oldProgress,
                fixture.event("task_complete", turnID: "old-turn"), start, oldProgress, lateWork,
                fixture.event("error", turnID: "legacy-turn", extra: ["codex_error_info": "usage_limit_exceeded", "will_retry": false]),
                fixture.event("task_failed", turnID: "legacy-turn"),
            ])
            let observation = try fixture.observe()
            XCTAssertEqual(observation.turnID, "legacy-turn")
            XCTAssertEqual(observation.phase, .quotaBlocked)
            XCTAssertFalse(observation.hasAgentProgress, boundary)
        }
    }

    func testLegacyCompletedWorkNeedsMatchingTurnAndCannotArriveAfterFailure() throws {
        let fixture = try self.fixture(historyMode: "legacy")
        let work: [String: Any] = ["item": ["type": "CommandExecution", "status": "completed"]]
        for turnID: String? in [nil, "other-turn"] {
            try fixture.replaceRecords(fixture.legacyQuotaTurnRecords(
                progress: [fixture.event("item_completed", turnID: turnID, extra: work)]))
            XCTAssertFalse(try fixture.observe().hasAgentProgress)
        }
        try fixture.replaceRecords(fixture.legacyQuotaTurnRecords()
            + [fixture.event("item_completed", turnID: "legacy-turn", extra: work)])
        XCTAssertFalse(try fixture.observe().hasAgentProgress)
    }

    @MainActor
    func testLegacySecondQuotaCycleAfterProgressCanResumeAcrossRestartWithoutDuplicates() async throws {
        for progressKind in ["agent_message", "completed_work", "none"] {
            let fixture = try self.fixture(historyMode: "legacy")
            try fixture.replaceRecords(fixture.legacyQuotaTurnRecords(turnID: "initial-failure"))
            let bridge = LegacyQuotaResumeBridgeStub()
            var now = fixture.now
            var decision: CodexQuotaResumeQuota.Decision = .allowed
            func makeCoordinator() -> CodexQuotaResumeCoordinator {
                CodexQuotaResumeCoordinator(storageURL: fixture.root.appendingPathComponent("resume.json"),
                    list: { _, _ in [try fixture.observe()] }, read: { _ in try fixture.observe() },
                    quota: { _, _ in decision }, identityIsValid: { $0 == "confirmed-account" }, bridge: bridge,
                    resolveDesktopAccount: { .resolved(accountID: "confirmed-account") }, now: { now })
            }
            let initial = makeCoordinator()
            initial.configure(enabled: true, accountID: "confirmed-account")
            await initial.refreshThreads()
            initial.watch(threadID: fixture.threadID)
            await initial.checkNow()
            let first = try XCTUnwrap(initial.state.entries.first)
            XCTAssertEqual(bridge.operationIDs.count, 1)
            initial.stop()

            // 应用未运行期间，已恢复的同一轮次做了工作后再次限额；重启时额度已恢复。
            now.addTimeInterval(20_000)
            let progress: [[String: Any]]
            switch progressKind {
            case "agent_message":
                progress = [fixture.event("agent_message", turnID: "resumed-turn", extra: ["message": "已完成下一阶段检查"])]
            case "completed_work":
                progress = [fixture.event("item_completed", turnID: "resumed-turn",
                    extra: ["item": ["type": "CommandExecution", "status": "completed"]])]
            default: progress = []
            }
            try fixture.replaceRecords(fixture.legacyQuotaTurnRecords(turnID: "resumed-turn",
                operationID: first.id.uuidString, progress: progress))
            let restarted = makeCoordinator()
            defer { restarted.stop() }
            await restarted.checkNow()
            XCTAssertEqual(restarted.state.entries.count, 2)
            if progressKind == "none" {
                XCTAssertEqual(bridge.operationIDs.count, 1, "没有真实进展的即时失败必须等待新的 blocked 证据")
                XCTAssertEqual(restarted.state.entries.last?.status, .needsAttention)
                now.addTimeInterval(61)
                decision = .blocked(nextCheckAt: now.addingTimeInterval(300))
                await restarted.checkNow()
                now.addTimeInterval(301)
                decision = .allowed
                await restarted.checkNow()
            }
            XCTAssertEqual(bridge.operationIDs.count, 2, progressKind)
            XCTAssertEqual(restarted.state.entries.last?.status, .queued, progressKind)
            restarted.stop()

            let again = makeCoordinator()
            defer { again.stop() }
            await again.checkNow()
            XCTAssertEqual(bridge.operationIDs.count, 2, "同一恢复操作跨重启不得重复发送")
            XCTAssertEqual(Set(bridge.operationIDs).count, 2)
        }
    }

    func testIncompleteLegacyRecordAndOutOfRootPathAreUnavailable() throws {
        let fixture = try self.fixture(historyMode: "legacy")
        try Data("{\"type\":\"event_msg\"".utf8).write(to: fixture.rolloutURL)
        XCTAssertFalse(try fixture.observe().isCurrent)
        try fixture.execute("UPDATE threads SET rollout_path = '/private/tmp/outside.jsonl'", database: fixture.stateURL)
        XCTAssertFalse(try fixture.observe().isCurrent)
    }

    func testUnknownHistoryFormatDoesNotFallBackToLegacy() throws {
        let fixture = try self.fixture(historyMode: "future-format")
        try fixture.writeTurn(status: "failed", errorCode: "usageLimitExceeded")
        XCTAssertFalse(try fixture.observe().isCurrent)
    }

    private func fixture(historyMode: String = "paginated") throws -> QuotaObservationFixture {
        let fixture = try QuotaObservationFixture(historyMode: historyMode)
        self.fixtures.append(fixture)
        return fixture
    }
}

private final class QuotaObservationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-quota-observer-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_793_500_000)
    let threadID = "cad79f88-47aa-43f7-96f8-ecc5740e365c"
    var stateURL: URL { self.root.appendingPathComponent("state_5.sqlite") }
    var historyURL: URL { self.root.appendingPathComponent("thread_history_1.sqlite") }
    var queueURL: URL { self.root.appendingPathComponent("queue_1.sqlite") }
    var goalsURL: URL { self.root.appendingPathComponent("goals_1.sqlite") }
    var rolloutURL: URL { self.root.appendingPathComponent("sessions/test.jsonl") }
    var store: CodexQuotaResumeObservationStore { .init(codexRootURL: self.root) }

    init(historyMode: String) throws {
        try FileManager.default.createDirectory(at: self.rolloutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.replaceRecords([self.event("task_complete", turnID: "turn-1")])
        try self.execute("""
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT, cwd TEXT,
                title TEXT, archived INTEGER, created_at INTEGER, updated_at INTEGER, model_provider TEXT,
                model TEXT, creator_account_id TEXT, history_mode TEXT, name TEXT, attached_thread_parent_id TEXT, originator TEXT);
            INSERT INTO threads VALUES (\(self.quote(self.threadID)), \(self.quote(self.rolloutURL.path)), 'vscode', '/fixture/project',
                '测试会话', 0, 1793490000, 1793500000, 'codexbar.openai-oauth', 'gpt-6.1-sol', 'creator-account',
                \(self.quote(historyMode)), NULL, NULL, 'Codex Desktop');
            """, database: self.stateURL)
        try self.execute("""
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT,
                error_json TEXT, started_at INTEGER, completed_at INTEGER, rollout_end_byte_offset INTEGER,
                first_user_item_id TEXT, PRIMARY KEY(thread_id, turn_id));
            CREATE TABLE thread_history_projection_state (thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER);
            CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_id TEXT, item_json TEXT,
                PRIMARY KEY(thread_id, turn_id, item_id));
            """, database: self.historyURL)
        try self.execute("""
            CREATE TABLE queued_items (thread_id TEXT);
            CREATE TABLE queued_thread_revisions (thread_id TEXT PRIMARY KEY, revision INTEGER);
            """, database: self.queueURL)
    }

    func observe() throws -> CodexQuotaResumeObservationStore.Observation {
        try XCTUnwrap(self.store.observation(threadID: self.threadID, now: self.now))
    }

    func sourceBytes() throws -> [Data] {
        try [self.stateURL, self.historyURL, self.queueURL, self.rolloutURL].map { try Data(contentsOf: $0) }
    }

    func writeTurn(
        id: String = "turn-1", ordinal: Int = 1, status: String, errorCode: String? = nil,
        completed: Bool = true, firstUserItemID: String? = nil
    ) throws {
        let error = try errorCode.map { try JSONSerialization.data(withJSONObject: ["codexErrorInfo": $0]) }
            .map { String(decoding: $0, as: UTF8.self) }
        let size = try Data(contentsOf: self.rolloutURL).count
        try self.execute("""
            INSERT OR REPLACE INTO thread_turns VALUES (\(self.quote(self.threadID)), \(self.quote(id)), \(ordinal),
                \(self.quote(status)), \(self.quote(error)), 1793499990, \(completed ? "1793500000" : "NULL"),
                \(size), \(self.quote(firstUserItemID)));
            """, database: self.historyURL)
        try self.projectAll()
    }

    func writeItem(id: String, turnID: String = "turn-1", type: String = "userMessage", text: String) throws {
        let item: [String: Any] = ["type": type, "id": id, "content": [["type": "text", "text": text]]]
        try self.writeRawItem(id: id, turnID: turnID, item: item)
    }

    func writeRawItem(id: String, turnID: String = "turn-1", item: [String: Any]) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: item), as: UTF8.self)
        try self.execute("""
            INSERT OR REPLACE INTO thread_items VALUES (\(self.quote(self.threadID)), \(self.quote(turnID)),
                \(self.quote(id)), \(self.quote(json)));
            """, database: self.historyURL)
    }

    func queueMessage() throws {
        try self.execute("""
            INSERT INTO queued_items VALUES (\(self.quote(self.threadID)));
            INSERT OR REPLACE INTO queued_thread_revisions VALUES (\(self.quote(self.threadID)), 1);
            """, database: self.queueURL)
    }

    func writeGoal(status: String) throws {
        try self.execute("""
            CREATE TABLE IF NOT EXISTS thread_goals (thread_id TEXT PRIMARY KEY, goal_id TEXT, status TEXT, updated_at_ms INTEGER);
            INSERT OR REPLACE INTO thread_goals VALUES (\(self.quote(self.threadID)), 'goal-1', \(self.quote(status)), 1793500000000);
            """, database: self.goalsURL)
    }

    func projectAll() throws {
        let size = try Data(contentsOf: self.rolloutURL).count
        try self.execute("""
            INSERT OR REPLACE INTO thread_history_projection_state VALUES (\(self.quote(self.threadID)), \(size));
            """, database: self.historyURL)
    }

    func event(_ name: String, turnID: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var payload = extra
        payload["type"] = name
        payload["turn_id"] = turnID
        return ["timestamp": self.now.formatted(.iso8601), "type": "event_msg", "payload": payload]
    }

    func legacyQuotaTurnRecords(
        turnID: String = "legacy-turn", operationID: String? = nil, progress: [[String: Any]] = []
    ) -> [[String: Any]] {
        var records = [self.event("task_started", turnID: turnID)]
        if let operationID {
            records.append(self.event("user_message", turnID: turnID,
                extra: ["message": "恢复标记：codexbar-resume:\(operationID)"]))
        }
        records += progress
        records += [
            self.event("error", turnID: turnID, extra: ["codex_error_info": "usage_limit_exceeded", "will_retry": false]),
            self.event("task_failed", turnID: turnID),
        ]
        return records
    }

    func appendEvent(_ name: String, turnID: String, updateProjection: Bool = true) throws {
        try self.appendRecord(self.event(name, turnID: turnID))
        if updateProjection { try self.projectAll() }
    }

    func appendRecord(_ record: [String: Any]) throws {
        let handle = try FileHandle(forWritingTo: self.rolloutURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self.encodeRecord(record))
    }

    func replaceRecords(_ records: [[String: Any]]) throws {
        var data = Data()
        for record in records { data.append(try self.encodeRecord(record)) }
        try data.write(to: self.rolloutURL)
    }

    private func encodeRecord(_ record: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        return data
    }

    func execute(_ sql: String, database url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "QuotaObservationFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "QuotaObservationFixture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }

    private func quote(_ value: String?) -> String {
        value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
    }
}

@MainActor
private final class LegacyQuotaResumeBridgeStub: CodexThreadContinuing {
    var operationIDs: [UUID] = []

    func capability() -> CodexThreadContinuationBridge.Capability {
        .available(appURL: URL(fileURLWithPath: "/fixture.app"), cliURL: URL(fileURLWithPath: "/fixture-cli"))
    }

    func enqueue(
        threadID: String, operationID: UUID, authorize: @escaping @MainActor () -> Bool
    ) async -> CodexThreadContinuationBridge.Outcome {
        guard authorize() else { return .notDispatched(reason: "cancelled") }
        self.operationIDs.append(operationID)
        return .queued(.init(threadID: threadID, operationID: operationID,
            messageID: UUID().uuidString, queuedAt: Date(), wakeRequested: true))
    }
}
