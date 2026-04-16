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
        guard currentMode() != targetMode else { return nil }

        if currentMode() == .aggregateGateway {
            try applyMode()
            return .updateConfigOnly
        }

        if targetMode == .aggregateGateway {
            do {
                try applyMode()
                try await launchNewInstance()
                return .launchNewInstance
            } catch {
                try? rollbackMode()
                throw error
            }
        }

        return try await OpenAIManualActivationExecutor.execute(
            targetAccountID: "",
            targetMode: targetMode,
            configuredBehavior: configuredBehavior,
            trigger: .primaryTap
        ) {
            try applyMode()
        } launchNewInstance: {
            do {
                try applyMode()
                try await launchNewInstance()
            } catch {
                try? rollbackMode()
                throw error
            }
        }
        .action
    }
}
