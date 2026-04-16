import Foundation

enum OpenAIManualSwitchCopyKey: Equatable {
    case defaultTargetUpdated
    case launchedNewInstance
}

enum OpenAIImmediateEffectRecommendation: Equatable {
    case noneNeeded
    case launchNewInstance
}

enum OpenAIManualActivationTrigger: Equatable {
    case primaryTap
    case contextOverride(CodexBarOpenAIManualActivationBehavior)
}

enum OpenAIManualActivationAction: Equatable {
    case updateConfigOnly
    case launchNewInstance
}

struct OpenAIManualSwitchResult: Equatable {
    let action: OpenAIManualActivationAction
    let targetAccountID: String
    let targetMode: CodexBarOpenAIAccountUsageMode
    let launchedNewInstance: Bool
    let affectsRunningThreads: Bool
    let copyKey: OpenAIManualSwitchCopyKey
    let immediateEffectRecommendation: OpenAIImmediateEffectRecommendation

    init(
        action: OpenAIManualActivationAction,
        targetAccountID: String,
        targetMode: CodexBarOpenAIAccountUsageMode,
        launchedNewInstance: Bool
    ) {
        self.action = action
        self.targetAccountID = targetAccountID
        self.targetMode = targetMode
        self.launchedNewInstance = launchedNewInstance
        self.affectsRunningThreads = false
        self.copyKey = launchedNewInstance ? .launchedNewInstance : .defaultTargetUpdated
        self.immediateEffectRecommendation = launchedNewInstance ? .noneNeeded : .launchNewInstance
    }
}

struct OpenAIAggregateStickyBindingSnapshot: Equatable {
    let threadID: String
    let accountID: String
    let updatedAt: Date
}

struct OpenAIRuntimeRouteSnapshot: Equatable {
    let configuredMode: CodexBarOpenAIAccountUsageMode
    let effectiveMode: CodexBarOpenAIAccountUsageMode
    let aggregateRuntimeActive: Bool
    let latestRoutedAccountID: String?
    let latestRoutedAccountIsSummary: Bool
    let stickyAffectsFutureRouting: Bool
    let leaseActive: Bool
    let staleStickyEligible: Bool
    let staleStickyThreadID: String?
    let latestRouteAt: Date?
}

enum OpenAIManualActivationResolver {
    static func resolve(
        configuredBehavior: CodexBarOpenAIManualActivationBehavior,
        trigger: OpenAIManualActivationTrigger
    ) -> OpenAIManualActivationAction {
        let behavior: CodexBarOpenAIManualActivationBehavior
        switch trigger {
        case .primaryTap:
            behavior = configuredBehavior
        case .contextOverride(let overrideBehavior):
            behavior = overrideBehavior
        }

        switch behavior {
        case .updateConfigOnly:
            return .updateConfigOnly
        case .launchNewInstance:
            return .launchNewInstance
        }
    }
}
