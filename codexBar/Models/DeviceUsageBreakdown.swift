import Foundation

/// A single pass over device days supplies both the device total and its expandable tool rows.
nonisolated struct DeviceUsageBreakdown: Equatable, Identifiable, Sendable {
    struct Tool: Equatable, Identifiable, Sendable {
        let toolID: String
        let totalTokens: Int
        let knownCostUSD: Double
        let costIsComplete: Bool
        let fraction: Double
        var id: String { self.toolID }
    }

    let device: DeviceUsageSnapshot
    let tools: [Tool]
    let aggregate: UsageAggregate
    let activeDayCount: Int
    var id: String { self.device.deviceID }

    static func build(device: DeviceUsageSnapshot, period: UsagePeriod, enabledToolIDs: Set<String>, now: Date, calendar: Calendar = .current) -> Self {
        var sourceCalendar = calendar
        sourceCalendar.timeZone = TimeZone(identifier: device.timeZoneIdentifier) ?? calendar.timeZone
        let firstDay = period.firstDay(now: now, calendar: sourceCalendar)
        struct Counters {
            var tokens = 0
            var cost = 0.0
            var complete = true
        }
        var byTool: [String: Counters] = [:]
        var activeDays = Set<Date>()
        var latestUsageAt: Date?
        for entry in device.dailyEntries {
            guard enabledToolIDs.contains(entry.toolID), entry.date <= now,
                  firstDay.map({ entry.date >= $0 }) ?? true else { continue }
            var counters = byTool[entry.toolID] ?? Counters()
            let tokens = max(0, entry.totalTokens)
            counters.tokens = self.add(counters.tokens, tokens)
            let validCost = entry.knownCostUSD.isFinite && entry.knownCostUSD >= 0
            counters.cost = self.add(counters.cost, validCost ? entry.knownCostUSD : 0)
            counters.complete = counters.complete && entry.costIsComplete && validCost
            byTool[entry.toolID] = counters
            if tokens > 0 { activeDays.insert(sourceCalendar.startOfDay(for: entry.date)) }
            latestUsageAt = max(latestUsageAt ?? entry.date, entry.date)
        }
        let denominator = byTool.values.reduce(0.0) { $0 + Double($1.tokens) }
        var rows: [Tool] = byTool.map { entry in
            let counters = entry.value
            let fraction = denominator > 0 ? Double(counters.tokens) / denominator : 0.0
            return Tool(toolID: entry.key, totalTokens: counters.tokens, knownCostUSD: counters.cost,
                        costIsComplete: counters.complete, fraction: fraction)
        }
        rows.sort { left, right in
            if left.totalTokens == right.totalTokens { return left.toolID < right.toolID }
            return left.totalTokens > right.totalTokens
        }
        return Self(device: device, tools: rows, aggregate: UsageAggregate(
            tokens: rows.reduce(0) { self.add($0, $1.totalTokens) },
            knownCostUSD: rows.reduce(0) { self.add($0, $1.knownCostUSD) },
            costIsComplete: rows.allSatisfy(\.costIsComplete), dailyEntries: [], latestUsageAt: latestUsageAt
        ), activeDayCount: activeDays.count)
    }

    private static func add(_ left: Int, _ right: Int) -> Int {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func add(_ left: Double, _ right: Double) -> Double {
        let sum = left + right
        return sum.isFinite ? sum : Double.greatestFiniteMagnitude
    }
}
