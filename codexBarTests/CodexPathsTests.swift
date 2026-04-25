import Foundation
import XCTest

final class CodexPathsTests: CodexBarTestCase {
    func testRustPathPlannerResolvesManagedAndGatewayPaths() throws {
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["CODEXBAR_HOME"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = URL(fileURLWithPath: home, isDirectory: true)

        XCTAssertEqual(CodexPaths.realHome.path, root.path)
        XCTAssertEqual(CodexPaths.codexRoot.path, root.appendingPathComponent(".codex", isDirectory: true).path)
        XCTAssertEqual(CodexPaths.codexBarRoot.path, root.appendingPathComponent(".codexbar", isDirectory: true).path)
        XCTAssertEqual(CodexPaths.menuHostRootURL.path, root.appendingPathComponent(".codexbar/menu-host", isDirectory: true).path)
        XCTAssertEqual(CodexPaths.menuHostAppURL.path, root.appendingPathComponent(".codexbar/menu-host/codexbar.app", isDirectory: true).path)
        XCTAssertEqual(CodexPaths.managedLaunchBinURL.path, root.appendingPathComponent(".codexbar/managed-launch/bin", isDirectory: true).path)
        XCTAssertEqual(CodexPaths.openAIGatewayRootURL.path, root.appendingPathComponent(".codexbar/openai-gateway", isDirectory: true).path)
        XCTAssertEqual(CodexPaths.openRouterGatewayRootURL.path, root.appendingPathComponent(".codexbar/openrouter-gateway", isDirectory: true).path)
        XCTAssertEqual(CodexPaths.configBackupURL.path, root.appendingPathComponent(".codex/config.toml.bak-codexbar-last").path)
        XCTAssertEqual(CodexPaths.authBackupURL.path, root.appendingPathComponent(".codex/auth.json.bak-codexbar-last").path)
    }

    func testRustPathPlannerUsesObservedSQLiteVersions() throws {
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["CODEXBAR_HOME"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let codexRoot = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try Data().write(to: codexRoot.appendingPathComponent("state_8.sqlite"))
        try Data().write(to: codexRoot.appendingPathComponent("logs_4.sqlite"))

        XCTAssertEqual(CodexPaths.stateSQLiteURL.lastPathComponent, "state_8.sqlite")
        XCTAssertEqual(CodexPaths.logsSQLiteURL.lastPathComponent, "logs_4.sqlite")
    }

    func testEnsureDirectoriesCreatesRustPlannedDirectories() throws {
        try CodexPaths.ensureDirectories()

        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.codexRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.codexBarRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.oauthFlowsDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.menuHostRootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.managedLaunchBinURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.managedLaunchHitsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.openAIGatewayRootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.openRouterGatewayRootURL.path))
    }
}
