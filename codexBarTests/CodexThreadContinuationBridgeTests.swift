import Foundation
import XCTest

@MainActor
final class CodexThreadContinuationBridgeTests: XCTestCase {
    private let threadID = "01a19674-fdee-72e2-ab94-c96d2dcec51c"
    private let messageID = "01a19675-d84a-7a51-a18f-25ece469047d"
    private let operationID = UUID(uuidString: "7a2042ef-a1bc-44d7-890a-8415ac8a8518")!

    func testUsesActualRunningApplicationWhenConfiguredPathIsStale() {
        let stub = ContinuationBridgeStub()
        stub.configuredAppURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let bridge = stub.makeBridge()

        XCTAssertEqual(bridge.capability(), .available(appURL: stub.appURL, cliURL: stub.modernCLIURL))
    }

    func testAmbiguousRunningCopiesRequireMatchingConfiguredApplication() {
        let stub = ContinuationBridgeStub()
        let second = URL(fileURLWithPath: "/Applications/Codex Preview.app")
        stub.runningAppURLs.append(second)
        let bridge = stub.makeBridge()

        guard case .unavailable = bridge.capability() else {
            return XCTFail("不能任意选择多个运行中的宿主")
        }
        stub.configuredAppURL = stub.appURL
        XCTAssertEqual(bridge.capability(), .available(appURL: stub.appURL, cliURL: stub.modernCLIURL))
    }

    func testFindsLegacyBundledCLIWithoutUsingSystemCLI() {
        let stub = ContinuationBridgeStub()
        let legacy = stub.appURL.appendingPathComponent("Contents/Resources/codex")
        stub.executableURLs = [legacy]

        XCTAssertEqual(stub.makeBridge().capability(), .available(appURL: stub.appURL, cliURL: legacy))
    }

    func testUnavailableApplicationNeverDispatchesOrLaunchesIt() async {
        let stub = ContinuationBridgeStub()
        stub.runningAppURLs = []

        let result = await stub.makeBridge().enqueue(threadID: self.threadID, operationID: self.operationID)

        guard case .notDispatched = result else { return XCTFail("关闭的桌面应用不应收到消息") }
        XCTAssertTrue(stub.invocations.isEmpty)
        XCTAssertTrue(stub.wakes.isEmpty)
    }

    func testInvalidThreadIdentifierNeverReachesProcessArguments() async {
        let stub = ContinuationBridgeStub()

        let result = await stub.makeBridge().enqueue(threadID: "--last; $(touch /tmp/unwanted)", operationID: self.operationID)

        guard case .notDispatched = result else { return XCTFail("只接受明确的 UUID") }
        XCTAssertTrue(stub.invocations.isEmpty)
        XCTAssertTrue(stub.wakes.isEmpty)
    }

    func testQueuesOnceWithOriginalThreadSettingsAndReturnsReceiptNotRunningState() async throws {
        let stub = ContinuationBridgeStub()
        stub.result = .exited(status: 0, stdout: "Queued message \(self.messageID) for thread \(self.threadID).\n")

        let result = await stub.makeBridge().enqueue(threadID: self.threadID.uppercased(), operationID: self.operationID)

        guard case let .queued(receipt) = result else { return XCTFail("应记录入队回执，不能推断线程已经恢复") }
        XCTAssertEqual(receipt.threadID, self.threadID)
        XCTAssertEqual(receipt.operationID, self.operationID)
        XCTAssertEqual(receipt.messageID, self.messageID)
        XCTAssertEqual(receipt.queuedAt, stub.now)
        XCTAssertTrue(receipt.wakeRequested)
        let invocation = try XCTUnwrap(stub.invocations.first)
        XCTAssertEqual(stub.invocations.count, 1)
        XCTAssertEqual(invocation.executableURL, stub.modernCLIURL)
        XCTAssertEqual(Array(invocation.arguments.prefix(4)), ["queue", "--thread", self.threadID, "--message"])
        XCTAssertEqual(invocation.arguments.count, 5)
        XCTAssertTrue(invocation.arguments[4].contains("codexbar-resume:\(self.operationID.uuidString.lowercased())"))
        XCTAssertFalse(invocation.arguments.contains("--resume"))
        XCTAssertFalse(invocation.arguments.contains("--model"))
        XCTAssertFalse(invocation.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertEqual(stub.wakes.count, 1)
        XCTAssertEqual(stub.wakes.first?.url.absoluteString, "codex://threads/wake/\(self.threadID)")
        XCTAssertEqual(stub.wakes.first?.appURL, stub.appURL)
    }

    func testWakeFailureDoesNotResubmitAnAcceptedMessage() async {
        let stub = ContinuationBridgeStub()
        stub.result = .exited(status: 0, stdout: "Queued message \(self.messageID) for thread \(self.threadID).\n")
        stub.wakeResult = false

        let result = await stub.makeBridge().enqueue(threadID: self.threadID, operationID: self.operationID)

        guard case let .queued(receipt) = result else { return XCTFail("唤醒失败不能丢弃已入队回执") }
        XCTAssertFalse(receipt.wakeRequested)
        XCTAssertEqual(stub.invocations.count, 1)
    }

    func testApplicationExitingDuringDispatchDoesNotGetRelaunched() async {
        let stub = ContinuationBridgeStub()
        stub.result = .exited(status: 0, stdout: "Queued message \(self.messageID) for thread \(self.threadID).\n")
        stub.onRun = { stub.runningAppURLs = [] }

        let result = await stub.makeBridge().enqueue(threadID: self.threadID, operationID: self.operationID)

        guard case let .queued(receipt) = result else { return XCTFail("保留已经入队的消息") }
        XCTAssertFalse(receipt.wakeRequested)
        XCTAssertTrue(stub.wakes.isEmpty)
    }

    func testFailureBeforeLaunchingIsSafeToRecheckLater() async {
        let stub = ContinuationBridgeStub()
        stub.result = .notStarted

        let result = await stub.makeBridge().enqueue(threadID: self.threadID, operationID: self.operationID)

        guard case .notDispatched = result else { return XCTFail("未启动与启动后未知必须区分") }
        XCTAssertEqual(stub.invocations.count, 1)
        XCTAssertTrue(stub.wakes.isEmpty)
    }

    func testTimeoutAndNonzeroExitNeverRetryOrWake() async {
        for processResult: CodexThreadContinuationBridge.ProcessResult in [.timedOut, .exited(status: 1, stdout: "")] {
            let stub = ContinuationBridgeStub()
            stub.result = processResult

            let result = await stub.makeBridge().enqueue(threadID: self.threadID, operationID: self.operationID)

            guard case .uncertain = result else { return XCTFail("CLI 启动后的失败不得自动重发") }
            XCTAssertEqual(stub.invocations.count, 1)
            XCTAssertTrue(stub.wakes.isEmpty)
        }
    }

    func testSuccessfulExitWithoutUnambiguousMatchingReceiptIsUncertain() async {
        let matchingLine = "Queued message \(self.messageID) for thread \(self.threadID).\n"
        let outputs = [
            "done",
            "Queued message \(self.messageID) for thread \(UUID().uuidString).\n",
            matchingLine + matchingLine,
        ]
        for output in outputs {
            let stub = ContinuationBridgeStub()
            stub.result = .exited(status: 0, stdout: output)

            let result = await stub.makeBridge().enqueue(threadID: self.threadID, operationID: self.operationID)

            guard case .uncertain = result else { return XCTFail("没有明确回执不能认定入队，更不能认定恢复") }
            XCTAssertEqual(stub.invocations.count, 1)
            XCTAssertTrue(stub.wakes.isEmpty)
        }
    }

    func testRealProcessRunnerCapturesOutputWithoutShellEvaluation() async {
        let literal = "literal $(not_a_command) `also_not_a_command`"
        let invocation = CodexThreadContinuationBridge.Invocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", literal],
            timeout: 5
        )
        let result = await CodexThreadContinuationBridge.executeProcess(invocation)

        guard case let .exited(status, output) = result else { return XCTFail("printf 应正常退出") }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output, literal)
    }

    func testRealProcessRunnerTerminatesTimedOutChild() async {
        let invocation = CodexThreadContinuationBridge.Invocation(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            timeout: 0.1
        )
        let started = Date()
        let result = await CodexThreadContinuationBridge.executeProcess(invocation)

        guard case .timedOut = result else { return XCTFail("超时必须报告结果未知") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testRevokedAuthorizationAtActualProcessStartDoesNotExecute() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let invocation = CodexThreadContinuationBridge.Invocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], timeout: 1,
            authorize: { false }
        )
        let result = await CodexThreadContinuationBridge.executeProcess(invocation)
        guard case .notStarted = result else { return XCTFail("撤销的发送不能启动子进程") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

@MainActor
private final class ContinuationBridgeStub {
    let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    let now = Date(timeIntervalSince1970: 1_793_525_667)
    var configuredAppURL: URL?
    var runningAppURLs: [URL]
    var executableURLs: Set<URL>
    var invocations: [CodexThreadContinuationBridge.Invocation] = []
    var wakes: [(url: URL, appURL: URL)] = []
    var wakeResult = true
    var result: CodexThreadContinuationBridge.ProcessResult = .notStarted
    var onRun: (() -> Void)?

    var modernCLIURL: URL {
        self.appURL.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    }

    init() {
        self.runningAppURLs = [self.appURL]
        self.executableURLs = [self.appURL.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")]
    }

    func makeBridge() -> CodexThreadContinuationBridge {
        CodexThreadContinuationBridge(
            configuredAppURL: { self.configuredAppURL },
            runningAppURLs: { self.runningAppURLs },
            isExecutable: { self.executableURLs.contains($0) },
            runProcess: { invocation in
                self.invocations.append(invocation)
                self.onRun?()
                return self.result
            },
            wake: { url, appURL in
                self.wakes.append((url, appURL))
                return self.wakeResult
            },
            now: { self.now }
        )
    }
}
