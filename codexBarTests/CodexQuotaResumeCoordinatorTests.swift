import Foundation
import XCTest

@MainActor
final class CodexQuotaResumeCoordinatorTests: CodexBarTestCase {
    func testCurrentDesktopOptionEnablesAndPinsResolvedAccount() {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        c.configure(enabled: true, accountID: nil)
        XCTAssertTrue(c.state.enabled)
        XCTAssertEqual(c.state.accountID, "account")
        XCTAssertNil(c.errorMessage)
    }

    func testUnresolvedCurrentDesktopOptionExplainsActualFailure() {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        f.accountResolution = .unavailable(reason: "无法读取桌面登录身份")
        let c = f.makeCoordinator()
        defer { c.stop() }
        c.configure(enabled: true, accountID: nil)
        XCTAssertFalse(c.state.enabled)
        XCTAssertEqual(c.errorMessage, "无法读取桌面登录身份")
        XCTAssertFalse(c.errorMessage?.contains("聚合") == true)
    }

    func testExplicitWrongAccountDoesNotFallBackToAutomaticOrReportAggregateMode() {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        f.identityValid = false
        let c = f.makeCoordinator()
        defer { c.stop() }
        c.configure(enabled: true, accountID: "wrong-account")
        XCTAssertFalse(c.state.enabled)
        XCTAssertTrue(c.errorMessage?.contains("不一致") == true)
        XCTAssertFalse(c.errorMessage?.contains("聚合") == true)
        c.accountSelectionDidChange()
        XCTAssertNil(c.errorMessage)
    }

    func testQuotaResetContinuesOriginalThreadExactlyOnce() async throws {
        let fixture = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let coordinator = fixture.makeCoordinator()
        defer { coordinator.stop() }
        await fixture.enable(coordinator)
        fixture.decision = .blocked(nextCheckAt: fixture.now.addingTimeInterval(300))
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.state.entries.count, 1)
        XCTAssertTrue(fixture.bridge.calls.isEmpty)
        fixture.now.addTimeInterval(301)
        fixture.decision = .allowed
        await coordinator.checkNow()
        let entry = try XCTUnwrap(coordinator.state.entries.first)
        XCTAssertEqual(entry.status, .queued)
        XCTAssertEqual(fixture.bridge.calls.count, 1)
        XCTAssertEqual(fixture.bridge.calls.first?.0, fixture.threadID)
        await coordinator.checkNow()
        XCTAssertEqual(fixture.bridge.calls.count, 1)
        fixture.observation = fixture.makeObservation(phase: .inProgress, turnID: "resumed-turn", operationID: entry.id)
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.state.entries.first?.status, .resumed)
    }

    func testManualStopBeforeResetCancelsWithoutResurrectingAfterRestart() async throws {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        var c = f.makeCoordinator()
        await f.enable(c)
        f.decision = .blocked(nextCheckAt: f.now.addingTimeInterval(300))
        await c.checkNow()
        f.observation = f.makeObservation(phase: .interrupted)
        f.now.addTimeInterval(301)
        f.decision = .allowed
        await c.checkNow()
        XCTAssertEqual(c.state.entries.first?.status, .cancelled)
        c.stop()
        c = f.makeCoordinator()
        defer { c.stop() }
        await c.checkNow()
        XCTAssertTrue(f.bridge.calls.isEmpty)
        XCTAssertEqual(c.state.entries.first?.status, .cancelled)
    }

    func testCancellationTombstoneSurvivesRestartEvenWhenOldQuotaFailureRemains() async throws {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        await f.enable(c)
        f.decision = .blocked(nextCheckAt: f.now.addingTimeInterval(300))
        await c.checkNow()
        c.cancel(try XCTUnwrap(c.state.entries.first?.id))
        c.stop()
        let restarted = f.makeCoordinator()
        defer { restarted.stop() }
        f.now.addTimeInterval(600)
        f.decision = .allowed
        await restarted.checkNow()
        XCTAssertTrue(f.bridge.calls.isEmpty)
        XCTAssertEqual(restarted.state.entries.count, 1)
        XCTAssertEqual(restarted.state.entries.first?.status, .cancelled)
    }

    func testRestartAfterQueueReceiptDoesNotQueueAgain() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        await f.enable(c)
        await c.checkNow()
        c.stop()
        let restarted = f.makeCoordinator()
        defer { restarted.stop() }
        f.now.addTimeInterval(1_000)
        await restarted.checkNow()
        XCTAssertEqual(f.bridge.calls.count, 1)
        XCTAssertEqual(restarted.state.entries.first?.status, .queued)
    }

    func testUnknownDispatchAndCrashBeforeReceiptAreNeverRetried() async throws {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        await f.enable(c)
        f.bridge.result = .uncertain(reason: "timeout")
        f.bridge.onSend = {
            let saved = try! JSONDecoder().decode(CodexQuotaResumeCoordinator.State.self, from: Data(contentsOf: f.storageURL))
            XCTAssertEqual(saved.entries.first?.status, .dispatching, "发送之前必须先持久化")
        }
        await c.checkNow()
        c.stop()
        var saved = try JSONDecoder().decode(CodexQuotaResumeCoordinator.State.self, from: Data(contentsOf: f.storageURL))
        saved.entries[0].status = .dispatching // 模拟入队后未保存回执就退出。
        try JSONEncoder().encode(saved).write(to: f.storageURL)
        let restarted = f.makeCoordinator()
        defer { restarted.stop() }
        await restarted.checkNow()
        XCTAssertEqual(f.bridge.calls.count, 1)
        XCTAssertEqual(restarted.state.entries.first?.status, .uncertain)
    }

    func testUserStopsDuringQuotaRequestPreventsDispatch() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        await f.enable(c)
        f.onQuota = { f.observation = f.makeObservation(phase: .interrupted) }
        await c.checkNow()
        XCTAssertTrue(f.bridge.calls.isEmpty)
        await c.checkNow()
        XCTAssertEqual(c.state.entries.first?.status, .cancelled)
    }

    func testDisableDuringQuotaRequestPreventsDispatch() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        await f.enable(c)
        f.onQuota = { c.configure(enabled: false, accountID: "account") }
        await c.checkNow()
        XCTAssertFalse(c.state.enabled)
        XCTAssertTrue(f.bridge.calls.isEmpty)
    }

    func testQueuedInputStaleProjectionApprovalAndCompletedWorkNeverDispatch() async {
        for phase in [CodexQuotaResumeObservationStore.Phase.completed, .interrupted, .inProgress, .failed, .unknown] {
            let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot.appendingPathComponent(phase.rawValue))
            let c = f.makeCoordinator()
            await f.enable(c)
            f.observation = f.makeObservation(phase: phase)
            await c.checkNow()
            XCTAssertTrue(c.state.entries.isEmpty)
            XCTAssertTrue(f.bridge.calls.isEmpty)
            c.stop()
        }
        for (current, queued) in [(false, 0), (true, 1)] {
            let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot.appendingPathComponent(UUID().uuidString))
            let c = f.makeCoordinator()
            await f.enable(c)
            f.observation = f.makeObservation(isCurrent: current, queued: queued)
            await c.checkNow()
            XCTAssertTrue(f.bridge.calls.isEmpty)
            c.stop()
        }
    }

    func testOldFailuresRequireExplicitSelectionAndSubagentsAreExcluded() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        f.now.addTimeInterval(100)
        c.configure(enabled: true, accountID: "account")
        await c.checkNow()
        XCTAssertTrue(c.state.entries.isEmpty)
        f.observation = f.makeObservation(isSubagent: true)
        await c.refreshThreads()
        c.watch(threadID: f.threadID)
        await c.checkNow()
        XCTAssertTrue(c.state.entries.isEmpty)
        f.observation = f.makeObservation()
        await c.refreshThreads()
        c.watch(threadID: f.threadID)
        await c.checkNow()
        XCTAssertEqual(f.bridge.calls.count, 1)
    }

    func testAccountChangeDisablesMonitoringAndRequiresExplicitReenable() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        await f.enable(c)
        f.identityValid = false
        await c.checkNow()
        XCTAssertFalse(c.state.enabled)
        f.identityValid = true
        await c.checkNow()
        XCTAssertTrue(f.bridge.calls.isEmpty)
    }

    func testCorruptJournalIsPreservedAndFailsClosed() async throws {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        try FileManager.default.createDirectory(at: f.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("damaged journal".utf8)
        try bytes.write(to: f.storageURL)
        let c = f.makeCoordinator()
        defer { c.stop() }
        await f.enable(c)
        await c.checkNow()
        XCTAssertNotNil(c.errorMessage)
        XCTAssertTrue(f.bridge.calls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.storageURL), bytes)
    }

    func testUnconfirmedThreadNeverUsesSelectedAccountQuota() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        c.configure(enabled: true, accountID: "account")
        f.onQuota = { XCTFail("未绑定的线程不能使用当前账号的额度") }
        await c.checkNow()
        XCTAssertEqual(c.state.entries.first?.status, .needsAttention)
        XCTAssertTrue(f.bridge.calls.isEmpty)
    }

    func testDisableAtDispatchBoundaryRevokesProcessPermit() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        await f.enable(c)
        f.bridge.onSend = { c.configure(enabled: false, accountID: "account") }
        await c.checkNow()
        XCTAssertTrue(f.bridge.calls.isEmpty)
        XCTAssertEqual(c.state.entries.first?.status, .cancelled)
    }

    func testNextQuotaCycleAfterRealProgressCanResumeWhenRestartFindsAllowance() async throws {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        await f.enable(c)
        await c.checkNow()
        let first = try XCTUnwrap(c.state.entries.first)
        f.observation = f.makeObservation(phase: .inProgress, turnID: "auto-turn", operationID: first.id)
        await c.checkNow()
        XCTAssertEqual(c.state.entries.first?.status, .resumed)
        c.stop()
        f.now.addTimeInterval(20_000)
        f.observation = f.makeObservation(turnID: "auto-turn", operationID: first.id)
        f.observation.hasAgentProgress = true
        let restarted = f.makeCoordinator()
        defer { restarted.stop() }
        await restarted.checkNow()
        XCTAssertEqual(f.bridge.calls.count, 2)
        XCTAssertEqual(restarted.state.entries.count, 2)
        XCTAssertEqual(restarted.state.entries.last?.status, .queued)
    }

    func testImmediateQuotaFailureAfterResumeWaitsForObservedNewBlock() async throws {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        await f.enable(c)
        await c.checkNow()
        let first = try XCTUnwrap(c.state.entries.first)
        f.observation = f.makeObservation(turnID: "immediate-failure", operationID: first.id)
        await c.checkNow()
        XCTAssertEqual(f.bridge.calls.count, 1)
        f.now.addTimeInterval(61)
        f.decision = .blocked(nextCheckAt: f.now.addingTimeInterval(300))
        await c.checkNow()
        f.now.addTimeInterval(301)
        f.decision = .allowed
        await c.checkNow()
        XCTAssertEqual(f.bridge.calls.count, 2)
    }

    func testStaleSecondInstanceReloadsJournalBeforeSending() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        await f.enable(c)
        let second = f.makeCoordinator()
        defer { second.stop() }
        await c.checkNow()
        c.stop()
        await second.checkNow()
        XCTAssertEqual(f.bridge.calls.count, 1)
        XCTAssertEqual(second.state.entries.first?.status, .queued)
    }

    func testExplicitAccountRebindingReplacesOnlyUnsentCancelledWait() async {
        let f = ResumeCoordinatorFixture(root: CodexPaths.codexBarRoot)
        let c = f.makeCoordinator()
        defer { c.stop() }
        await f.enable(c)
        f.decision = .blocked(nextCheckAt: f.now.addingTimeInterval(300))
        await c.checkNow()
        c.configure(enabled: true, accountID: "confirmed-new-account")
        XCTAssertEqual(c.state.entries.first?.status, .cancelled)
        await c.refreshThreads()
        c.watch(threadID: f.threadID)
        f.decision = .allowed
        await c.checkNow()
        XCTAssertEqual(c.state.entries.first?.accountID, "confirmed-new-account")
        XCTAssertEqual(f.bridge.calls.count, 1)
    }
}

@MainActor
private final class ResumeCoordinatorFixture {
    let threadID = "01a19674-fdee-72e2-ab94-c96d2dcec51c"
    let storageURL: URL
    var now = Date(timeIntervalSince1970: 1_793_600_000)
    var identityValid = true
    var accountResolution: CodexQuotaResumeAccountResolution = .resolved(accountID: "account")
    var decision: CodexQuotaResumeQuota.Decision = .allowed
    var observation: CodexQuotaResumeObservationStore.Observation!
    var onQuota: (() -> Void)?
    let bridge = ResumeCoordinatorBridgeStub()

    init(root: URL) {
        self.storageURL = root.appendingPathComponent("resume.json")
        self.observation = self.makeObservation()
    }

    func enable(_ coordinator: CodexQuotaResumeCoordinator) async {
        coordinator.configure(enabled: true, accountID: "account")
        await coordinator.refreshThreads()
        coordinator.watch(threadID: self.threadID)
    }

    func makeCoordinator() -> CodexQuotaResumeCoordinator {
        CodexQuotaResumeCoordinator(storageURL: self.storageURL,
            list: { _, _ in [self.observation] }, read: { _ in self.observation },
            quota: { _, _ in self.onQuota?(); return self.decision },
            identityIsValid: { _ in self.identityValid }, bridge: self.bridge,
            resolveDesktopAccount: { self.accountResolution }, now: { self.now })
    }

    func makeObservation(phase: CodexQuotaResumeObservationStore.Phase = .quotaBlocked,
                         turnID: String = "failed-turn", operationID: UUID? = nil,
                         isCurrent: Bool = true, queued: Int = 0, isSubagent: Bool = false) -> CodexQuotaResumeObservationStore.Observation {
        var value = CodexQuotaResumeObservationStore.Observation(threadID: self.threadID, title: "验收线程", cwd: "/fixture",
            source: "vscode", modelProvider: "openai", model: "gpt-6.1-sol", creatorAccountID: "account",
            executionAccountID: nil, parentThreadID: nil, isSubagent: isSubagent, createdAt: self.now.addingTimeInterval(-100),
            turnID: turnID, phase: phase, startedAt: self.now.addingTimeInterval(-10), completedAt: self.now,
            observedAt: self.now, revision: turnID + phase.rawValue, queuedMessageCount: queued,
            isCurrent: isCurrent, unavailableReason: nil)
        value.originator = "Codex Desktop"
        value.continuationOperationID = operationID?.uuidString.lowercased()
        return value
    }
}

@MainActor
private final class ResumeCoordinatorBridgeStub: CodexThreadContinuing {
    var calls: [(String, UUID)] = []
    var result: CodexThreadContinuationBridge.Outcome?
    var onSend: (() -> Void)?
    func capability() -> CodexThreadContinuationBridge.Capability {
        .available(appURL: URL(fileURLWithPath: "/fixture.app"), cliURL: URL(fileURLWithPath: "/fixture-cli"))
    }
    func enqueue(threadID: String, operationID: UUID, authorize: @escaping @MainActor () -> Bool) async -> CodexThreadContinuationBridge.Outcome {
        self.onSend?()
        guard authorize() else { return .notDispatched(reason: "cancelled") }
        self.calls.append((threadID, operationID))
        return self.result ?? .queued(.init(threadID: threadID, operationID: operationID,
            messageID: UUID().uuidString, queuedAt: Date(), wakeRequested: true))
    }
}
