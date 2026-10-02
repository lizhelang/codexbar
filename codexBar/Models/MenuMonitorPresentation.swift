import Foundation

/// One immutable result for a menu render. Never aggregate records from SwiftUI body.
nonisolated struct MenuMonitorPresentation: Sendable {
    let period: UsagePeriod
    let scope: UsageScope
    let page: MonitorPageData
    let aggregates: [UsageScope: UsageAggregate]
    let history: UsageAggregate
    let sessionsByProject: [String: [MonitorSessionSummary]]

    static func build(
        costSummary: LocalCostSummary,
        records: RecordsSnapshot?,
        toolSnapshots: [ToolUsageClient: ToolUsageSnapshot],
        modelUsage: [MonitorModelUsage]?,
        runningThreads: OpenAIRunningThreadAttribution,
        period: UsagePeriod,
        scope: UsageScope,
        codexSessions: [MonitorCodexSessionUsage]?,
        recentCodexSessions: [MonitorCodexSessionUsage]?,
        recentSessionLimit: Int,
        now: Date,
        calendar: Calendar
    ) -> Self {
        let scopes: [UsageScope] = [.all, .codex] + ToolUsageClient.allCases.map(UsageScope.client)
        let aggregates = Dictionary(uniqueKeysWithValues: scopes.map { scope in
            (scope, UsagePresentation.aggregate(codex: costSummary, external: toolSnapshots,
                scope: scope, period: period, now: now, calendar: calendar))
        })
        let page = MonitorPageData.build(costSummary: costSummary, records: records,
                toolSnapshots: toolSnapshots, modelUsage: modelUsage, runningThreads: runningThreads,
                period: period, scope: scope, codexSessions: codexSessions,
                recentCodexSessions: recentCodexSessions, recentSessionLimit: recentSessionLimit,
                now: now, calendar: calendar)
        var sessionsByProject: [String: [MonitorSessionSummary]] = [:]
        for session in page.sessions {
            if let project = session.projectPath {
                sessionsByProject[project, default: []].append(session)
            }
        }
        return Self(
            period: period, scope: scope,
            page: page,
            aggregates: aggregates,
            history: period == .allTime ? (aggregates[.all] ?? .empty)
                : UsagePresentation.aggregate(codex: costSummary, external: toolSnapshots,
                    scope: .all, period: .allTime, now: now, calendar: calendar),
            sessionsByProject: sessionsByProject
        )
    }
}
