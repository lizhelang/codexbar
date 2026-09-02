import Foundation
import XCTest

@MainActor
final class CodexDesktopInstanceServiceTests: CodexBarTestCase {
    private static let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)

    func testLaunchInstanceClonesHomeSeedsAuthAndVerifiesPID() async throws {
        let sourceHome = try self.makeSourceHome()
        let instancesRoot = self.temporaryURL(named: "instances")
        let registryURL = instancesRoot.appendingPathComponent("instances.json")

        var clonedFrom: URL?
        var clonedTo: URL?
        var launchedArguments: [String] = []
        var launchedEnvironment: [String: String] = [:]

        let service = CodexDesktopInstanceService(
            resolveAppURL: { Self.appURL },
            cloneHome: { source, destination in
                clonedFrom = source
                clonedTo = destination
                try FileManager.default.copyItem(at: source, to: destination)
            },
            launchApp: { _, arguments, environment in
                launchedArguments = arguments
                launchedEnvironment = environment
                return 4242
            },
            runningCodexPIDs: { [100] },
            isProcessAlive: { pid in pid == 4242 || pid == 100 },
            sleep: { _ in },
            environment: ["PATH": "/usr/bin"],
            codexHomeURL: sourceHome,
            instancesRootURL: instancesRoot,
            registryURL: registryURL,
            now: { self.date("2026-09-02T10:00:00Z") }
        )

        let account = self.makeInstanceAccount()
        let record = try await service.launchInstance(for: account, mode: .clonedHome)

        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.accountID, account.accountId)
        XCTAssertEqual(record.launchedAt, self.date("2026-09-02T10:00:00Z"))

        // 克隆源与目标
        XCTAssertEqual(clonedFrom, sourceHome)
        let expectedHome = instancesRoot
            .appendingPathComponent(
                CodexDesktopInstanceService.sanitizedDirectoryName(account.accountId),
                isDirectory: true
            )
            .appendingPathComponent("home", isDirectory: true)
        XCTAssertEqual(clonedTo, expectedHome)

        // 历史与写锁指回主 home，两边写同一份，占用锁跨实例生效
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: expectedHome.appendingPathComponent("sessions/marker.jsonl").path
            )
        )
        let lockDir = expectedHome.appendingPathComponent("thread-writer-locks", isDirectory: true)
        XCTAssertEqual(
            URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(atPath: lockDir.path))
                .standardizedFileURL,
            sourceHome.appendingPathComponent("thread-writer-locks", isDirectory: true).standardizedFileURL
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: lockDir.appendingPathComponent("thread-1.lock").path
            )
        )
        XCTAssertEqual(
            URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(
                atPath: expectedHome.appendingPathComponent("sessions").path
            )).standardizedFileURL,
            sourceHome.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL
        )

        let extraSession = expectedHome.appendingPathComponent("sessions/from-clone.jsonl")
        try Data("cloned-write".utf8).write(to: extraSession)
        XCTAssertEqual(
            try String(
                contentsOf: sourceHome.appendingPathComponent("sessions/from-clone.jsonl"),
                encoding: .utf8
            ),
            "cloned-write"
        )

        // auth.json 换成了目标账号
        let authData = try Data(contentsOf: expectedHome.appendingPathComponent("auth.json"))
        let authObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: authData) as? [String: Any]
        )
        XCTAssertEqual(authObject["auth_mode"] as? String, "chatgpt")
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["account_id"] as? String, account.remoteAccountId)
        XCTAssertEqual(tokens["access_token"] as? String, account.accessToken)
        let authValues = try expectedHome.appendingPathComponent("auth.json")
            .resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertNotEqual(authValues.isSymbolicLink, true)

        let stateLink = expectedHome.appendingPathComponent("state_5.sqlite")
        XCTAssertEqual(
            URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(atPath: stateLink.path))
                .standardizedFileURL,
            sourceHome.appendingPathComponent("state_5.sqlite").standardizedFileURL
        )

        // 启动参数与三重隔离环境
        let root = expectedHome.deletingLastPathComponent()
        XCTAssertEqual(
            launchedArguments,
            ["--user-data-dir=\(root.appendingPathComponent("profile").path)"]
        )
        XCTAssertEqual(launchedEnvironment["CODEX_HOME"], expectedHome.path)
        XCTAssertEqual(
            launchedEnvironment["TMPDIR"],
            root.appendingPathComponent("tmp").path
        )
        XCTAssertEqual(launchedEnvironment["NO_PROXY"], "localhost,127.0.0.1,::1")

        // 注册表落盘
        let registryData = try Data(contentsOf: registryURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CodexDesktopInstanceRecord].self, from: registryData)
        XCTAssertEqual(records, [record])
        XCTAssertEqual(service.runningInstance(accountID: account.accountId), record)
    }

    func testLaunchSharedHomeInstanceSkipsCloneAndKeepsDefaultCodexHome() async throws {
        let sourceHome = try self.makeSourceHome()
        let instancesRoot = self.temporaryURL(named: "instances")
        var launchedArguments: [String] = []
        var launchedEnvironment: [String: String] = [:]

        let service = CodexDesktopInstanceService(
            resolveAppURL: { Self.appURL },
            cloneHome: { _, _ in XCTFail("shared home 模式不应克隆") },
            launchApp: { _, arguments, environment in
                launchedArguments = arguments
                launchedEnvironment = environment
                return 4242
            },
            runningCodexPIDs: { [] },
            isProcessAlive: { _ in true },
            sleep: { _ in },
            environment: ["CODEX_HOME": "/stale/override", "PATH": "/usr/bin"],
            codexHomeURL: sourceHome,
            instancesRootURL: instancesRoot,
            registryURL: instancesRoot.appendingPathComponent("instances.json"),
            now: { self.date("2026-09-02T10:00:00Z") }
        )

        let account = self.makeInstanceAccount()
        let record = try await service.launchInstance(for: account, mode: .sharedHome)

        XCTAssertEqual(record.mode, .sharedHome)
        // 不注入 CODEX_HOME，让实例沿用默认 ~/.codex（并清掉环境里的陈旧覆盖）
        XCTAssertNil(launchedEnvironment["CODEX_HOME"])

        let root = instancesRoot.appendingPathComponent(
            CodexDesktopInstanceService.sanitizedDirectoryName(account.accountId),
            isDirectory: true
        )
        XCTAssertEqual(
            launchedArguments,
            ["--user-data-dir=\(root.appendingPathComponent("profile").path)"]
        )
        XCTAssertEqual(
            launchedEnvironment["TMPDIR"],
            root.appendingPathComponent("tmp").path
        )
        // 共享模式不应创建克隆 home
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("home").path
            )
        )
    }

    func testLaunchInstanceRejectsSecondLaunchWhileInstanceAlive() async throws {
        let sourceHome = try self.makeSourceHome()
        let instancesRoot = self.temporaryURL(named: "instances")
        var launchCount = 0

        let service = CodexDesktopInstanceService(
            resolveAppURL: { Self.appURL },
            cloneHome: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            launchApp: { _, _, _ in
                launchCount += 1
                return 4242
            },
            runningCodexPIDs: { [] },
            isProcessAlive: { _ in true },
            sleep: { _ in },
            environment: [:],
            codexHomeURL: sourceHome,
            instancesRootURL: instancesRoot,
            registryURL: instancesRoot.appendingPathComponent("instances.json")
        )

        let account = self.makeInstanceAccount()
        _ = try await service.launchInstance(for: account, mode: .clonedHome)

        await XCTAssertThrowsErrorAsync(try await service.launchInstance(for: account, mode: .clonedHome)) { error in
            guard case CodexDesktopInstanceError.instanceAlreadyRunning(_, let pid) = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
            XCTAssertEqual(pid, 4242)
        }
        XCTAssertEqual(launchCount, 1)
    }

    func testLaunchInstanceAllowsRelaunchAfterInstanceExited() async throws {
        let sourceHome = try self.makeSourceHome()
        let instancesRoot = self.temporaryURL(named: "instances")
        var alivePIDs: Set<pid_t> = []
        var nextPID: pid_t = 5000

        let service = CodexDesktopInstanceService(
            resolveAppURL: { Self.appURL },
            cloneHome: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            launchApp: { _, _, _ in
                nextPID += 1
                alivePIDs.insert(nextPID)
                return nextPID
            },
            runningCodexPIDs: { [] },
            isProcessAlive: { pid in alivePIDs.contains(pid) },
            sleep: { _ in },
            environment: [:],
            codexHomeURL: sourceHome,
            instancesRootURL: instancesRoot,
            registryURL: instancesRoot.appendingPathComponent("instances.json"),
            now: { self.date("2026-09-02T10:00:00Z") }
        )

        let account = self.makeInstanceAccount()
        let first = try await service.launchInstance(for: account, mode: .clonedHome)

        alivePIDs.remove(first.pid)
        XCTAssertNil(service.runningInstance(accountID: account.accountId))

        let second = try await service.launchInstance(for: account, mode: .clonedHome)
        XCTAssertNotEqual(second.pid, first.pid)
        XCTAssertEqual(service.runningInstance(accountID: account.accountId), second)
    }

    func testLaunchInstanceFailsPIDVerificationWhenProcessDies() async throws {
        let sourceHome = try self.makeSourceHome()
        let instancesRoot = self.temporaryURL(named: "instances")

        let service = CodexDesktopInstanceService(
            resolveAppURL: { Self.appURL },
            cloneHome: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            launchApp: { _, _, _ in 4242 },
            runningCodexPIDs: { [] },
            isProcessAlive: { _ in false },
            sleep: { _ in },
            environment: [:],
            codexHomeURL: sourceHome,
            instancesRootURL: instancesRoot,
            registryURL: instancesRoot.appendingPathComponent("instances.json")
        )

        await XCTAssertThrowsErrorAsync(
            try await service.launchInstance(for: self.makeInstanceAccount(), mode: .clonedHome)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                CodexDesktopInstanceError.pidVerificationFailed.localizedDescription
            )
        }
        XCTAssertTrue(service.runningInstances().isEmpty)
    }

    func testLaunchInstanceFailsWhenAppMissing() async throws {
        let service = CodexDesktopInstanceService(
            resolveAppURL: { nil },
            cloneHome: { _, _ in XCTFail("should not clone") },
            launchApp: { _, _, _ in
                XCTFail("should not launch")
                return nil
            },
            runningCodexPIDs: { [] },
            isProcessAlive: { _ in false },
            sleep: { _ in },
            environment: [:]
        )

        await XCTAssertThrowsErrorAsync(
            try await service.launchInstance(for: self.makeInstanceAccount(), mode: .clonedHome)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                CodexDesktopInstanceError.codexAppNotFound.localizedDescription
            )
        }
    }

    func testRenderAuthJSONRequiresTokens() throws {
        var account = self.makeInstanceAccount()
        account.refreshToken = ""

        XCTAssertThrowsError(
            try CodexDesktopInstanceService.renderAuthJSON(for: account)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                CodexDesktopInstanceError.missingOAuthTokens.localizedDescription
            )
        }
    }

    func testSanitizedDirectoryNameReplacesUnsafeCharacters() {
        XCTAssertEqual(
            CodexDesktopInstanceService.sanitizedDirectoryName("user@example.com/team:1"),
            "user-example-com-team-1"
        )
        XCTAssertEqual(CodexDesktopInstanceService.sanitizedDirectoryName(""), "account")
    }

    func testSharedHistoryRelativeNamesCoverLocksSessionsAndSqlite() {
        XCTAssertTrue(CodexDesktopInstanceService.isSharedHistoryRelativeName("thread-writer-locks"))
        XCTAssertTrue(CodexDesktopInstanceService.isSharedHistoryRelativeName("sessions"))
        XCTAssertTrue(CodexDesktopInstanceService.isSharedHistoryRelativeName("state_5.sqlite"))
        XCTAssertTrue(CodexDesktopInstanceService.isSharedHistoryRelativeName("state_5.sqlite-wal"))
        XCTAssertFalse(CodexDesktopInstanceService.isSharedHistoryRelativeName("auth.json"))
        XCTAssertFalse(CodexDesktopInstanceService.isSharedHistoryRelativeName("config.toml"))
    }

    // MARK: - Helpers

    private func makeInstanceAccount() -> TokenAccount {
        TokenAccount(
            email: "test@example.com",
            accountId: "acct-123",
            openAIAccountId: "org-abc",
            accessToken: "test-access",
            refreshToken: "test-refresh",
            idToken: "test-id",
            oauthClientID: "client-1",
            planType: "pro",
            tokenLastRefreshAt: self.date("2026-09-01T00:00:00Z")
        )
    }

    private func makeSourceHome() throws -> URL {
        let home = self.temporaryURL(named: "source-codex")
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let locks = home.appendingPathComponent("thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sessions.appendingPathComponent("marker.jsonl"))
        try Data("stale".utf8).write(to: locks.appendingPathComponent("thread-1.lock"))
        try Data("{}".utf8).write(to: home.appendingPathComponent("auth.json"))
        try Data("sqlite".utf8).write(to: home.appendingPathComponent("state_5.sqlite"))
        return home
    }

    private func temporaryURL(named name: String) -> URL {
        CodexPaths.realHome.appendingPathComponent(name, isDirectory: true)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
