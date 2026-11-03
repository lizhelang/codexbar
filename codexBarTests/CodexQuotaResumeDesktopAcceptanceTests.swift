import Foundation
import XCTest

/// 手动验收入口：必须显式提供专用测试线程和证据目录，常规回归不向桌面发消息。
/// 只模拟额度失败/恢复边界，实际发送、原线程执行及回执观察均使用生产实现。
@MainActor
final class CodexQuotaResumeDesktopAcceptanceTests: XCTestCase {
    func testOptInOriginalDesktopThreadContinuesAndRestartDoesNotResend() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let threadID = env["CODEXBAR_RESUME_ACCEPTANCE_THREAD_ID"],
              let rootPath = env["CODEXBAR_RESUME_ACCEPTANCE_CODEX_ROOT"],
              let outputPath = env["CODEXBAR_RESUME_ACCEPTANCE_OUTPUT"] else {
            throw XCTSkip("仅在显式指定已授权的测试线程时执行桌面续跑")
        }
        let observer = CodexQuotaResumeObservationStore(codexRootURL: URL(fileURLWithPath: rootPath))
        let baseline = try XCTUnwrap(observer.observation(threadID: threadID))
        XCTAssertEqual(baseline.phase, .completed)
        XCTAssertTrue(baseline.isCurrent)
        let workspace = URL(fileURLWithPath: baseline.cwd)
        let marker = try String(contentsOf: workspace.appendingPathComponent("scene-marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker.trimmingCharacters(in: .whitespacesAndNewlines), "codexbar-quota-resume-20261101")
        let witnessURL = workspace.appendingPathComponent("resume-witness.json")
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: witnessURL)) as? [String: Any])
        XCTAssertEqual(before["acceptancePhase"] as? String, "armed")
        guard baseline.phase == .completed, baseline.isCurrent, before["acceptancePhase"] as? String == "armed" else { return }

        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let journal = output.appendingPathComponent("acceptance-journal-\(UUID().uuidString).json")
        var now = Date()
        var useActualState = false
        var allowed = false
        let bridge = AcceptanceBridge {
            useActualState = true
        }
        var simulated = CodexQuotaResumeObservationStore.Observation(
            threadID: threadID, title: baseline.title, cwd: baseline.cwd, source: baseline.source,
            modelProvider: baseline.modelProvider, model: baseline.model, creatorAccountID: baseline.creatorAccountID,
            executionAccountID: nil, parentThreadID: nil, isSubagent: false, createdAt: baseline.createdAt,
            turnID: baseline.turnID, phase: .quotaBlocked, startedAt: now.addingTimeInterval(-30), completedAt: now,
            observedAt: now, revision: "isolated-quota-failure-fixture", queuedMessageCount: 0,
            isCurrent: true, unavailableReason: nil)
        simulated.originator = "Codex Desktop"
        func make() -> CodexQuotaResumeCoordinator {
            CodexQuotaResumeCoordinator(storageURL: journal,
                list: { _, _ in useActualState ? [try XCTUnwrap(observer.observation(threadID: threadID))] : [simulated] },
                read: { _ in useActualState ? try observer.observation(threadID: threadID) : simulated },
                quota: { _, _ in allowed ? .allowed : .blocked(nextCheckAt: now.addingTimeInterval(60)) },
                identityIsValid: { $0 == "explicit-test-account" }, bridge: bridge, now: { now })
        }
        let initial = make()
        initial.configure(enabled: true, accountID: "explicit-test-account")
        await initial.refreshThreads()
        initial.watch(threadID: threadID)
        await initial.checkNow()
        XCTAssertEqual(initial.state.entries.first?.status, .waiting)
        XCTAssertEqual(bridge.sendCount, 0)
        initial.stop()

        let resumed = make() // 在等待期间重建服务，保留同一份磁盘队列。
        allowed = true
        now.addTimeInterval(61)
        await resumed.checkNow()
        XCTAssertEqual(bridge.sendCount, 1)
        XCTAssertEqual(resumed.state.entries.first?.status, .queued)
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            await resumed.checkNow()
            if resumed.state.entries.first?.status == .resumed,
               let actual = try observer.observation(threadID: threadID), actual.phase == .completed { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertEqual(resumed.state.entries.first?.status, .resumed)
        let operationID = try XCTUnwrap(resumed.state.entries.first?.id.uuidString.lowercased())
        resumed.stop()

        let restarted = make()
        defer { restarted.stop() }
        await restarted.checkNow()
        XCTAssertEqual(bridge.sendCount, 1)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: witnessURL)) as? [String: Any])
        XCTAssertEqual(after["coordinatorResumeCount"] as? Int, 1)
        XCTAssertEqual(after["coordinatorOperationID"] as? String, operationID)
        let report: [String: Any] = [
            "scenario": "simulated quota boundary; real desktop dispatch and execution",
            "threadID": threadID, "operationID": operationID, "sendCount": bridge.sendCount,
            "confirmedStatus": restarted.state.entries.first?.status.rawValue ?? "missing",
            "witnessCount": after["coordinatorResumeCount"] ?? NSNull(),
            "journal": journal.path, "timestamp": Date().timeIntervalSince1970,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("coordinator-desktop-acceptance.json"))
    }
}

@MainActor
private final class AcceptanceBridge: CodexThreadContinuing {
    private let live = CodexThreadContinuationBridge()
    private let didDispatch: () -> Void
    private(set) var sendCount = 0
    init(didDispatch: @escaping () -> Void) { self.didDispatch = didDispatch }
    func capability() -> CodexThreadContinuationBridge.Capability { self.live.capability() }
    func enqueue(threadID: String, operationID: UUID, authorize: @escaping @MainActor () -> Bool) async -> CodexThreadContinuationBridge.Outcome {
        self.sendCount += 1
        let result = await self.live.enqueue(threadID: threadID, operationID: operationID, authorize: authorize)
        self.didDispatch()
        return result
    }
}
