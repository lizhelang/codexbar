import Foundation
import XCTest

@MainActor
final class UpdateCoordinatorTests: CodexBarTestCase {
    func testManualCheckStoresAvailableUpdateWithoutExecuting() async {
        let releaseLoader = MockReleaseLoader(release: self.makeRelease(version: "1.1.7"))
        let executor = MockUpdateExecutor()

        let coordinator = UpdateCoordinator(
            releaseLoader: releaseLoader,
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                architecture: .arm64
            ),
            capabilityEvaluator: MockCapabilityEvaluator(
                blockers: [.guidedDownloadOnlyRelease]
            ),
            actionExecutor: executor
        )

        await coordinator.checkForUpdates(trigger: .manual)

        XCTAssertEqual(releaseLoader.loadCount, 1)
        XCTAssertTrue(executor.executed.isEmpty)
        XCTAssertEqual(coordinator.pendingAvailability?.release.version, "1.1.7")

        guard case let .updateAvailable(availability) = coordinator.state else {
            return XCTFail("Expected updateAvailable state")
        }
        XCTAssertEqual(availability.release.version, "1.1.7")
    }

    func testToolbarActionExecutesPendingUpdateWithoutRefetching() async {
        let releaseLoader = MockReleaseLoader(release: self.makeRelease(version: "1.1.7"))
        let executor = MockUpdateExecutor()

        let coordinator = UpdateCoordinator(
            releaseLoader: releaseLoader,
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                architecture: .arm64
            ),
            capabilityEvaluator: MockCapabilityEvaluator(
                blockers: [.guidedDownloadOnlyRelease]
            ),
            actionExecutor: executor
        )

        await coordinator.checkForUpdates(trigger: .manual)
        releaseLoader.release = self.makeRelease(version: "1.1.5")

        await coordinator.handleToolbarAction()

        XCTAssertEqual(releaseLoader.loadCount, 1)
        XCTAssertEqual(executor.executed.count, 1)
        XCTAssertEqual(executor.executed.first?.release.version, "1.1.7")
        XCTAssertEqual(coordinator.pendingAvailability?.release.version, "1.1.7")
    }

    func testAutomaticAndManualChecksUseSameReleaseResolution() async {
        let releaseLoader = MockReleaseLoader(release: self.makeRelease(version: "1.1.7"))

        let coordinator = UpdateCoordinator(
            releaseLoader: releaseLoader,
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                architecture: .x86_64
            ),
            capabilityEvaluator: MockCapabilityEvaluator(
                blockers: [.guidedDownloadOnlyRelease]
            ),
            actionExecutor: MockUpdateExecutor()
        )

        await coordinator.checkForUpdates(trigger: .automaticStartup)
        await coordinator.checkForUpdates(trigger: .manual)

        XCTAssertEqual(releaseLoader.loadCount, 2)
        XCTAssertEqual(coordinator.pendingAvailability?.release.version, "1.1.7")
        XCTAssertEqual(coordinator.pendingAvailability?.selectedArtifact.architecture, .x86_64)
    }

    func testStartSchedulesDailyAutomaticChecks() async {
        let scheduler = MockAutomaticCheckScheduler()
        let releaseLoader = MockReleaseLoader(release: self.makeRelease(version: "1.1.7"))

        let coordinator = UpdateCoordinator(
            releaseLoader: releaseLoader,
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                architecture: .arm64
            ),
            capabilityEvaluator: MockCapabilityEvaluator(
                blockers: [.guidedDownloadOnlyRelease]
            ),
            actionExecutor: MockUpdateExecutor(),
            automaticCheckScheduler: scheduler,
            automaticCheckInterval: 123
        )

        coordinator.start()
        await scheduler.waitUntilScheduled()
        while releaseLoader.loadCount < 1 {
            await Task.yield()
        }
        XCTAssertEqual(scheduler.scheduledInterval, 123)

        await scheduler.fire()
        while releaseLoader.loadCount < 2 {
            await Task.yield()
        }

        XCTAssertEqual(releaseLoader.loadCount, 2)
        XCTAssertEqual(coordinator.pendingAvailability?.release.version, "1.1.7")
    }

    func testManualCheckShowsUpToDateStateWhenVersionsMatch() async {
        let coordinator = UpdateCoordinator(
            releaseLoader: MockReleaseLoader(release: self.makeRelease(version: "1.1.5")),
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                architecture: .arm64
            ),
            capabilityEvaluator: MockCapabilityEvaluator(blockers: []),
            actionExecutor: MockUpdateExecutor()
        )

        await coordinator.checkForUpdates(trigger: .manual)

        XCTAssertNil(coordinator.pendingAvailability)
        guard case let .upToDate(currentVersion, checkedVersion) = coordinator.state else {
            return XCTFail("Expected upToDate state")
        }
        XCTAssertEqual(currentVersion, "1.1.5")
        XCTAssertEqual(checkedVersion, "1.1.5")
    }

    func testCoordinatorFailsWhenCompatibleArtifactIsMissing() async {
        let feed = self.makeFeed(
            version: "1.1.7",
            artifacts: [
                AppUpdateArtifact(
                    architecture: .x86_64,
                    format: .dmg,
                    downloadURL: URL(string: "https://example.com/intel.dmg")!,
                    sha256: nil
                )
            ]
        )

        let coordinator = UpdateCoordinator(
            releaseLoader: MockReleaseLoader(release: feed.release),
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                architecture: .arm64
            ),
            capabilityEvaluator: MockCapabilityEvaluator(blockers: []),
            actionExecutor: MockUpdateExecutor()
        )

        await coordinator.checkForUpdates(trigger: .manual)

        guard case let .failed(message) = coordinator.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertEqual(message, L.updateErrorNoCompatibleArtifact("Apple Silicon"))
    }

    func testArtifactSelectorPrefersArmThenUniversal() throws {
        let artifact = try AppUpdateArtifactSelector.selectArtifact(
            for: .arm64,
            artifacts: [
                AppUpdateArtifact(
                    architecture: .universal,
                    format: .dmg,
                    downloadURL: URL(string: "https://example.com/universal.dmg")!,
                    sha256: nil
                ),
                AppUpdateArtifact(
                    architecture: .arm64,
                    format: .zip,
                    downloadURL: URL(string: "https://example.com/arm.zip")!,
                    sha256: nil
                ),
            ]
        )

        XCTAssertEqual(artifact.architecture, .universal)
        XCTAssertEqual(artifact.format, .dmg)
    }

    func testArtifactSelectorPrefersIntelSpecificBuild() throws {
        let artifact = try AppUpdateArtifactSelector.selectArtifact(
            for: .x86_64,
            artifacts: [
                AppUpdateArtifact(
                    architecture: .universal,
                    format: .zip,
                    downloadURL: URL(string: "https://example.com/universal.zip")!,
                    sha256: nil
                ),
                AppUpdateArtifact(
                    architecture: .x86_64,
                    format: .dmg,
                    downloadURL: URL(string: "https://example.com/intel.dmg")!,
                    sha256: nil
                ),
            ]
        )

        XCTAssertEqual(artifact.architecture, .x86_64)
        XCTAssertEqual(artifact.format, .dmg)
    }

    func testArtifactSelectorMapsRustNoCompatibleArtifactToAppUpdateError() {
        XCTAssertThrowsError(
            try AppUpdateArtifactSelector.selectArtifact(
                for: .arm64,
                artifacts: [
                    AppUpdateArtifact(
                        architecture: .x86_64,
                        format: .dmg,
                        downloadURL: URL(string: "https://example.com/intel.dmg")!,
                        sha256: nil
                    )
                ]
            )
        ) { error in
            guard let updateError = error as? AppUpdateError else {
                return XCTFail("Expected AppUpdateError, got \(error)")
            }
            XCTAssertEqual(updateError.errorDescription, L.updateErrorNoCompatibleArtifact("Apple Silicon"))
        }
    }

    func testGitHubReleasesLoaderSkipsDraftPrereleaseAndMissingArtifacts() async throws {
        let releasesURL = URL(string: "https://api.github.com/repos/lizhelang/codexbar/releases")!
        let session = self.makeMockSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url, releasesURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")

            let body = """
            [
              {
                "tag_name": "v1.2.1-beta.1",
                "name": "v1.2.1 beta 1",
                "body": "pre",
                "html_url": "https://github.com/lizhelang/codexbar/releases/tag/v1.2.1-beta.1",
                "draft": false,
                "prerelease": true,
                "published_at": "2026-04-15T11:49:02Z",
                "assets": [
                  {
                    "name": "codexbar-1.2.1-beta.1-macOS.dmg",
                    "browser_download_url": "https://example.com/pre.dmg"
                  }
                ]
              },
              {
                "tag_name": "v1.2.0",
                "name": "v1.2.0",
                "body": "stable but not installable",
                "html_url": "https://github.com/lizhelang/codexbar/releases/tag/v1.2.0",
                "draft": false,
                "prerelease": false,
                "published_at": "2026-04-15T11:48:02Z",
                "assets": [
                  {
                    "name": "codexbar-1.2.0.pkg",
                    "browser_download_url": "https://example.com/ignored.pkg"
                  }
                ]
              },
              {
                "tag_name": "v1.1.9",
                "name": "v1.1.9",
                "body": "reissued stable",
                "html_url": "https://github.com/lizhelang/codexbar/releases/tag/v1.1.9",
                "draft": false,
                "prerelease": false,
                "published_at": "2026-04-15T11:47:02Z",
                "assets": [
                  {
                    "name": "codexbar-1.1.9-macOS.dmg",
                    "browser_download_url": "https://example.com/universal.dmg",
                    "digest": "sha256:abc123"
                  },
                  {
                    "name": "codexbar-1.1.9-macOS-intel.zip",
                    "browser_download_url": "https://example.com/intel.zip",
                    "digest": "sha256:def456"
                  }
                ]
              }
            ]
            """

            return (
                HTTPURLResponse(url: releasesURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let loader = LiveGitHubReleasesUpdateLoader(
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.8",
                architecture: .arm64,
                githubReleasesURL: releasesURL
            ),
            session: session
        )

        let release = try await loader.loadLatestRelease()

        XCTAssertEqual(release.version, "1.1.9")
        XCTAssertEqual(release.deliveryMode, .guidedDownload)
        XCTAssertEqual(release.artifacts.count, 2)
        XCTAssertEqual(release.artifacts[0].architecture, .universal)
        XCTAssertEqual(release.artifacts[0].format, .dmg)
        XCTAssertEqual(release.artifacts[0].sha256, "abc123")
        XCTAssertEqual(release.artifacts[1].architecture, .x86_64)
        XCTAssertEqual(release.artifacts[1].format, .zip)
        XCTAssertEqual(release.artifacts[1].sha256, "def456")
    }

    func testManualCheckDoesNotTreatReissued119AsUpgradeable() async {
        let coordinator = UpdateCoordinator(
            releaseLoader: MockReleaseLoader(release: self.makeRelease(version: "1.1.9")),
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.9",
                architecture: .arm64
            ),
            capabilityEvaluator: MockCapabilityEvaluator(blockers: []),
            actionExecutor: MockUpdateExecutor()
        )

        await coordinator.checkForUpdates(trigger: .manual)

        XCTAssertNil(coordinator.pendingAvailability)
        guard case let .upToDate(currentVersion, checkedVersion) = coordinator.state else {
            return XCTFail("Expected upToDate state")
        }
        XCTAssertEqual(currentVersion, "1.1.9")
        XCTAssertEqual(checkedVersion, "1.1.9")
    }

    func testCoordinatorMapsRustInvalidReleaseVersionToLocalizedFailure() async {
        let coordinator = UpdateCoordinator(
            releaseLoader: MockReleaseLoader(
                release: AppUpdateRelease(
                    version: "bad.version",
                    publishedAt: nil,
                    summary: nil,
                    releaseNotesURL: URL(string: "https://example.com/release-notes")!,
                    downloadPageURL: URL(string: "https://example.com/download")!,
                    deliveryMode: .guidedDownload,
                    minimumAutomaticUpdateVersion: nil,
                    artifacts: []
                )
            ),
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                architecture: .arm64
            ),
            capabilityEvaluator: MockCapabilityEvaluator(blockers: []),
            actionExecutor: MockUpdateExecutor()
        )

        await coordinator.checkForUpdates(trigger: .manual)

        guard case let .failed(message) = coordinator.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertEqual(message, L.updateErrorInvalidReleaseVersion("bad.version"))
    }

    func testStableFeedUsesGuidedDownloadArtifacts() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let feedURL = rootURL.appendingPathComponent("release-feed/stable.json")
        let data = try Data(contentsOf: feedURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let feed = try decoder.decode(AppUpdateFeed.self, from: data)
        let releaseVersion = feed.release.version

        XCTAssertFalse(releaseVersion.isEmpty)
        XCTAssertEqual(feed.release.deliveryMode, .guidedDownload)
        XCTAssertTrue(feed.release.downloadPageURL.absoluteString.contains("/releases/tag/v\(releaseVersion)"))
        XCTAssertEqual(feed.release.artifacts.count, 2)
        XCTAssertTrue(feed.release.artifacts.allSatisfy { $0.sha256?.isEmpty == false })
        XCTAssertTrue(feed.release.artifacts.allSatisfy {
            $0.downloadURL.absoluteString.contains("/releases/download/v\(releaseVersion)/")
        })
        XCTAssertEqual(Set(feed.release.artifacts.map(\.format)), Set([.dmg, .zip]))
    }

    func testBootstrapGateKeeps115InGuidedMode() {
        let evaluator = DefaultAppUpdateCapabilityEvaluator(
            signatureInspector: MockSignatureInspector(
                inspection: AppSignatureInspection(
                    hasUsableSignature: true,
                    summary: "Signature=Developer ID; TeamIdentifier=TEAMID"
                )
            ),
            gatekeeperInspector: MockGatekeeperInspector(
                inspection: AppGatekeeperInspection(
                    passesAssessment: true,
                    summary: "accepted | source=Developer ID"
                )
            ),
            automaticUpdaterAvailable: true
        )

        let blockers = evaluator.blockers(
            for: AppUpdateRelease(
                version: "1.1.7",
                publishedAt: nil,
                summary: nil,
                releaseNotesURL: URL(string: "https://example.com/release-notes")!,
                downloadPageURL: URL(string: "https://example.com/download")!,
                deliveryMode: .automatic,
                minimumAutomaticUpdateVersion: "1.1.6",
                artifacts: []
            ),
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                bundleURL: URL(fileURLWithPath: "/Applications/codexbar.app"),
                architecture: .arm64
            )
        )

        XCTAssertEqual(
            blockers,
            [
                .bootstrapRequired(
                    currentVersion: "1.1.5",
                    minimumAutomaticVersion: "1.1.6"
                )
            ]
        )
    }

    func testPhase0GateIncludesGatekeeperAssessmentBlocker() {
        let evaluator = DefaultAppUpdateCapabilityEvaluator(
            signatureInspector: MockSignatureInspector(
                inspection: AppSignatureInspection(
                    hasUsableSignature: true,
                    summary: "Signature=Developer ID; TeamIdentifier=TEAMID"
                )
            ),
            gatekeeperInspector: MockGatekeeperInspector(
                inspection: AppGatekeeperInspection(
                    passesAssessment: false,
                    summary: "accepted | source=no usable signature"
                )
            ),
            automaticUpdaterAvailable: true
        )

        let blockers = evaluator.blockers(
            for: AppUpdateRelease(
                version: "1.1.7",
                publishedAt: nil,
                summary: nil,
                releaseNotesURL: URL(string: "https://example.com/release-notes")!,
                downloadPageURL: URL(string: "https://example.com/download")!,
                deliveryMode: .automatic,
                minimumAutomaticUpdateVersion: "1.1.5",
                artifacts: []
            ),
            environment: MockUpdateEnvironment(
                currentVersion: "1.1.5",
                bundleURL: URL(fileURLWithPath: "/Applications/codexbar.app"),
                architecture: .arm64
            )
        )

        XCTAssertEqual(
            blockers,
            [.failingGatekeeperAssessment(summary: "accepted | source=no usable signature")]
        )
    }

    private func makeFeed(
        version: String,
        artifacts: [AppUpdateArtifact]? = nil
    ) -> AppUpdateFeed {
        AppUpdateFeed(
            schemaVersion: 1,
            channel: "stable",
            release: AppUpdateRelease(
                version: version,
                publishedAt: nil,
                summary: "Guided release",
                releaseNotesURL: URL(string: "https://example.com/release-notes")!,
                downloadPageURL: URL(string: "https://example.com/download")!,
                deliveryMode: .guidedDownload,
                minimumAutomaticUpdateVersion: "1.1.6",
                artifacts: artifacts ?? [
                    AppUpdateArtifact(
                        architecture: .arm64,
                        format: .dmg,
                        downloadURL: URL(string: "https://example.com/arm.dmg")!,
                        sha256: nil
                    ),
                    AppUpdateArtifact(
                        architecture: .x86_64,
                        format: .dmg,
                        downloadURL: URL(string: "https://example.com/intel.dmg")!,
                        sha256: nil
                    ),
                ]
            )
        )
    }

    private func makeRelease(
        version: String,
        artifacts: [AppUpdateArtifact]? = nil
    ) -> AppUpdateRelease {
        self.makeFeed(version: version, artifacts: artifacts).release
    }
}

private final class MockReleaseLoader: AppUpdateReleaseLoading {
    var release: AppUpdateRelease
    var loadCount = 0

    init(release: AppUpdateRelease) {
        self.release = release
    }

    func loadLatestRelease() async throws -> AppUpdateRelease {
        self.loadCount += 1
        return self.release
    }
}

private struct MockUpdateEnvironment: AppUpdateEnvironmentProviding {
    var currentVersion: String
    var bundleURL: URL = URL(fileURLWithPath: "/Applications/codexbar.app")
    var architecture: UpdateArtifactArchitecture
    var githubReleasesURL: URL? = URL(string: "https://api.github.com/repos/lizhelang/codexbar/releases")
}

private struct MockCapabilityEvaluator: AppUpdateCapabilityEvaluating, AppUpdateEnvironmentFactsProviding {
    var blockers: [AppUpdateBlocker]
    var signatureUsable = true
    var signatureSummary = "Signature=Developer ID; TeamIdentifier=TEAMID"
    var gatekeeperPasses = true
    var gatekeeperSummary = "accepted | source=Developer ID"
    var automaticUpdaterAvailable = true

    func blockers(
        for release: AppUpdateRelease,
        environment: AppUpdateEnvironmentProviding
    ) -> [AppUpdateBlocker] {
        self.blockers
    }

    func environmentFacts(
        for environment: AppUpdateEnvironmentProviding
    ) -> PortableCoreUpdateEnvironmentFacts {
        PortableCoreUpdateEnvironmentFacts(
            currentVersion: environment.currentVersion,
            architecture: environment.architecture.rawValue,
            bundlePath: environment.bundleURL.path,
            signatureUsable: self.signatureUsable,
            signatureSummary: self.signatureSummary,
            gatekeeperPasses: self.gatekeeperPasses,
            gatekeeperSummary: self.gatekeeperSummary,
            automaticUpdaterAvailable: self.automaticUpdaterAvailable
        )
    }
}

private final class MockUpdateExecutor: AppUpdateActionExecuting {
    var executed: [AppUpdateAvailability] = []
    var error: Error?

    func execute(_ availability: AppUpdateAvailability) async throws {
        if let error {
            throw error
        }
        self.executed.append(availability)
    }
}

private final class MockAutomaticCheckScheduler: AppUpdateAutomaticCheckScheduling {
    private(set) var scheduledInterval: TimeInterval?
    private var operation: (@Sendable @MainActor () async -> Void)?

    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable @MainActor () async -> Void
    ) -> AppUpdateAutomaticCheckCancelling {
        self.scheduledInterval = interval
        self.operation = operation
        return MockAutomaticCheckHandle()
    }

    func waitUntilScheduled() async {
        while self.scheduledInterval == nil {
            await Task.yield()
        }
    }

    func fire() async {
        await self.operation?()
    }
}

private struct MockAutomaticCheckHandle: AppUpdateAutomaticCheckCancelling {
    func cancel() {}
}

private struct MockSignatureInspector: AppSignatureInspecting {
    var inspection: AppSignatureInspection

    func inspect(bundleURL: URL) -> AppSignatureInspection {
        self.inspection
    }
}

private struct MockGatekeeperInspector: AppGatekeeperInspecting {
    var inspection: AppGatekeeperInspection

    func inspect(bundleURL: URL) -> AppGatekeeperInspection {
        self.inspection
    }
}
