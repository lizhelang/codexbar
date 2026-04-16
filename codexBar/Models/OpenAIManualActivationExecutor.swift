import Foundation

enum OpenAIManualActivationExecutor {
    static func execute(
        targetAccountID: String,
        targetMode: CodexBarOpenAIAccountUsageMode,
        configuredBehavior: CodexBarOpenAIManualActivationBehavior,
        trigger: OpenAIManualActivationTrigger,
        activateOnly: () throws -> Void,
        launchNewInstance: () async throws -> Void
    ) async throws -> OpenAIManualSwitchResult {
        let action = OpenAIManualActivationResolver.resolve(
            configuredBehavior: configuredBehavior,
            trigger: trigger
        )

        switch action {
        case .updateConfigOnly:
            try activateOnly()
        case .launchNewInstance:
            try await launchNewInstance()
        }

        return OpenAIManualSwitchResult(
            action: action,
            targetAccountID: targetAccountID,
            targetMode: targetMode,
            launchedNewInstance: action == .launchNewInstance
        )
    }
}
