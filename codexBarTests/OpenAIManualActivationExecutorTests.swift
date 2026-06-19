import XCTest

final class OpenAIManualActivationExecutorTests: XCTestCase {
    func testPrimaryTapExecutesConfigOnlyActivationWithoutLaunching() async throws {
        let tracker = ManualActivationEffectTracker()

        let result = try await OpenAIManualActivationExecutor.execute(
            targetAccountID: "acct-primary",
            targetMode: .switchAccount,
            configuredBehavior: .updateConfigOnly,
            trigger: .primaryTap
        ) {
            tracker.activateOnlyCount += 1
        } launchNewInstance: {
            tracker.launchCount += 1
        }

        XCTAssertEqual(result.action, .updateConfigOnly)
        XCTAssertEqual(result.targetAccountID, "acct-primary")
        XCTAssertEqual(result.targetMode, .switchAccount)
        XCTAssertFalse(result.launchedNewInstance)
        XCTAssertFalse(result.affectsRunningThreads)
        XCTAssertEqual(result.copyKey, .defaultTargetUpdated)
        XCTAssertEqual(result.immediateEffectRecommendation, .noneNeeded)
        XCTAssertEqual(tracker.activateOnlyCount, 1)
        XCTAssertEqual(tracker.launchCount, 0)
    }

    func testPrimaryTapWithLaunchConfiguredStillUpdatesConfigOnly() async throws {
        let tracker = ManualActivationEffectTracker()

        let result = try await OpenAIManualActivationExecutor.execute(
            targetAccountID: "acct-primary-launch",
            targetMode: .switchAccount,
            configuredBehavior: .launchNewInstance,
            trigger: .primaryTap
        ) {
            tracker.activateOnlyCount += 1
        } launchNewInstance: {
            tracker.launchCount += 1
        }

        XCTAssertEqual(result.action, .updateConfigOnly)
        XCTAssertFalse(result.launchedNewInstance)
        XCTAssertEqual(tracker.activateOnlyCount, 1)
        XCTAssertEqual(tracker.launchCount, 0)
    }

    func testContextOverrideLaunchFallsBackToConfigOnlyWhenLaunchIsUnsupported() async throws {
        let tracker = ManualActivationEffectTracker()

        let result = try await OpenAIManualActivationExecutor.execute(
            targetAccountID: "acct-launch",
            targetMode: .switchAccount,
            configuredBehavior: .updateConfigOnly,
            trigger: .contextOverride(.launchNewInstance)
        ) {
            tracker.activateOnlyCount += 1
        } launchNewInstance: {
            tracker.launchCount += 1
        }

        XCTAssertEqual(result.action, .updateConfigOnly)
        XCTAssertFalse(result.launchedNewInstance)
        XCTAssertEqual(result.copyKey, .defaultTargetUpdated)
        XCTAssertEqual(result.immediateEffectRecommendation, .noneNeeded)
        XCTAssertEqual(tracker.activateOnlyCount, 1)
        XCTAssertEqual(tracker.launchCount, 0)
    }

    func testContextOverrideConfigOnlyExecutesActivationWithoutLaunchingWhenDefaultIsLaunch() async throws {
        let tracker = ManualActivationEffectTracker()

        let result = try await OpenAIManualActivationExecutor.execute(
            targetAccountID: "acct-config",
            targetMode: .switchAccount,
            configuredBehavior: .launchNewInstance,
            trigger: .contextOverride(.updateConfigOnly)
        ) {
            tracker.activateOnlyCount += 1
        } launchNewInstance: {
            tracker.launchCount += 1
        }

        XCTAssertEqual(result.action, .updateConfigOnly)
        XCTAssertEqual(tracker.activateOnlyCount, 1)
        XCTAssertEqual(tracker.launchCount, 0)
    }
}

private final class ManualActivationEffectTracker {
    var activateOnlyCount = 0
    var launchCount = 0
}
