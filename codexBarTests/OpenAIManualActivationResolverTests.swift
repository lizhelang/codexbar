import XCTest

final class OpenAIManualActivationResolverTests: XCTestCase {
    func testPrimaryTapUsesConfiguredUpdateConfigOnlyBehavior() {
        let action = OpenAIManualActivationResolver.resolve(
            configuredBehavior: .updateConfigOnly,
            trigger: .primaryTap
        )

        XCTAssertEqual(action, .updateConfigOnly)
    }

    func testPrimaryTapFallsBackToConfigOnlyWhenLaunchIsConfigured() {
        let action = OpenAIManualActivationResolver.resolve(
            configuredBehavior: .launchNewInstance,
            trigger: .primaryTap
        )

        XCTAssertEqual(action, .updateConfigOnly)
    }

    func testContextOverrideLaunchFallsBackToConfigOnlyWhenLaunchIsUnsupported() {
        let action = OpenAIManualActivationResolver.resolve(
            configuredBehavior: .updateConfigOnly,
            trigger: .contextOverride(.launchNewInstance)
        )

        XCTAssertEqual(action, .updateConfigOnly)
    }

    func testContextOverrideUpdatesConfigOnlyEvenWhenDefaultIsLaunchNewInstance() {
        let action = OpenAIManualActivationResolver.resolve(
            configuredBehavior: .launchNewInstance,
            trigger: .contextOverride(.updateConfigOnly)
        )

        XCTAssertEqual(action, .updateConfigOnly)
    }
}
