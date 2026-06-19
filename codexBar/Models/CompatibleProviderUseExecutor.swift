import Foundation

enum CompatibleProviderUseExecutor {
    static func execute(
        configuredBehavior: CodexBarOpenAIManualActivationBehavior,
        activateOnly: () throws -> Void,
        restorePreviousSelection: () throws -> Void,
        launchNewInstance: () async throws -> Void
    ) async throws {
        _ = configuredBehavior
        _ = restorePreviousSelection
        _ = launchNewInstance
        try activateOnly()
    }
}
