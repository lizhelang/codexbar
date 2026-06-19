import Foundation

enum OpenAIAccountUsageModeTransitionExecutor {
    static func execute(
        configuredBehavior: CodexBarOpenAIManualActivationBehavior,
        targetMode: CodexBarOpenAIAccountUsageMode,
        currentMode: @autoclosure () -> CodexBarOpenAIAccountUsageMode,
        applyMode: () throws -> Void,
        rollbackMode: () throws -> Void,
        launchNewInstance: () async throws -> Void
    ) async throws -> OpenAIManualActivationAction? {
        _ = configuredBehavior
        _ = rollbackMode
        _ = launchNewInstance
        guard currentMode() != targetMode else { return nil }

        try applyMode()
        return .updateConfigOnly
    }
}
