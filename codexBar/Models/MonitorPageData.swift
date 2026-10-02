import Foundation

nonisolated struct MonitorModelToolUsage: Equatable, Identifiable, Sendable {
    let sourceID: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let knownCostUSD: Double
    let costIsComplete: Bool

    var id: String { self.sourceID }

    /// Codex reports cache reads inside input; other collectors report separate buckets.
    var cacheEligibleInputTokens: Double {
        let input = Double(max(0, self.inputTokens))
        return self.sourceID == "codex" ? input
            : input + Double(max(0, self.cachedInputTokens)) + Double(max(0, self.cacheWriteTokens))
    }
}

/// Usage attributed to a recorded model, with source identities retained when merged.
/// Costs combine local Codex pricing estimates and costs explicitly reported by tools.
nonisolated struct MonitorModelUsage: Equatable, Identifiable, Sendable {
    let modelID: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
    let lastUsedDay: Date
    var costIsComplete: Bool = true
    var sourceIDs: [String] = ["codex"]
    var cacheWriteTokens: Int = 0
    var toolBreakdown: [MonitorModelToolUsage] = []

    var id: String { self.modelID }

    var cacheEligibleInputTokens: Double {
        if self.toolBreakdown.isEmpty {
            return self.sourceIDs == ["codex"] ? Double(max(0, self.inputTokens))
                : Double(max(0, self.inputTokens)) + Double(max(0, self.cachedInputTokens)) + Double(max(0, self.cacheWriteTokens))
        }
        return self.toolBreakdown.reduce(0) { $0 + $1.cacheEligibleInputTokens }
    }

    var cacheHitRate: Double? {
        let input = self.cacheEligibleInputTokens
        guard input > 0 else { return nil }
        return min(1, Double(max(0, self.cachedInputTokens)) / input)
    }

    var hasCompleteTokenBreakdown: Bool {
        self.cacheEligibleInputTokens + Double(max(0, self.outputTokens)) == Double(max(0, self.totalTokens))
    }
}

nonisolated struct MonitorTrendDay: Equatable, Identifiable, Sendable {
    let date: Date
    let totalTokens: Int
    let knownCostUSD: Double
    let costIsComplete: Bool

    var id: Date { self.date }
}

nonisolated struct MonitorTrendData: Equatable, Sendable {
    /// Sparse calendar days within the selected time range, ordered oldest first.
    let days: [MonitorTrendDay]
    let totalTokens: Int
    let knownCostUSD: Double
    let costIsComplete: Bool
    let activeDayCount: Int
    let peakDay: MonitorTrendDay?
    /// Consecutive active days ending today. Zero when today has no recorded usage.
    let currentStreakDays: Int
    let longestStreakDays: Int
}

nonisolated struct MonitorSessionSummary: Equatable, Identifiable, Sendable {
    let sourceID: String
    let sessionID: String
    var title: String
    var modelIDs: [String]
    var projectPath: String?
    var firstUsageAt: Date
    var lastActivityAt: Date
    var totalTokens: Int
    var knownCostUSD: Double
    var costIsComplete: Bool
    var isRunning: Bool?
    var contextWindowTokens: Int?
    var contextUsedTokens: Int?

    var id: String { "\(self.sourceID)|\(self.sessionID)" }
    var modelID: String { self.modelIDs.joined(separator: " · ") }
    var estimatedCostUSD: Double? { self.costIsComplete ? self.knownCostUSD : nil }
}

nonisolated struct MonitorProjectToolUsage: Equatable, Identifiable, Sendable {
    let sourceID: String
    var totalTokens: Int
    var knownCostUSD: Double
    var costIsComplete: Bool
    var sessionCount: Int

    var id: String { self.sourceID }
}

nonisolated struct MonitorRunningProject: Equatable, Identifiable, Sendable {
    let cwd: String
    let displayName: String
    let runningThreadCount: Int
    let lastRuntimeAt: Date
    let totalTokens: Int
    let knownCostUSD: Double
    let costIsComplete: Bool
    let sessionCount: Int
    let sourceIDs: [String]
    let toolBreakdown: [MonitorProjectToolUsage]

    var id: String { self.cwd }
}

nonisolated struct MonitorDeviceData: Equatable, Sendable {
    /// The current Mac is the only device represented by local usage files.
    let localDeviceName: String
    let isLocalOnly: Bool
}

/// Period-safe usage projections. Records provide display metadata only;
/// their lifetime token totals never enter a selected-period session total.
nonisolated struct MonitorPageData: Equatable, Sendable {
    private struct PreparedToolSnapshot: Sendable {
        let client: ToolUsageClient
        let availability: ToolUsageAvailability
        let dailyEntries: [ToolUsageDailyEntry]
        let records: [ToolUsageRecord]

        init(_ snapshot: ToolUsageSnapshot) {
            self.client = snapshot.client
            self.availability = snapshot.availability
            self.dailyEntries = snapshot.dailyEntries
            self.records = MonitorPageData.uniqueRecords(snapshot)
        }
    }

    let models: [MonitorModelUsage]?
    let sessions: [MonitorSessionSummary]
    let recentSessions: [MonitorSessionSummary]
    let recordsAvailable: Bool
    let recordWarningCount: Int
    let missingModelCount: Int
    let trend: MonitorTrendData
    let projects: [MonitorRunningProject]
    let projectsAvailable: Bool
    let device: MonitorDeviceData

    static let empty = Self(
        models: nil, sessions: [], recentSessions: [], recordsAvailable: false,
        recordWarningCount: 0, missingModelCount: 0,
        trend: MonitorTrendData(
            days: [], totalTokens: 0, knownCostUSD: 0, costIsComplete: true,
            activeDayCount: 0, peakDay: nil, currentStreakDays: 0, longestStreakDays: 0
        ),
        projects: [], projectsAvailable: false,
        device: MonitorDeviceData(localDeviceName: ProcessInfo.processInfo.hostName, isLocalOnly: true)
    )

    static func build(
        costSummary: LocalCostSummary,
        records: RecordsSnapshot?,
        toolSnapshots: [ToolUsageClient: ToolUsageSnapshot],
        modelUsage: [MonitorModelUsage]?,
        runningThreads: OpenAIRunningThreadAttribution,
        period: UsagePeriod,
        scope: UsageScope,
        codexSessions: [MonitorCodexSessionUsage]? = nil,
        recentCodexSessions: [MonitorCodexSessionUsage]? = nil,
        recentSessionLimit: Int = 5,
        now: Date = Date(),
        calendar: Calendar = .current,
        localDeviceName: String = ProcessInfo.processInfo.hostName
    ) -> MonitorPageData {
        let firstDay = period.firstDay(now: now, calendar: calendar)
        let recentStart = UsagePeriod.last30Days.firstDay(now: now, calendar: calendar)
        let includesCodex = scope == .all || scope == .codex
        // Session, recent-session, model and warning projections share one deduplication
        // and sort per snapshot, retaining their stable metadata ordering.
        let snapshots = ToolUsageClient.allCases.compactMap { client -> PreparedToolSnapshot? in
            guard scope == .all || scope == .client(client) else { return nil }
            return toolSnapshots[client].map(PreparedToolSnapshot.init)
        }
        let externalAvailable = snapshots.contains {
            [.ready, .partial, .noRecords].contains($0.availability)
        }
        let available = (includesCodex && (records != nil || codexSessions != nil)) || externalAvailable
            || (includesCodex && !runningThreads.summary.isUnavailable && !runningThreads.threads.isEmpty)
        let sessions = Self.sessionSummaries(
            codex: includesCodex ? codexSessions : nil,
            records: includesCodex ? records : nil,
            snapshots: snapshots,
            runningThreads: includesCodex ? runningThreads : nil,
            firstDay: firstDay,
            now: now
        )
        let recent = Self.sessionSummaries(
            codex: includesCodex ? recentCodexSessions : nil,
            records: includesCodex ? records : nil,
            snapshots: snapshots,
            runningThreads: includesCodex ? runningThreads : nil,
            firstDay: recentStart,
            now: now
        )
        let recentSessions = recent.enumerated().compactMap { index, session in
            index < max(1, recentSessionLimit) || session.isRunning == true ? session : nil
        }
        let aggregate = UsagePresentation.aggregate(
            codex: costSummary, external: toolSnapshots, scope: scope,
            period: period, now: now, calendar: calendar
        )
        let days = aggregate.dailyEntries.map {
            MonitorTrendDay(date: $0.date, totalTokens: $0.tokens,
                            knownCostUSD: $0.knownCostUSD, costIsComplete: $0.costIsComplete)
        }
        let activeDays = days.filter { $0.totalTokens > 0 }
        let peakDay = activeDays.max {
            $0.totalTokens != $1.totalTokens ? $0.totalTokens < $1.totalTokens : $0.date < $1.date
        }
        let selectedWarnings = includesCodex ? records?.warnings ?? [] : []
        let externalMissingModels = snapshots.reduce(0) { count, snapshot in
            let missing = snapshot.records.filter {
                Self.contains($0.timestamp, firstDay: firstDay, now: now) &&
                    $0.totalTokens > 0 && Self.modelName($0.modelID) == "unknown"
            }
            return count + Set(missing.map { $0.sessionID ?? $0.id }).count
        }
        return MonitorPageData(
            models: Self.modelSummaries(
                codex: includesCodex ? modelUsage : nil,
                snapshots: snapshots, available: externalAvailable,
                firstDay: firstDay, now: now, calendar: calendar
            ),
            sessions: sessions,
            recentSessions: recentSessions,
            recordsAvailable: available,
            recordWarningCount: selectedWarnings.filter { $0.kind != .missingModel }.count,
            missingModelCount: selectedWarnings.filter { $0.kind == .missingModel }.count + externalMissingModels,
            trend: MonitorTrendData(
                days: days, totalTokens: aggregate.tokens, knownCostUSD: aggregate.knownCostUSD,
                costIsComplete: aggregate.costIsComplete, activeDayCount: activeDays.count, peakDay: peakDay,
                currentStreakDays: Self.currentStreakDays(activeDays: activeDays, now: now, calendar: calendar),
                longestStreakDays: Self.longestStreakDays(activeDays: activeDays, calendar: calendar)
            ),
            projects: Self.projects(from: sessions),
            projectsAvailable: available || (includesCodex && !runningThreads.summary.isUnavailable),
            device: MonitorDeviceData(localDeviceName: localDeviceName, isLocalOnly: true)
        )
    }

    private static func modelSummaries(
        codex: [MonitorModelUsage]?, snapshots: [PreparedToolSnapshot], available: Bool,
        firstDay: Date?, now: Date, calendar: Calendar
    ) -> [MonitorModelUsage]? {
        guard codex != nil || available || snapshots.contains(where: { !$0.records.isEmpty }) else { return nil }
        var result: [String: MonitorModelUsage] = [:]
        var codexByModel: [String: MonitorModelUsage] = [:]
        // The index already groups dated events by model. Repeated snapshots of
        // the same source/model replace one another, rather than doubling usage.
        for row in codex ?? [] where Self.contains(row.lastUsedDay, firstDay: firstDay, now: now) {
            let modelID = Self.modelName(row.modelID)
            if let existing = codexByModel[modelID], existing.lastUsedDay > row.lastUsedDay { continue }
            codexByModel[modelID] = row
        }
        for row in codexByModel.values { Self.mergeModel(row, sourceID: "codex", into: &result) }
        for snapshot in snapshots {
            let allRecords = snapshot.records
            let datedRecords = allRecords.filter { Self.contains($0.timestamp, firstDay: firstDay, now: now) }
            for record in datedRecords {
                let cost = Self.safeCost(record.costUSD)
                let row = MonitorModelUsage(
                    modelID: Self.modelName(record.modelID), inputTokens: max(0, record.inputTokens),
                    cachedInputTokens: max(0, record.cacheReadTokens), outputTokens: max(0, record.outputTokens),
                    totalTokens: max(0, record.totalTokens), estimatedCostUSD: cost ?? 0,
                    lastUsedDay: record.timestamp, costIsComplete: cost != nil || record.totalTokens == 0,
                    sourceIDs: [snapshot.client.rawValue], cacheWriteTokens: max(0, record.cacheWriteTokens)
                )
                Self.mergeModel(row, sourceID: snapshot.client.rawValue, into: &result)
            }
            // Account-level exports may have no model attribution. Keep their
            // uncovered tokens visible as unknown instead of silently dropping them.
            let recordsByDay = Dictionary(grouping: allRecords) { calendar.startOfDay(for: $0.timestamp) }
            let days = Dictionary(grouping: snapshot.dailyEntries) { calendar.startOfDay(for: $0.date) }
            for (day, entries) in days where Self.contains(day, firstDay: firstDay, now: now) {
                let covered = recordsByDay[day] ?? []
                let dayTokens = entries.reduce(0) { Self.add($0, max(0, $1.totalTokens)) }
                let coveredTokens = covered.reduce(0) { Self.add($0, max(0, $1.totalTokens)) }
                let residual = max(0, dayTokens - coveredTokens)
                guard residual > 0 else { continue }
                let costsKnown = entries.allSatisfy { Self.safeCost($0.costUSD) != nil || $0.totalTokens == 0 }
                    && covered.allSatisfy { Self.safeCost($0.costUSD) != nil || $0.totalTokens == 0 }
                let dayCost = entries.reduce(0.0) { $0 + (Self.safeCost($1.costUSD) ?? Self.safeCost($1.knownCostUSD) ?? 0) }
                let coveredCost = covered.reduce(0.0) { $0 + (Self.safeCost($1.costUSD) ?? 0) }
                let row = MonitorModelUsage(
                    modelID: "unknown", inputTokens: 0, cachedInputTokens: 0, outputTokens: 0,
                    totalTokens: residual, estimatedCostUSD: max(0, dayCost - coveredCost), lastUsedDay: day,
                    costIsComplete: costsKnown, sourceIDs: [snapshot.client.rawValue]
                )
                Self.mergeModel(row, sourceID: snapshot.client.rawValue, into: &result)
            }
        }
        return result.values.filter { $0.totalTokens > 0 }.sorted {
            $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.modelID < $1.modelID
        }
    }

    private static func mergeModel(_ row: MonitorModelUsage, sourceID: String, into result: inout [String: MonitorModelUsage]) {
        let key = Self.modelName(row.modelID)
        let old = result[key]
        var sources = old?.toolBreakdown ?? []
        let prior = sources.first { $0.sourceID == sourceID }
        let source = MonitorModelToolUsage(
            sourceID: sourceID,
            inputTokens: Self.add(prior?.inputTokens ?? 0, row.inputTokens),
            cachedInputTokens: Self.add(prior?.cachedInputTokens ?? 0, row.cachedInputTokens),
            cacheWriteTokens: Self.add(prior?.cacheWriteTokens ?? 0, row.cacheWriteTokens),
            outputTokens: Self.add(prior?.outputTokens ?? 0, row.outputTokens),
            totalTokens: Self.add(prior?.totalTokens ?? 0, row.totalTokens),
            knownCostUSD: (prior?.knownCostUSD ?? 0) + row.estimatedCostUSD,
            costIsComplete: (prior?.costIsComplete ?? true) && row.costIsComplete
        )
        if let index = sources.firstIndex(where: { $0.sourceID == sourceID }) { sources[index] = source }
        else { sources.append(source) }
        result[key] = MonitorModelUsage(
            modelID: key,
            inputTokens: Self.add(old?.inputTokens ?? 0, row.inputTokens),
            cachedInputTokens: Self.add(old?.cachedInputTokens ?? 0, row.cachedInputTokens),
            outputTokens: Self.add(old?.outputTokens ?? 0, row.outputTokens),
            totalTokens: Self.add(old?.totalTokens ?? 0, row.totalTokens),
            estimatedCostUSD: (old?.estimatedCostUSD ?? 0) + row.estimatedCostUSD,
            lastUsedDay: max(old?.lastUsedDay ?? row.lastUsedDay, row.lastUsedDay),
            costIsComplete: (old?.costIsComplete ?? true) && row.costIsComplete,
            sourceIDs: Array(Set((old?.sourceIDs ?? []) + [sourceID])).sorted(),
            cacheWriteTokens: Self.add(old?.cacheWriteTokens ?? 0, row.cacheWriteTokens),
            toolBreakdown: sources.sorted {
                $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.sourceID < $1.sourceID
            }
        )
    }

    private static func sessionSummaries(
        codex: [MonitorCodexSessionUsage]?, records: RecordsSnapshot?, snapshots: [PreparedToolSnapshot],
        runningThreads: OpenAIRunningThreadAttribution?, firstDay: Date?, now: Date
    ) -> [MonitorSessionSummary] {
        var result: [String: MonitorSessionSummary] = [:]
        let cachedTitles = (records?.sessions ?? []).reduce(into: [String: String]()) { titles, record in
            if let title = SessionDisplayTitle.cleaned(record.title, sessionID: record.sessionID) {
                titles[record.sessionID] = title
            }
        }
        var indexedTitles: [String: String] = [:]
        for session in codex ?? [] where Self.contains(session.lastActivityAt, firstDay: firstDay, now: now) {
            if let title = SessionDisplayTitle.cleaned(session.title, sessionID: session.sessionID) {
                indexedTitles[session.sessionID] = title
            }
            let item = MonitorSessionSummary(
                sourceID: "codex", sessionID: session.sessionID,
                title: SessionDisplayTitle.preferred([session.title, cachedTitles[session.sessionID]], sessionID: session.sessionID),
                modelIDs: Self.modelNames(session.modelIDs), projectPath: Self.projectPath(session.projectPath),
                firstUsageAt: session.firstUsageAt, lastActivityAt: session.lastActivityAt,
                totalTokens: max(0, session.totalTokens), knownCostUSD: max(0, session.knownCostUSD),
                costIsComplete: session.costIsComplete,
                isRunning: nil,
                contextWindowTokens: nil, contextUsedTokens: nil
            )
            if let prior = result[item.id], prior.lastActivityAt > item.lastActivityAt { continue }
            result[item.id] = item
        }
        var titleUpdatedAt: [String: Date] = [:]
        for snapshot in snapshots {
            for record in snapshot.records where Self.contains(record.timestamp, firstDay: firstDay, now: now) {
                guard let sessionID = Self.cleaned(record.sessionID) else { continue }
                let key = "\(snapshot.client.rawValue)|\(sessionID)"
                let cost = Self.safeCost(record.costUSD)
                var item = result[key] ?? MonitorSessionSummary(
                    sourceID: snapshot.client.rawValue, sessionID: sessionID,
                    title: SessionDisplayTitle.preferred([record.sessionTitle], sessionID: sessionID),
                    modelIDs: [], projectPath: nil, firstUsageAt: record.timestamp, lastActivityAt: record.timestamp,
                    totalTokens: 0, knownCostUSD: 0, costIsComplete: true, isRunning: nil,
                    contextWindowTokens: nil, contextUsedTokens: nil
                )
                item.totalTokens = Self.add(item.totalTokens, max(0, record.totalTokens))
                item.knownCostUSD += cost ?? 0
                item.costIsComplete = item.costIsComplete && (cost != nil || record.totalTokens == 0)
                item.firstUsageAt = min(item.firstUsageAt, record.timestamp)
                item.modelIDs = Self.modelNames(item.modelIDs + [Self.modelName(record.modelID)])
                if let title = SessionDisplayTitle.cleaned(record.sessionTitle, sessionID: sessionID),
                   record.timestamp >= titleUpdatedAt[key, default: .distantPast] {
                    item.title = title
                    titleUpdatedAt[key] = record.timestamp
                }
                if let path = Self.projectPath(record.projectPath) { item.projectPath = path }
                if record.timestamp >= item.lastActivityAt {
                    item.lastActivityAt = record.timestamp
                    // A persisted start marker can outlive a missing end event.
                    // Only recent explicit states are useful as live/finished evidence.
                    item.isRunning = now.timeIntervalSince(record.timestamp) <= 10 * 60
                        ? record.sessionIsRunning : nil
                    item.contextWindowTokens = record.contextWindowTokens
                    item.contextUsedTokens = record.contextUsedTokens
                }
                result[key] = item
            }
        }
        // A record with usage is a lifetime summary and cannot supply a missing
        // period total. Zero-usage records may still provide a useful session row.
        for record in records?.sessions ?? [] where record.totalTokens == 0 && Self.contains(record.lastActivityAt, firstDay: firstDay, now: now) {
            let key = "codex|\(record.sessionID)"
            guard result[key] == nil else { continue }
            result[key] = MonitorSessionSummary(
                sourceID: "codex", sessionID: record.sessionID,
                title: SessionDisplayTitle.preferred([record.title], sessionID: record.sessionID),
                modelIDs: Self.modelNames([record.modelID]), projectPath: Self.projectPath(record.projectPath),
                firstUsageAt: record.startedAt, lastActivityAt: record.lastActivityAt,
                totalTokens: 0, knownCostUSD: 0, costIsComplete: true,
                isRunning: nil, contextWindowTokens: nil, contextUsedTokens: nil
            )
        }
        if let runningThreads, !runningThreads.summary.isUnavailable {
            for thread in runningThreads.threads where Self.contains(thread.lastRuntimeAt, firstDay: firstDay, now: now) {
                let key = "codex|\(thread.threadID)"
                var item = result[key] ?? MonitorSessionSummary(
                    sourceID: "codex", sessionID: thread.threadID, title: SessionDisplayTitle.unnamed,
                    modelIDs: [], projectPath: nil,
                    firstUsageAt: thread.lastRuntimeAt, lastActivityAt: thread.lastRuntimeAt,
                    totalTokens: 0, knownCostUSD: 0, costIsComplete: true, isRunning: true,
                    contextWindowTokens: nil, contextUsedTokens: nil
                )
                item.title = SessionDisplayTitle.preferred(
                    [indexedTitles[thread.threadID], cachedTitles[thread.threadID], thread.title, item.title],
                    sessionID: thread.threadID)
                if let path = Self.projectPath(thread.cwd) { item.projectPath = path }
                item.lastActivityAt = max(item.lastActivityAt, thread.lastRuntimeAt)
                item.isRunning = true
                result[key] = item
            }
        }
        return result.values.sorted {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.id < $1.id
        }
    }

    private static func projects(from sessions: [MonitorSessionSummary]) -> [MonitorRunningProject] {
        let grouped = Dictionary(grouping: sessions.filter { $0.projectPath != nil }) { $0.projectPath! }
        return grouped.map { path, sessions in
            var tools: [String: MonitorProjectToolUsage] = [:]
            var runningCount = 0
            var lastActivity = Date.distantPast
            for session in sessions {
                var tool = tools[session.sourceID] ?? MonitorProjectToolUsage(
                    sourceID: session.sourceID, totalTokens: 0, knownCostUSD: 0,
                    costIsComplete: true, sessionCount: 0
                )
                tool.totalTokens = Self.add(tool.totalTokens, session.totalTokens)
                tool.knownCostUSD += session.knownCostUSD
                tool.costIsComplete = tool.costIsComplete && session.costIsComplete
                tool.sessionCount += 1
                tools[session.sourceID] = tool
                if session.isRunning == true { runningCount += 1 }
                lastActivity = max(lastActivity, session.lastActivityAt)
            }
            let breakdown = tools.values.sorted {
                $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.sourceID < $1.sourceID
            }
            return MonitorRunningProject(
                cwd: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
                runningThreadCount: runningCount,
                lastRuntimeAt: lastActivity,
                totalTokens: breakdown.reduce(0) { Self.add($0, $1.totalTokens) },
                knownCostUSD: breakdown.reduce(0) { $0 + $1.knownCostUSD },
                costIsComplete: breakdown.allSatisfy(\.costIsComplete), sessionCount: sessions.count,
                sourceIDs: tools.keys.sorted(), toolBreakdown: breakdown
            )
        }.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.lastRuntimeAt != $1.lastRuntimeAt { return $0.lastRuntimeAt > $1.lastRuntimeAt }
            return $0.cwd < $1.cwd
        }
    }

    private static func uniqueRecords(_ snapshot: ToolUsageSnapshot) -> [ToolUsageRecord] {
        var byID: [String: ToolUsageRecord] = [:]
        for record in snapshot.usageRecords {
            if let old = byID[record.id], old.timestamp > record.timestamp { continue }
            byID[record.id] = record
        }
        return byID.values.sorted { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.id < $1.id }
    }

    private static func contains(_ date: Date, firstDay: Date?, now: Date) -> Bool {
        date <= now && (firstDay.map { date >= $0 } ?? true)
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let result = text?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        return result
    }

    private static func modelName(_ text: String?) -> String { Self.cleaned(text) ?? "unknown" }
    private static func modelNames(_ names: [String]) -> [String] { Array(Set(names.map { Self.modelName($0) })).sorted() }

    private static func projectPath(_ text: String?) -> String? {
        guard let path = Self.cleaned(text), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func safeCost(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private static func add(_ left: Int, _ right: Int) -> Int {
        let (sum, overflow) = max(0, left).addingReportingOverflow(max(0, right))
        return overflow ? Int.max : sum
    }

    private static func currentStreakDays(activeDays: [MonitorTrendDay], now: Date, calendar: Calendar) -> Int {
        let activeDates = Set(activeDays.map(\.date))
        let today = calendar.startOfDay(for: now)
        var length = 0
        while let day = calendar.date(byAdding: .day, value: -length, to: today), activeDates.contains(day) { length += 1 }
        return length
    }

    private static func longestStreakDays(activeDays: [MonitorTrendDay], calendar: Calendar) -> Int {
        var longest = 0
        var current = 0
        var previous: Date?
        for day in activeDays {
            current = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day.date ? current + 1 : 1
            longest = max(longest, current)
            previous = day.date
        }
        return longest
    }
}
