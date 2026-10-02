import Foundation
import XCTest

final class DeviceUsageBreakdownTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        calendar.firstWeekday = 2
        return calendar
    }

    func testDeviceTotalEqualsFilteredToolRowsAndCosts() {
        let now = self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
        let day = self.calendar.startOfDay(for: now)
        let old = self.calendar.date(byAdding: .day, value: -1, to: day)!
        let snapshot = DeviceUsageSnapshot(deviceID: UUID().uuidString, deviceName: "Fixture", generatedAt: now,
            timeZoneIdentifier: self.calendar.timeZone.identifier, dailyEntries: [
                .init(date: day, toolID: "codex", totalTokens: 100, knownCostUSD: 1, costIsComplete: true),
                .init(date: day, toolID: "openCode", totalTokens: 50, knownCostUSD: 0.5, costIsComplete: false),
                .init(date: old, toolID: "codex", totalTokens: 900, knownCostUSD: 9, costIsComplete: true),
                .init(date: day, toolID: "claudeCode", totalTokens: 700, knownCostUSD: 7, costIsComplete: true),
            ])
        let result = DeviceUsageBreakdown.build(device: snapshot, period: .thisMonth,
            enabledToolIDs: ["codex", "openCode"], now: now, calendar: self.calendar)
        XCTAssertEqual(result.aggregate.tokens, 150)
        XCTAssertEqual(result.tools.reduce(0) { $0 + $1.totalTokens }, result.aggregate.tokens)
        XCTAssertEqual(result.aggregate.knownCostUSD, 1.5)
        XCTAssertFalse(result.aggregate.costIsComplete)
        XCTAssertEqual(result.tools.map(\.toolID), ["codex", "openCode"])
        XCTAssertEqual(result.tools.reduce(0) { $0 + $1.fraction }, 1, accuracy: 0.0001)
        XCTAssertEqual(result.activeDayCount, 1)
    }

    func testDateFiltersUseSourceTimeZoneAndExcludeFutureData() {
        let now = self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 1))!
        var source = self.calendar
        source.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sourceDay = source.startOfDay(for: now)
        let previousDay = source.date(byAdding: .day, value: -1, to: sourceDay)!
        let snapshot = DeviceUsageSnapshot(deviceID: UUID().uuidString, deviceName: "Remote", generatedAt: now,
            timeZoneIdentifier: source.timeZone.identifier, dailyEntries: [
                .init(date: sourceDay, toolID: "codex", totalTokens: 10),
                .init(date: previousDay, toolID: "codex", totalTokens: 20),
                .init(date: now.addingTimeInterval(3600), toolID: "codex", totalTokens: 30),
            ])
        let result = DeviceUsageBreakdown.build(device: snapshot, period: .today, enabledToolIDs: ["codex"], now: now, calendar: self.calendar)
        XCTAssertEqual(result.aggregate.tokens, 10)
    }

    func testEmptyAndOverflowingDeviceTotalsRemainFinite() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let snapshot = DeviceUsageSnapshot(deviceID: UUID().uuidString, deviceName: "Fixture", dailyEntries: [
            .init(date: day, toolID: "codex", totalTokens: .max, knownCostUSD: .greatestFiniteMagnitude, costIsComplete: true),
            .init(date: day, toolID: "openCode", totalTokens: .max, knownCostUSD: .greatestFiniteMagnitude, costIsComplete: true),
        ])
        let empty = DeviceUsageBreakdown.build(device: snapshot, period: .allTime, enabledToolIDs: [], now: now)
        XCTAssertTrue(empty.tools.isEmpty)
        XCTAssertEqual(empty.aggregate.tokens, 0)
        let result = DeviceUsageBreakdown.build(device: snapshot, period: .allTime, enabledToolIDs: ["codex", "openCode"], now: now)
        XCTAssertEqual(result.aggregate.tokens, Int.max)
        XCTAssertTrue(result.aggregate.knownCostUSD.isFinite)
        XCTAssertEqual(result.tools.reduce(0) { $0 + $1.fraction }, 1, accuracy: 0.0001)
    }
}
