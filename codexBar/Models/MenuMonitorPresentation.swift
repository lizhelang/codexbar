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
        selectedToolSnapshot: ToolUsageSnapshot? = nil,
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
        // 暂停采集的软件仍可单独查看缓存；总汇总和历史只使用已启用的数据源。
        var detailSnapshots = toolSnapshots
        if case .client(let client) = scope,
           let selectedToolSnapshot,
           selectedToolSnapshot.client == client,
           detailSnapshots[client] == nil {
            detailSnapshots[client] = selectedToolSnapshot
        }
        let scopes: [UsageScope] = [.all, .codex] + ToolUsageClient.allCases.map(UsageScope.client)
        let aggregates = Dictionary(uniqueKeysWithValues: scopes.map { aggregateScope in
            (aggregateScope, UsagePresentation.aggregate(codex: costSummary,
                external: aggregateScope == scope ? detailSnapshots : toolSnapshots,
                scope: aggregateScope, period: period, now: now, calendar: calendar))
        })
        let page = MonitorPageData.build(costSummary: costSummary, records: records,
                toolSnapshots: detailSnapshots, modelUsage: modelUsage, runningThreads: runningThreads,
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
