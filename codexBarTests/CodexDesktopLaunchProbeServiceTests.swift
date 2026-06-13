import Foundation
import XCTest

@MainActor
final class CodexDesktopLaunchProbeServiceTests: CodexBarTestCase {
    func testLaunchProbeCreatesWrapperAndInjectsEnvironment() async throws {
        let codexAppURL = try self.makeFakeCodexApp()
        var capturedURL: URL?
        var capturedEnvironment: [String: String] = [:]

        let service = CodexDesktopLaunchProbeService(
            locateCodexApp: {
                CodexDesktopResolvedAppLocation(
                    url: codexAppURL,
                    source: .bundleIdentifierLookup
                )
            },
            workspaceLaunchApp: { appURL, environment in
                capturedURL = appURL
                capturedEnvironment = environment
                return 123
            },
            commandLaunchApp: { _, _ in nil },
            runningCodexProcessIDs: { [] },
            environment: ["PATH": "/usr/bin:/bin"],
            now: { self.date("2026-04-08T01:30:00Z") },
            makeUUID: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }
        )

        let state = try await service.launchProbe()

        XCTAssertEqual(capturedURL, codexAppURL)
        XCTAssertEqual(state.runID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(state.launchedAt, self.date("2026-04-08T01:30:00Z"))
        XCTAssertEqual(
            capturedEnvironment["PATH"],
            CodexPaths.managedLaunchBinURL.path + ":/usr/bin:/bin"
        )
        XCTAssertEqual(
            capturedEnvironment["CODEXBAR_DESKTOP_PROBE_RUN_ID"],
            "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(
            capturedEnvironment["CODEXBAR_DESKTOP_PROBE_HITS_DIR"],
            CodexPaths.managedLaunchHitsURL.path
        )
        XCTAssertEqual(
            capturedEnvironment["NO_PROXY"],
            "localhost,127.0.0.1,::1"
        )
        XCTAssertEqual(
            capturedEnvironment["no_proxy"],
            "localhost,127.0.0.1,::1"
        )

        let wrapperURL = CodexPaths.managedLaunchBinURL.appendingPathComponent("codex")
        let script = try String(contentsOf: wrapperURL, encoding: .utf8)
        XCTAssertTrue(script.contains("CODEXBAR_DESKTOP_PROBE_RUN_ID"))
        XCTAssertTrue(script.contains(codexAppURL.appendingPathComponent("Contents/Resources/codex").path))

        let stateData = try Data(contentsOf: CodexPaths.managedLaunchStateURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(CodexDesktopLaunchProbeState.self, from: stateData), state)
    }

    func testLaunchProbeFailsWhenCodexAppCannotBeLocated() async throws {
        let service = CodexDesktopLaunchProbeService(
            locateCodexApp: { nil },
            workspaceLaunchApp: { _, _ in
                XCTFail("launch should not run")
                return nil
            },
            commandLaunchApp: { _, _ in
                XCTFail("launch should not run")
                return nil
            }
        )

        await XCTAssertThrowsErrorAsync(try await service.launchProbe()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                CodexDesktopLaunchProbeError.codexAppNotFound.localizedDescription
            )
        }
    }

    func testResolvedCodexAppLocationPrefersValidManualPath() throws {
        let preferredURL = try self.makeFakeCodexApp(name: "Preferred")
        let fallbackURL = try self.makeFakeCodexApp(name: "Fallback")

        let service = CodexDesktopLaunchProbeService(
            preferredAppPathProvider: { preferredURL.path },
            locateCodexApp: {
                CodexDesktopResolvedAppLocation(
                    url: fallbackURL,
                    source: .bundleIdentifierLookup
                )
            }
        )

        let resolved = try XCTUnwrap(service.resolvedCodexAppLocation())
        XCTAssertEqual(resolved.url, preferredURL)
        XCTAssertEqual(resolved.source, .preferredPath)
    }

    func testResolvedCodexAppLocationFallsBackWhenManualPathIsInvalid() throws {
        let fallbackURL = try self.makeFakeCodexApp(name: "Fallback")
        let invalidManualURL = try self.makeDirectory(named: "Fake/Codex.app")

        let service = CodexDesktopLaunchProbeService(
            preferredAppPathProvider: { invalidManualURL.path },
            locateCodexApp: {
                CodexDesktopResolvedAppLocation(
                    url: fallbackURL,
                    source: .applicationsFallback
                )
            }
        )

        let resolved = try XCTUnwrap(service.resolvedCodexAppLocation())
        XCTAssertEqual(resolved.url, fallbackURL)
        XCTAssertEqual(resolved.source, .applicationsFallback)
    }

    func testValidatedPreferredCodexAppURLRejectsFakeBundleWithoutExecutable() throws {
        let fakeURL = try self.makeDirectory(named: "Fake/Codex.app")
        let wrongNameURL = try self.makeFakeCodexApp(name: "WrongName", appName: "NotCodex.app")

        XCTAssertNil(
            CodexDesktopLaunchProbeService.validatedPreferredCodexAppURL(
                from: fakeURL.path
            )
        )
        XCTAssertNil(
            CodexDesktopLaunchProbeService.validatedPreferredCodexAppURL(
                from: wrongNameURL.path
            )
        )
        XCTAssertNil(
            CodexDesktopLaunchProbeService.validatedPreferredCodexAppURL(
                from: "relative/Codex.app"
            )
        )
    }

    func testOpenCommandEnvironmentArgumentsOnlyIncludeLaunchWhitelist() {
        let arguments = CodexDesktopLaunchProbeService.openCommandEnvironmentArguments(
            from: [
                "PATH": "/managed/bin:/usr/bin",
                "CODEXBAR_DESKTOP_PROBE_RUN_ID": "probe-run",
                "CODEXBAR_DESKTOP_PROBE_HITS_DIR": "/tmp/hits",
                "NO_PROXY": "localhost",
                "SECRET_TOKEN": "do-not-leak",
            ]
        )

        XCTAssertEqual(
            arguments,
            [
                "--env", "PATH=/managed/bin:/usr/bin",
                "--env", "CODEXBAR_DESKTOP_PROBE_RUN_ID=probe-run",
                "--env", "CODEXBAR_DESKTOP_PROBE_HITS_DIR=/tmp/hits",
                "--env", "NO_PROXY=localhost",
            ]
        )
    }

    func testOpenCommandArgumentsUseIsolatedUserDataDirectory() {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
        let profileURL = URL(fileURLWithPath: "/tmp/codex-profile", isDirectory: true)

        let arguments = CodexDesktopLaunchProbeService.openCommandArguments(
            appURL: appURL,
            environment: ["PATH": "/usr/bin"],
            profileURL: profileURL
        )

        XCTAssertEqual(
            arguments,
            [
                "-n",
                "--env", "PATH=/usr/bin",
                "/Applications/Codex.app",
                "--args",
                "--user-data-dir=/tmp/codex-profile",
                "--no-first-run",
            ]
        )
    }

    func testMakeIsolatedProfileDirectoryCreatesManagedProfile() throws {
        let profileURL = try CodexDesktopLaunchProbeService.makeIsolatedProfileDirectory(
            makeUUID: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }
        )

        XCTAssertEqual(
            profileURL.path,
            CodexPaths.managedCodexDesktopProfilesURL
                .appendingPathComponent("11111111-2222-3333-4444-555555555555")
                .path
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPreferredAppPathStatusReportsInvalidManualPath() throws {
        let invalidManualURL = try self.makeDirectory(named: "Invalid/Codex.app")

        XCTAssertEqual(
            CodexDesktopLaunchProbeService.preferredAppPathStatus(for: invalidManualURL.path),
            .manualInvalid(invalidManualURL.path)
        )
    }

    func testLatestHitReadsRecordedHitFile() throws {
        try CodexPaths.ensureDirectories()
        let hit = CodexDesktopLaunchProbeHit(
            runID: "probe-run",
            recordedAt: self.date("2026-04-08T01:31:00Z"),
            argc: 2
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(hit)
        try CodexPaths.writeSecureFile(
            data,
            to: CodexPaths.managedLaunchHitsURL.appendingPathComponent("probe-run.json")
        )

        let service = CodexDesktopLaunchProbeService(
            locateCodexApp: { nil },
            workspaceLaunchApp: { _, _ in nil },
            commandLaunchApp: { _, _ in nil }
        )

        XCTAssertEqual(service.hit(for: "probe-run"), hit)
        XCTAssertEqual(service.latestHit(), hit)
    }

    func testLaunchNewInstancePassesEnvironmentWithoutProbeKeys() async throws {
        let codexAppURL = try self.makeFakeCodexApp()
        var capturedEnvironment: [String: String] = [:]

        let service = CodexDesktopLaunchProbeService(
            locateCodexApp: {
                CodexDesktopResolvedAppLocation(
                    url: codexAppURL,
                    source: .bundleIdentifierLookup
                )
            },
            workspaceLaunchApp: { _, environment in
                capturedEnvironment = environment
                return 123
            },
            commandLaunchApp: { _, _ in nil },
            runningCodexProcessIDs: { [] },
            environment: [
                "PATH": "/usr/bin:/bin",
                "CODEXBAR_DESKTOP_PROBE_RUN_ID": "old-run",
                "CODEXBAR_DESKTOP_PROBE_HITS_DIR": "/tmp/old-hits",
            ]
        )

        _ = try await service.launchNewInstance()

        XCTAssertEqual(capturedEnvironment["PATH"], "/usr/bin:/bin")
        XCTAssertNil(capturedEnvironment["CODEXBAR_DESKTOP_PROBE_RUN_ID"])
        XCTAssertNil(capturedEnvironment["CODEXBAR_DESKTOP_PROBE_HITS_DIR"])
        XCTAssertEqual(capturedEnvironment["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(capturedEnvironment["no_proxy"], "localhost,127.0.0.1,::1")
    }

    func testLaunchNewInstanceFallsBackToOpenCommandWhenWorkspaceOnlyActivatesExistingCodex() async throws {
        let codexAppURL = try self.makeFakeCodexApp()
        var workspaceLaunchCount = 0
        var commandLaunchCount = 0
        var commandEnvironment: [String: String] = [:]

        let service = CodexDesktopLaunchProbeService(
            locateCodexApp: {
                CodexDesktopResolvedAppLocation(
                    url: codexAppURL,
                    source: .bundleIdentifierLookup
                )
            },
            workspaceLaunchApp: { _, _ in
                workspaceLaunchCount += 1
                return 100
            },
            commandLaunchApp: { _, environment in
                commandLaunchCount += 1
                commandEnvironment = environment
                return 200
            },
            runningCodexProcessIDs: { [100] },
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let launchedPID = try await service.launchNewInstance()

        XCTAssertEqual(launchedPID, 200)
        XCTAssertEqual(workspaceLaunchCount, 1)
        XCTAssertEqual(commandLaunchCount, 1)
        XCTAssertEqual(commandEnvironment["PATH"], "/usr/bin:/bin")
    }

    func testLaunchNewInstanceDoesNotFallbackWhenWorkspaceReturnsFreshProcess() async throws {
        let codexAppURL = try self.makeFakeCodexApp()
        var commandLaunchCount = 0

        let service = CodexDesktopLaunchProbeService(
            locateCodexApp: {
                CodexDesktopResolvedAppLocation(
                    url: codexAppURL,
                    source: .bundleIdentifierLookup
                )
            },
            workspaceLaunchApp: { _, _ in 200 },
            commandLaunchApp: { _, _ in
                commandLaunchCount += 1
                return nil
            },
            runningCodexProcessIDs: { [100] }
        )

        let launchedPID = try await service.launchNewInstance()

        XCTAssertEqual(launchedPID, 200)
        XCTAssertEqual(commandLaunchCount, 0)
    }

    func testLaunchNewInstancePreservesExistingNoProxyEntries() async throws {
        let codexAppURL = try self.makeFakeCodexApp()
        var capturedEnvironment: [String: String] = [:]

        let service = CodexDesktopLaunchProbeService(
            locateCodexApp: {
                CodexDesktopResolvedAppLocation(
                    url: codexAppURL,
                    source: .bundleIdentifierLookup
                )
            },
            workspaceLaunchApp: { _, environment in
                capturedEnvironment = environment
                return 123
            },
            commandLaunchApp: { _, _ in nil },
            runningCodexProcessIDs: { [] },
            environment: [
                "NO_PROXY": "example.com,localhost",
                "no_proxy": "127.0.0.1",
            ]
        )

        _ = try await service.launchNewInstance()

        XCTAssertEqual(capturedEnvironment["NO_PROXY"], "example.com,localhost,127.0.0.1,::1")
        XCTAssertEqual(capturedEnvironment["no_proxy"], "127.0.0.1,localhost,::1")
    }

    private func makeFakeCodexApp(
        name: String = "Codex",
        appName: String = "Codex.app"
    ) throws -> URL {
        let appURL = CodexPaths.realHome.appendingPathComponent("\(name)/\(appName)", isDirectory: true)
        let resourcesURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let executableURL = resourcesURL.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )
        return appURL
    }

    private func makeDirectory(named relativePath: String) throws -> URL {
        let url = CodexPaths.realHome.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
