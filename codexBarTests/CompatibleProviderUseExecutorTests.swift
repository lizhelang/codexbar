import XCTest

final class CompatibleProviderUseExecutorTests: XCTestCase {
    func testUpdateConfigOnlyActivatesWithoutLaunching() async throws {
        let tracker = CompatibleProviderUseEffectTracker()

        try await CompatibleProviderUseExecutor.execute(
            configuredBehavior: .updateConfigOnly
        ) {
            tracker.activateCount += 1
        } restorePreviousSelection: {
            tracker.restoreCount += 1
        } launchNewInstance: {
            tracker.launchCount += 1
        }

        XCTAssertEqual(tracker.activateCount, 1)
        XCTAssertEqual(tracker.launchCount, 0)
        XCTAssertEqual(tracker.restoreCount, 0)
    }

    func testLaunchNewInstanceActivatesThenLaunches() async throws {
        let tracker = CompatibleProviderUseEffectTracker()

        try await CompatibleProviderUseExecutor.execute(
            configuredBehavior: .launchNewInstance
        ) {
            tracker.activateCount += 1
        } restorePreviousSelection: {
            tracker.restoreCount += 1
        } launchNewInstance: {
            tracker.launchCount += 1
        }

        XCTAssertEqual(tracker.activateCount, 1)
        XCTAssertEqual(tracker.launchCount, 1)
        XCTAssertEqual(tracker.restoreCount, 0)
    }

    func testLaunchFailureRestoresPreviousSelection() async {
        let tracker = CompatibleProviderUseEffectTracker()
        let expectedError = CompatibleProviderUseTestError.launchFailed

        do {
            try await CompatibleProviderUseExecutor.execute(
                configuredBehavior: .launchNewInstance
            ) {
                tracker.activateCount += 1
            } restorePreviousSelection: {
                tracker.restoreCount += 1
            } launchNewInstance: {
                tracker.launchCount += 1
                throw expectedError
            }
            XCTFail("Expected launch to fail")
        } catch {
            XCTAssertEqual(error as? CompatibleProviderUseTestError, expectedError)
        }

        XCTAssertEqual(tracker.activateCount, 1)
        XCTAssertEqual(tracker.launchCount, 1)
        XCTAssertEqual(tracker.restoreCount, 1)
    }
}

private final class CompatibleProviderUseEffectTracker {
    var activateCount = 0
    var restoreCount = 0
    var launchCount = 0
}

private enum CompatibleProviderUseTestError: Error, Equatable {
    case launchFailed
}
