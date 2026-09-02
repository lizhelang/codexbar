import AppKit
import Foundation

/// 新实例与主实例的数据关系。
enum CodexDesktopInstanceMode: String, Codable, Equatable {
    /// 与主实例共享 ~/.codex：实时共享线程列表，依赖 codex 原生 per-thread
    /// 写锁互斥（正被占用的线程另一实例接管会收到明确错误，释放后即可接管）。
    /// 仅当目标账号就是当前激活账号时可用。
    case sharedHome
    /// 克隆 ~/.codex 后只隔离凭据（auth.json）；会话目录、线程索引和写锁
    /// 指回主 home。两边看到同一份对话，占用中的线程由 Codex 原生 flock 拦住。
    case clonedHome
}

/// 一次成功启动的受管 Codex Desktop 实例记录。
struct CodexDesktopInstanceRecord: Codable, Equatable {
    let accountID: String
    let accountLabel: String
    let pid: Int32
    let launchedAt: Date
    let rootPath: String
    var mode: CodexDesktopInstanceMode = .clonedHome

    enum CodingKeys: String, CodingKey {
        case accountID, accountLabel, pid, launchedAt, rootPath, mode
    }

    init(
        accountID: String,
        accountLabel: String,
        pid: Int32,
        launchedAt: Date,
        rootPath: String,
        mode: CodexDesktopInstanceMode
    ) {
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.pid = pid
        self.launchedAt = launchedAt
        self.rootPath = rootPath
        self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountID = try container.decode(String.self, forKey: .accountID)
        self.accountLabel = try container.decode(String.self, forKey: .accountLabel)
        self.pid = try container.decode(Int32.self, forKey: .pid)
        self.launchedAt = try container.decode(Date.self, forKey: .launchedAt)
        self.rootPath = try container.decode(String.self, forKey: .rootPath)
        self.mode = try container.decodeIfPresent(CodexDesktopInstanceMode.self, forKey: .mode) ?? .clonedHome
    }
}

enum CodexDesktopInstanceError: LocalizedError, Equatable {
    case codexAppNotFound
    case missingOAuthTokens
    case instanceAlreadyRunning(accountLabel: String, pid: Int32)
    case cloneFailed(String)
    case launchTimedOut
    case launchFailed(String)
    case pidVerificationFailed

    var errorDescription: String? {
        switch self {
        case .codexAppNotFound:
            return L.codexLaunchProbeAppNotFound
        case .missingOAuthTokens:
            return L.desktopInstanceMissingTokens
        case .instanceAlreadyRunning(let accountLabel, let pid):
            return L.desktopInstanceAlreadyRunning(accountLabel, Int(pid))
        case .cloneFailed(let message):
            return L.desktopInstanceCloneFailed(message)
        case .launchTimedOut:
            return L.codexLaunchProbeTimedOut
        case .launchFailed(let message):
            return L.codexLaunchProbeFailed(message)
        case .pidVerificationFailed:
            return L.desktopInstancePIDVerificationFailed
        }
    }
}

/// 按账号启动隔离的 Codex Desktop（ChatGPT.app）实例。
///
/// 隔离配方（已在 2026-09-02 实测验证，见决策日志 0002/0004）：
/// 1. `--user-data-dir` 隔离 Chromium profile（避免 profile 锁冲突弹窗）；
/// 2. `CODEX_HOME` 指向 `~/.codex` 的 APFS 克隆（带全部历史，且替换目标账号 auth.json）；
/// 3. `TMPDIR` 隔离（避免 codex_chronicle 全局锁竞争）；
/// 4. 通过 NSWorkspace 启动，进程由 launchd 托管，不随 codexbar 生命周期退出。
@MainActor
final class CodexDesktopInstanceService {
    typealias AppLocationResolver = @MainActor () -> URL?
    typealias HomeCloner = (_ source: URL, _ destination: URL) throws -> Void
    typealias Launcher = @MainActor (
        _ appURL: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) async throws -> pid_t?
    typealias RunningPIDsProvider = @MainActor () -> Set<pid_t>
    typealias ProcessAliveCheck = @MainActor (_ pid: pid_t) -> Bool
    typealias Sleeper = (_ seconds: Double) async -> Void

    static let shared = CodexDesktopInstanceService()

    /// PID 级验证：启动后等待该时长，进程仍存活才算成功。
    static let pidVerificationDelaySeconds: Double = 5

    private let resolveAppURL: AppLocationResolver
    private let cloneHome: HomeCloner
    private let launchApp: Launcher
    private let runningCodexPIDs: RunningPIDsProvider
    private let isProcessAlive: ProcessAliveCheck
    private let sleep: Sleeper
    private let fileManager: FileManager
    private let environment: [String: String]
    private let codexHomeURL: URL
    private let instancesRootURL: URL
    private let registryURL: URL
    private let now: () -> Date

    init(
        resolveAppURL: @escaping AppLocationResolver = {
            CodexDesktopLaunchProbeService.shared.resolvedCodexAppLocation()?.url
        },
        cloneHome: @escaping HomeCloner = CodexDesktopInstanceService.cloneDirectoryUsingAPFSClone,
        launchApp: @escaping Launcher = CodexDesktopInstanceService.workspaceLaunch,
        runningCodexPIDs: @escaping RunningPIDsProvider = {
            Set(
                NSWorkspace.shared.runningApplications
                    .filter { $0.bundleIdentifier == "com.openai.codex" }
                    .map(\.processIdentifier)
            )
        },
        isProcessAlive: @escaping ProcessAliveCheck = { pid in
            kill(pid, 0) == 0
        },
        sleep: @escaping Sleeper = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexHomeURL: URL = CodexPaths.codexRoot,
        instancesRootURL: URL = CodexPaths.managedCodexDesktopProfilesURL,
        registryURL: URL = CodexPaths.managedInstancesRegistryURL,
        now: @escaping () -> Date = Date.init
    ) {
        self.resolveAppURL = resolveAppURL
        self.cloneHome = cloneHome
        self.launchApp = launchApp
        self.runningCodexPIDs = runningCodexPIDs
        self.isProcessAlive = isProcessAlive
        self.sleep = sleep
        self.fileManager = fileManager
        self.environment = environment
        self.codexHomeURL = codexHomeURL
        self.instancesRootURL = instancesRootURL
        self.registryURL = registryURL
        self.now = now
    }

    // MARK: - Public API

    /// 为目标账号启动一个隔离的 Codex Desktop 实例。
    ///
    /// - `sharedHome`：与主实例共享 `~/.codex`（实时同一份线程列表 + 原生写锁互斥）。
    /// - `clonedHome`：隔离 `auth.json`，但会话、索引和写锁仍指向主 `~/.codex`。
    ///
    /// 同一账号同一时间只允许一个受管实例。
    func launchInstance(
        for account: TokenAccount,
        mode: CodexDesktopInstanceMode
    ) async throws -> CodexDesktopInstanceRecord {
        if let existing = self.runningInstance(accountID: account.accountId) {
            throw CodexDesktopInstanceError.instanceAlreadyRunning(
                accountLabel: existing.accountLabel,
                pid: existing.pid
            )
        }

        guard let appURL = self.resolveAppURL() else {
            throw CodexDesktopInstanceError.codexAppNotFound
        }

        let root = self.instanceRootURL(accountID: account.accountId)
        let profileURL = root.appendingPathComponent("profile", isDirectory: true)
        let tmpURL = root.appendingPathComponent("tmp", isDirectory: true)

        var launchEnvironment = self.environment

        switch mode {
        case .sharedHome:
            // 共享主 home：不克隆、不改凭据，让实例沿用默认 CODEX_HOME。
            launchEnvironment.removeValue(forKey: "CODEX_HOME")
        case .clonedHome:
            let authData = try Self.renderAuthJSON(for: account, now: self.now())
            let homeURL = root.appendingPathComponent("home", isDirectory: true)
            try self.prepareInstanceHome(homeURL: homeURL, authData: authData)
            launchEnvironment["CODEX_HOME"] = homeURL.path
        }

        try self.fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)

        launchEnvironment["TMPDIR"] = tmpURL.path
        launchEnvironment = CodexDesktopLaunchProbeService.appendingLocalProxyBypass(to: launchEnvironment)

        let beforeLaunch = self.runningCodexPIDs()
        let workspacePID = try await self.launchApp(
            appURL,
            ["--user-data-dir=\(profileURL.path)"],
            launchEnvironment
        )

        let launchedPID = try await self.resolveLaunchedPID(
            workspacePID: workspacePID,
            excluding: beforeLaunch
        )

        await self.sleep(Self.pidVerificationDelaySeconds)
        guard self.isProcessAlive(launchedPID) else {
            throw CodexDesktopInstanceError.pidVerificationFailed
        }

        let record = CodexDesktopInstanceRecord(
            accountID: account.accountId,
            accountLabel: account.displayIdentifier,
            pid: launchedPID,
            launchedAt: self.now(),
            rootPath: root.path,
            mode: mode
        )
        self.upsertRecord(record)
        return record
    }

    /// 当前仍存活的受管实例（按注册表 + PID 存活过滤）。
    func runningInstances() -> [CodexDesktopInstanceRecord] {
        self.loadRegistry().filter { self.isProcessAlive($0.pid) }
    }

    func runningInstance(accountID: String) -> CodexDesktopInstanceRecord? {
        self.runningInstances().first { $0.accountID == accountID }
    }

    // MARK: - Steps

    private func prepareInstanceHome(homeURL: URL, authData: Data) throws {
        guard self.fileManager.fileExists(atPath: self.codexHomeURL.path) else {
            throw CodexDesktopInstanceError.cloneFailed(
                "source home missing: \(self.codexHomeURL.path)"
            )
        }

        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
        try self.fileManager.createDirectory(
            at: homeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            try self.cloneHome(self.codexHomeURL, homeURL)
        } catch {
            throw CodexDesktopInstanceError.cloneFailed(error.localizedDescription)
        }

        try? self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: homeURL.path
        )

        try self.relinkSharedHistory(into: homeURL)

        try CodexPaths.writeSecureFile(
            authData,
            to: homeURL.appendingPathComponent("auth.json")
        )
    }

    /// 把会话、线程索引和 writer lock 指回主 home，让 Codex 原生 per-thread
    /// flock 跨实例生效：一方占用中，另一方打开同一线程会立刻失败。
    private func relinkSharedHistory(into homeURL: URL) throws {
        for directoryName in Self.sharedHistoryDirectoryNames {
            let sourceURL = self.codexHomeURL.appendingPathComponent(directoryName, isDirectory: true)
            if self.fileManager.fileExists(atPath: sourceURL.path) == false {
                try self.fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            }
            try self.replaceItemWithSymlink(
                at: homeURL.appendingPathComponent(directoryName, isDirectory: true),
                pointingTo: sourceURL
            )
        }

        var names = Set<String>()
        if let sourceItems = try? self.fileManager.contentsOfDirectory(atPath: self.codexHomeURL.path) {
            names.formUnion(sourceItems)
        }
        if let clonedItems = try? self.fileManager.contentsOfDirectory(atPath: homeURL.path) {
            names.formUnion(clonedItems)
        }

        for name in names where Self.isSharedHistoryRelativeName(name) {
            if Self.sharedHistoryDirectoryNames.contains(name) { continue }
            let sourceURL = self.codexHomeURL.appendingPathComponent(name)
            guard self.fileManager.fileExists(atPath: sourceURL.path) else { continue }
            try self.replaceItemWithSymlink(
                at: homeURL.appendingPathComponent(name),
                pointingTo: sourceURL
            )
        }
    }

    private func replaceItemWithSymlink(at destinationURL: URL, pointingTo sourceURL: URL) throws {
        if self.fileManager.fileExists(atPath: destinationURL.path) {
            try self.fileManager.removeItem(at: destinationURL)
        }
        try self.fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
    }

    nonisolated static let sharedHistoryDirectoryNames: Set<String> = [
        "thread-writer-locks",
        "sessions",
        "archived_sessions",
    ]

    nonisolated static func isSharedHistoryRelativeName(_ name: String) -> Bool {
        if Self.sharedHistoryDirectoryNames.contains(name) { return true }
        if name == "session_index.jsonl" || name == "sqlite" { return true }
        let sharedPrefixes = ["state_", "thread_history_", "queue_", "logs_"]
        return sharedPrefixes.contains { name.hasPrefix($0) }
    }

    private func resolveLaunchedPID(
        workspacePID: pid_t?,
        excluding beforeLaunch: Set<pid_t>
    ) async throws -> pid_t {
        if let workspacePID, beforeLaunch.contains(workspacePID) == false {
            return workspacePID
        }

        for _ in 0..<20 {
            let launched = self.runningCodexPIDs().subtracting(beforeLaunch)
            if let pid = launched.sorted().first {
                return pid
            }
            await self.sleep(0.1)
        }

        throw CodexDesktopInstanceError.launchFailed(
            "Codex did not create a new application instance."
        )
    }

    // MARK: - Registry

    private func instanceRootURL(accountID: String) -> URL {
        self.instancesRootURL.appendingPathComponent(
            Self.sanitizedDirectoryName(accountID),
            isDirectory: true
        )
    }

    private func loadRegistry() -> [CodexDesktopInstanceRecord] {
        guard let data = try? Data(contentsOf: self.registryURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CodexDesktopInstanceRecord].self, from: data)) ?? []
    }

    private func upsertRecord(_ record: CodexDesktopInstanceRecord) {
        var records = self.loadRegistry().filter {
            $0.accountID != record.accountID && self.isProcessAlive($0.pid)
        }
        records.append(record)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.registryURL)
    }

    // MARK: - Helpers

    /// 与 CodexSyncService 写 ~/.codex/auth.json 的结构保持一致。
    nonisolated static func renderAuthJSON(
        for account: TokenAccount,
        now: Date = Date()
    ) throws -> Data {
        guard account.accessToken.isEmpty == false,
              account.refreshToken.isEmpty == false,
              account.idToken.isEmpty == false,
              account.remoteAccountId.isEmpty == false else {
            throw CodexDesktopInstanceError.missingOAuthTokens
        }

        var authObject: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "last_refresh": ISO8601DateFormatter().string(
                from: account.tokenLastRefreshAt ?? now
            ),
            "tokens": [
                "access_token": account.accessToken,
                "refresh_token": account.refreshToken,
                "id_token": account.idToken,
                "account_id": account.remoteAccountId,
            ],
        ]
        if let clientID = account.oauthClientID, clientID.isEmpty == false {
            authObject["client_id"] = clientID
        }

        return try JSONSerialization.data(
            withJSONObject: authObject,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    nonisolated static func sanitizedDirectoryName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(mapped)
        return sanitized.isEmpty ? "account" : sanitized
    }

    /// APFS 写时复制克隆；同卷时秒级完成且几乎不占额外空间。
    nonisolated static func cloneDirectoryUsingAPFSClone(
        source: URL,
        destination: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-Rc", source.path, destination.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData, encoding: .utf8) ?? ""
            throw CodexDesktopInstanceError.cloneFailed(
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    @MainActor
    static func workspaceLaunch(
        appURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> pid_t? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.environment = environment

        do {
            let application = try await withThrowingTaskGroup(of: NSRunningApplication?.self) { group in
                group.addTask {
                    try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw CodexDesktopInstanceError.launchTimedOut
                }

                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CodexDesktopInstanceError.launchTimedOut
                }
                return result
            }
            return application?.processIdentifier
        } catch let error as CodexDesktopInstanceError {
            throw error
        } catch {
            throw CodexDesktopInstanceError.launchFailed(error.localizedDescription)
        }
    }
}
