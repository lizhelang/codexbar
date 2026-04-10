import XCTest

final class OpenAIAccountUsageModeTransitionExecutorTests: XCTestCase {
    func testUpdateConfigOnlyAppliesModeWithoutLaunching() async throws {
        let tracker = UsageModeTransitionEffectTracker(currentMode: .switchAccount)

        let action = try await OpenAIAccountUsageModeTransitionExecutor.execute(
            configuredBehavior: .updateConfigOnly,
            targetMode: .aggregateGateway,
            currentMode: tracker.currentMode,
            applyMode: {
                tracker.applyCount += 1
                tracker.currentMode = .aggregateGateway
            },
            rollbackMode: {
                tracker.rollbackCount += 1
                tracker.currentMode = .switchAccount
            },
            launchNewInstance: {
                tracker.launchCount += 1
            }
        )

        XCTAssertEqual(action, .updateConfigOnly)
        XCTAssertEqual(tracker.applyCount, 1)
        XCTAssertEqual(tracker.launchCount, 0)
        XCTAssertEqual(tracker.rollbackCount, 0)
        XCTAssertEqual(tracker.currentMode, .aggregateGateway)
    }

    func testLaunchNewInstanceAppliesModeAndLaunches() async throws {
        let tracker = UsageModeTransitionEffectTracker(currentMode: .switchAccount)

        let action = try await OpenAIAccountUsageModeTransitionExecutor.execute(
            configuredBehavior: .launchNewInstance,
            targetMode: .aggregateGateway,
            currentMode: tracker.currentMode,
            applyMode: {
                tracker.applyCount += 1
                tracker.currentMode = .aggregateGateway
            },
            rollbackMode: {
                tracker.rollbackCount += 1
                tracker.currentMode = .switchAccount
            },
            launchNewInstance: {
                tracker.launchCount += 1
            }
        )

        XCTAssertEqual(action, .launchNewInstance)
        XCTAssertEqual(tracker.applyCount, 1)
        XCTAssertEqual(tracker.launchCount, 1)
        XCTAssertEqual(tracker.rollbackCount, 0)
        XCTAssertEqual(tracker.currentMode, .aggregateGateway)
    }

    func testLaunchFailureRollsBackMode() async {
        let tracker = UsageModeTransitionEffectTracker(currentMode: .switchAccount)

        await XCTAssertThrowsErrorAsync(
            try await OpenAIAccountUsageModeTransitionExecutor.execute(
                configuredBehavior: .launchNewInstance,
                targetMode: .aggregateGateway,
                currentMode: tracker.currentMode,
                applyMode: {
                    tracker.applyCount += 1
                    tracker.currentMode = .aggregateGateway
                },
                rollbackMode: {
                    tracker.rollbackCount += 1
                    tracker.currentMode = .switchAccount
                },
                launchNewInstance: {
                    tracker.launchCount += 1
                    throw DummyError.failed
                }
            )
        ) { error in
            XCTAssertEqual(error as? DummyError, .failed)
        }

        XCTAssertEqual(tracker.applyCount, 1)
        XCTAssertEqual(tracker.launchCount, 1)
        XCTAssertEqual(tracker.rollbackCount, 1)
        XCTAssertEqual(tracker.currentMode, .switchAccount)
    }

    func testNoopWhenTargetModeMatchesCurrentMode() async throws {
        let tracker = UsageModeTransitionEffectTracker(currentMode: .aggregateGateway)

        let action = try await OpenAIAccountUsageModeTransitionExecutor.execute(
            configuredBehavior: .launchNewInstance,
            targetMode: .aggregateGateway,
            currentMode: tracker.currentMode,
            applyMode: {
                tracker.applyCount += 1
            },
            rollbackMode: {
                tracker.rollbackCount += 1
            },
            launchNewInstance: {
                tracker.launchCount += 1
            }
        )

        XCTAssertNil(action)
        XCTAssertEqual(tracker.applyCount, 0)
        XCTAssertEqual(tracker.launchCount, 0)
        XCTAssertEqual(tracker.rollbackCount, 0)
    }
}

private final class UsageModeTransitionEffectTracker {
    var currentMode: CodexBarOpenAIAccountUsageMode
    var applyCount = 0
    var rollbackCount = 0
    var launchCount = 0

    init(currentMode: CodexBarOpenAIAccountUsageMode) {
        self.currentMode = currentMode
    }
}

private enum DummyError: Error, Equatable {
    case failed
}

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
