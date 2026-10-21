import Foundation

/// Software usage includes every monitored identity; the quota selection is independent.
/// Each identity contributes one snapshot, so a CSV replacement and a server refresh never add twice.
nonisolated enum CursorUsageAggregation {
    static func snapshot(
        accounts: [CursorManagedAccount],
        states: [String: CursorAccountState],
        calendar: Calendar = .current
    ) -> ToolUsageSnapshot {
        let enabled = accounts.filter { !$0.isPaused }
        let identities = Dictionary(grouping: enabled, by: \.userID)
        guard !identities.isEmpty else {
            return ToolUsageSnapshot(client: .cursor, availability: accounts.isEmpty ? .needsImport : .sourceMissing,
                evidence: .server, statusDetail: accounts.isEmpty ? "尚未连接 Cursor 账号" : "Cursor 账号采集已暂停")
        }

        var days: [Date: Bucket] = [:]
        var records: [ToolUsageRecord] = []
        var incomplete = 0
        var cachedFailures = 0
        var snapshots: [ToolUsageSnapshot] = []
        var conflictingEvents = false

        for userID in identities.keys.sorted() {
            // A stable user ID, not an email or display name, defines the account boundary.
            let candidates = identities[userID]!.compactMap { account -> (String, CursorAccountState)? in
                states[account.id].map { (account.id, $0) }
            }.sorted {
                let left = $0.1.usage?.refreshedAt ?? .distantPast
                let right = $1.1.usage?.refreshedAt ?? .distantPast
                if left != right { return left > right }
                if $0.1.usage?.evidence != $1.1.usage?.evidence {
                    return $0.1.usage?.evidence == .server
                }
                return $0.0 < $1.0
            }
            guard let state = candidates.first?.1, let source = state.usage else {
                incomplete += 1
                continue
            }
            let stale = state.status == .authenticationRequired || state.status == .failed
                || (source.availability != .ready && source.availability != .noRecords)
            if stale {
                incomplete += 1
                if !source.dailyEntries.isEmpty || !source.usageRecords.isEmpty { cachedFailures += 1 }
            }

            var uniqueRecords: [String: ToolUsageRecord] = [:]
            for record in source.usageRecords {
                if let previous = uniqueRecords[record.id] {
                    if previous != record { conflictingEvents = true }
                    continue
                }
                uniqueRecords[record.id] = record
            }
            let distinct = uniqueRecords.values.sorted {
                $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
            }
            // Rebuild only when records cover the whole snapshot. This both removes duplicate
            // event IDs and rebuckets dates after a timezone change, without losing daily-only history.
            let recordTotal = source.usageRecords.reduce(0.0) { $0 + Double($1.totalTokens) }
            let dailyTotal = source.dailyEntries.reduce(0.0) { $0 + Double($1.totalTokens) }
            let hasFullRecords = !source.usageRecords.isEmpty
                && (source.dailyEntries.isEmpty || recordTotal == dailyTotal)
            let entries: [ToolUsageDailyEntry]
            if hasFullRecords {
                var recordDays: [Date: Bucket] = [:]
                for record in distinct {
                    let day = calendar.startOfDay(for: record.timestamp)
                    var bucket = recordDays[day, default: Bucket()]
                    bucket.add(ToolUsageDailyEntry(date: day, inputTokens: record.inputTokens,
                        outputTokens: record.outputTokens, cacheReadTokens: record.cacheReadTokens,
                        cacheWriteTokens: record.cacheWriteTokens, totalTokens: record.totalTokens,
                        costUSD: record.costUSD, costEvidence: record.costEvidence,
                        billedCostUSD: record.billedCostUSD))
                    recordDays[day] = bucket
                }
                conflictingEvents = conflictingEvents || recordDays.values.contains(where: \.overflow)
                entries = recordDays.keys.sorted().map { recordDays[$0]!.entry(date: $0) }
            } else {
                entries = source.dailyEntries
            }
            let usage = ToolCostEstimator.reprice(ToolUsageSnapshot(client: .cursor,
                availability: source.availability, evidence: source.evidence, dailyEntries: entries,
                usageRecords: distinct, latestUsageAt: source.latestUsageAt,
                refreshedAt: source.refreshedAt, statusDetail: source.statusDetail), calendar: calendar)
            snapshots.append(usage)
            for entry in usage.dailyEntries {
                let day = calendar.startOfDay(for: entry.date)
                var bucket = days[day, default: Bucket()]
                bucket.add(entry)
                days[day] = bucket
            }
            records.append(contentsOf: usage.usageRecords.map { record in
                ToolUsageRecord(id: "cursor-account:\(userID):\(record.id)", timestamp: record.timestamp,
                    modelID: record.modelID, sessionID: record.sessionID, sessionTitle: record.sessionTitle,
                    projectPath: record.projectPath, sessionIsRunning: record.sessionIsRunning,
                    contextWindowTokens: record.contextWindowTokens, contextUsedTokens: record.contextUsedTokens,
                    inputTokens: record.inputTokens, outputTokens: record.outputTokens,
                    cacheReadTokens: record.cacheReadTokens, cacheWriteTokens: record.cacheWriteTokens,
                    cacheWriteOneHourTokens: record.cacheWriteOneHourTokens, totalTokens: record.totalTokens,
                    costUSD: record.costUSD, costEvidence: record.costEvidence, billedCostUSD: record.billedCostUSD)
            })
        }

        let hasHistory = !days.isEmpty || !records.isEmpty
        let partial = incomplete > 0 || conflictingEvents || days.values.contains(where: \.overflow)
        let availability: ToolUsageAvailability = partial ? (hasHistory ? .partial : .failed)
            : (hasHistory ? .ready : .noRecords)
        var detail = "汇总 \(identities.count) 个 Cursor 账号的 Token 用量"
        if cachedFailures > 0 { detail += "；\(cachedFailures) 个账号同步异常，沿用已保存历史" }
        if incomplete > cachedFailures { detail += "；\(incomplete - cachedFailures) 个账号暂未取得完整用量" }
        if conflictingEvents || days.values.contains(where: \.overflow) { detail += "；部分记录存在冲突或超出计数范围" }
        return ToolUsageSnapshot(client: .cursor, availability: availability,
            evidence: !snapshots.isEmpty && snapshots.allSatisfy { $0.evidence == .imported } ? .imported : .server,
            dailyEntries: days.keys.sorted().map { days[$0]!.entry(date: $0) },
            usageRecords: records.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp },
            latestUsageAt: snapshots.compactMap(\.latestUsageAt).max(),
            refreshedAt: snapshots.compactMap(\.refreshedAt).min(), statusDetail: detail)
    }

    private struct Bucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var total = 0
        var knownCost = 0.0
        var hasKnownCost = false
        var completeCost = true
        var estimatedCost = false
        var billedCost = 0.0
        var completeBilling = true
        var overflow = false

        mutating func add(_ entry: ToolUsageDailyEntry) {
            self.input = self.sum(self.input, entry.inputTokens)
            self.output = self.sum(self.output, entry.outputTokens)
            self.cacheRead = self.sum(self.cacheRead, entry.cacheReadTokens)
            self.cacheWrite = self.sum(self.cacheWrite, entry.cacheWriteTokens)
            self.total = self.sum(self.total, entry.totalTokens)
            if let cost = entry.knownCostUSD ?? entry.costUSD, cost.isFinite, cost >= 0 {
                self.knownCost += cost
                self.hasKnownCost = true
            }
            if entry.costUSD == nil { self.completeCost = false }
            self.estimatedCost = self.estimatedCost || entry.costEvidence == .estimated
            if let cost = entry.billedCostUSD, cost.isFinite, cost >= 0 { self.billedCost += cost }
            else { self.completeBilling = false }
        }

        private mutating func sum(_ left: Int, _ right: Int) -> Int {
            let (value, overflow) = left.addingReportingOverflow(max(0, right))
            self.overflow = self.overflow || overflow || right < 0
            return overflow ? Int.max : value
        }

        func entry(date: Date) -> ToolUsageDailyEntry {
            let known = self.hasKnownCost && self.knownCost.isFinite ? self.knownCost : nil
            return ToolUsageDailyEntry(date: date, inputTokens: self.input, outputTokens: self.output,
                cacheReadTokens: self.cacheRead, cacheWriteTokens: self.cacheWrite, totalTokens: self.total,
                costUSD: self.completeCost ? known : nil, knownCostUSD: known,
                costEvidence: known == nil ? nil : (self.estimatedCost ? .estimated : .reported),
                billedCostUSD: self.completeBilling && self.billedCost.isFinite ? self.billedCost : nil)
        }
    }
}
