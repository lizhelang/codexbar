import Foundation

/// Keep the last complete render visible while another period or scope is loading.
/// A new projection replaces every displayed section together.
nonisolated struct MenuMonitorDisplayState {
    private(set) var requestedPeriod: UsagePeriod
    private(set) var requestedScope: UsageScope
    private(set) var presentation: MenuMonitorPresentation?

    init(period: UsagePeriod = .today, scope: UsageScope = .all) {
        self.requestedPeriod = period
        self.requestedScope = scope
    }

    var displayedPeriod: UsagePeriod {
        self.presentation?.period ?? self.requestedPeriod
    }

    var displayedScope: UsageScope {
        self.presentation?.scope ?? self.requestedScope
    }

    mutating func select(period: UsagePeriod, scope: UsageScope) {
        self.requestedPeriod = period
        self.requestedScope = scope
    }

    @discardableResult
    mutating func publish(_ presentation: MenuMonitorPresentation) -> Bool {
        guard presentation.period == self.requestedPeriod,
              presentation.scope == self.requestedScope else { return false }
        self.presentation = presentation
        return true
    }
}
