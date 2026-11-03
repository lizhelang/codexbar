import AppKit
import Darwin
import Foundation

@MainActor
protocol CodexThreadContinuing {
    func capability() -> CodexThreadContinuationBridge.Capability
    func enqueue(threadID: String, operationID: UUID, authorize: @escaping @MainActor () -> Bool) async -> CodexThreadContinuationBridge.Outcome
}

/// 只向原桌面线程入队，不创建 CLI 会话，也不把命令成功当成线程已恢复。
/// 调用方必须在调用前持久化 dispatching，并用后续线程事件确认实际运行。
@MainActor
final class CodexThreadContinuationBridge: CodexThreadContinuing {
    enum Capability: Equatable {
        case available(appURL: URL, cliURL: URL)
        case unavailable(reason: String)
    }

    struct Receipt: Codable, Equatable, Sendable {
        let threadID: String
        let operationID: UUID
        let messageID: String
        let queuedAt: Date
        /// 仅表示系统接受了唤醒 URL；不能证明线程已经运行。
        let wakeRequested: Bool
    }

    enum Outcome: Equatable {
        /// 尚未启动 CLI，没有产生消息，可在重新检查线程后再试。
        case notDispatched(reason: String)
        case queued(Receipt)
        /// CLI 已经启动，消息可能已经入队；不得自动重发。
        case uncertain(reason: String)
    }

    struct Invocation {
        let executableURL: URL
        let arguments: [String]
        let timeout: TimeInterval
        var authorize: @MainActor () -> Bool = { true }
    }

    enum ProcessResult: Sendable {
        case notStarted
        case exited(status: Int32, stdout: String)
        case timedOut
    }

    typealias ProcessRunner = (Invocation) async -> ProcessResult
    typealias WakeAction = (_ url: URL, _ appURL: URL) async -> Bool

    private let configuredAppURL: () -> URL?
    private let runningAppURLs: () -> [URL]
    private let isExecutable: (URL) -> Bool
    private let runProcess: ProcessRunner
    private let wake: WakeAction
    private let now: () -> Date
    private let timeout: TimeInterval

    init(
        configuredAppURL: @escaping () -> URL? = { nil },
        runningAppURLs: @escaping () -> [URL] = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                .filter { !$0.isTerminated }
                .compactMap(\.bundleURL)
        },
        isExecutable: @escaping (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
        runProcess: @escaping ProcessRunner = { invocation in
            await CodexThreadContinuationBridge.executeProcess(invocation)
        },
        wake: @escaping WakeAction = { url, appURL in
            await CodexThreadContinuationBridge.wakeDesktopThread(url: url, appURL: appURL)
        },
        now: @escaping () -> Date = Date.init,
        timeout: TimeInterval = 20
    ) {
        self.configuredAppURL = configuredAppURL
        self.runningAppURLs = runningAppURLs
        self.isExecutable = isExecutable
        self.runProcess = runProcess
        self.wake = wake
        self.now = now
        self.timeout = max(0.1, timeout)
    }

    func capability() -> Capability {
        let running = Array(Set(self.runningAppURLs().map(Self.normalizedURL)))
        let appURL: URL
        if let configured = self.configuredAppURL().map(Self.normalizedURL), running.contains(configured) {
            appURL = configured
        } else if running.count == 1, let onlyApp = running.first {
            appURL = onlyApp
        } else {
            return .unavailable(reason: running.isEmpty
                ? "等待 Codex 桌面应用运行"
                : "检测到多个 Codex 桌面实例，无法确定续跑宿主")
        }

        // 新版 ChatGPT / Codex 共用 com.openai.codex；始终使用实际运行应用的 CLI。
        let relativePaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex",
        ]
        guard let cliURL = relativePaths.map({ appURL.appendingPathComponent($0) }).first(where: self.isExecutable) else {
            return .unavailable(reason: "运行中的 Codex 桌面应用未提供可用的队列命令")
        }
        return .available(appURL: appURL, cliURL: cliURL)
    }

    func enqueue(threadID: String, operationID: UUID, authorize: @escaping @MainActor () -> Bool = { true }) async -> Outcome {
        guard let threadUUID = UUID(uuidString: threadID) else {
            return .notDispatched(reason: "线程 ID 无效，未发送续跑消息")
        }
        guard !Task.isCancelled, authorize() else {
            return .notDispatched(reason: "续跑已取消，未发送消息")
        }
        let capability = self.capability()
        guard case let .available(appURL, cliURL) = capability else {
            if case let .unavailable(reason) = capability {
                return .notDispatched(reason: reason)
            }
            return .notDispatched(reason: "Codex 桌面宿主已变化，请稍后重新检查")
        }

        let canonicalThreadID = threadUUID.uuidString.lowercased()
        let invocation = Invocation(
            executableURL: cliURL,
            arguments: [
                "queue", "--thread", canonicalThreadID,
                "--message", Self.continuationMessage(operationID: operationID),
            ],
            timeout: self.timeout,
            authorize: authorize
        )
        let result = await self.runProcess(invocation)
        switch result {
        case .notStarted:
            return .notDispatched(reason: "无法启动 Codex 队列命令，未发送消息")
        case .timedOut:
            return .uncertain(reason: "续跑命令超时，消息可能已入队；请核对线程，系统不会重复发送")
        case let .exited(status, stdout):
            guard status == 0,
                  let messageID = Self.queuedMessageID(stdout: stdout, expectedThreadID: canonicalThreadID) else {
                // 包括非零退出：进程可能在入队之后、返回回执之前退出。
                // 不将原始输出转成错误文案，避免日志包含认证或配置诊断。
                return .uncertain(reason: "无法确认续跑消息的入队回执；请核对线程，系统不会重复发送")
            }
            let queuedAt = self.now()
            let wakeURL = URL(string: "codex://threads/wake/\(canonicalThreadID)")!
            let isStillRunning = self.runningAppURLs().map(Self.normalizedURL).contains(appURL)
            let wakeRequested: Bool
            if !Task.isCancelled, authorize(), isStillRunning {
                wakeRequested = await self.wake(wakeURL, appURL)
            } else {
                wakeRequested = false
            }
            return .queued(Receipt(
                threadID: canonicalThreadID,
                operationID: operationID,
                messageID: messageID,
                queuedAt: queuedAt,
                wakeRequested: wakeRequested
            ))
        }
    }

    static func continuationMessage(operationID: UUID) -> String {
        """
        Codexbar 根据你开启的“额度恢复后自动继续”设置，恢复本线程因额度限制中断的工作。
        请先核对中断前的实际状态和已完成操作，避免重复执行，再按本线程已有目标继续剩余工作。沿用原工作目录、模型与权限；如果已收到停止指令、任务已完成，或当前需要用户确认，请停止并等待，不要自行扩大任务范围或更改权限。

        恢复标记：codexbar-resume:\(operationID.uuidString.lowercased())
        """
    }

    private static func normalizedURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func queuedMessageID(stdout: String, expectedThreadID: String) -> String? {
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        let pattern = "(?m)^Queued message (\(uuid)) for thread (\(uuid))\\.\\r?$"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(stdout.startIndex..., in: stdout)
        let matches = expression.matches(in: stdout, range: range)
        guard matches.count == 1,
              let match = matches.first,
              let messageRange = Range(match.range(at: 1), in: stdout),
              let threadRange = Range(match.range(at: 2), in: stdout),
              stdout[threadRange].lowercased() == expectedThreadID else { return nil }
        return stdout[messageRange].lowercased()
    }

    private static func wakeDesktopThread(url: URL, appURL: URL) async -> Bool {
        // 应用在命令执行期间退出时不自动启动另一个宿主。
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .contains(where: { !$0.isTerminated && $0.bundleURL.map(Self.normalizedURL) == appURL }) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// 使用临时文件接 stdout，避免子进程填满管道后无法退出。最多读取 16 KiB，且不输出原始诊断。
    static func executeProcess(_ invocation: Invocation) async -> ProcessResult {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory.appendingPathComponent("codexbar-queue-\(UUID().uuidString).out")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            return .notStarted
        }
        defer { try? fileManager.removeItem(at: outputURL) }
        guard let output = try? FileHandle(forWritingTo: outputURL) else { return .notStarted }
        defer { try? output.close() }

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        // 与用户取消共用 MainActor：最后授权检查到启动之间没有挂起点。
        guard !Task.isCancelled, invocation.authorize() else { return .notStarted }
        do {
            try process.run()
        } catch {
            return .notStarted
        }
        let timeout = invocation.timeout
        let finished = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                if terminated.wait(timeout: .now() + timeout) == .success {
                    continuation.resume(returning: true)
                    return
                }
                if process.isRunning { process.terminate() }
                if terminated.wait(timeout: .now() + 0.5) != .success, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = terminated.wait(timeout: .now() + 1)
                }
                continuation.resume(returning: false)
            }
        }
        guard finished else { return .timedOut }
        guard let input = try? FileHandle(forReadingFrom: outputURL) else {
            return .exited(status: process.terminationStatus, stdout: "")
        }
        defer { try? input.close() }
        let data = (try? input.read(upToCount: 16_384)) ?? Data()
        return .exited(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}
