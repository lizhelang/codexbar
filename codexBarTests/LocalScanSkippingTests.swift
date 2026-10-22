import Foundation
import XCTest

@MainActor
final class LocalScanSkippingTests: XCTestCase {
    func testSnapshotContentChangeIgnoresRefreshTime() {
        let entry = ToolUsageDailyEntry(date: Date(timeIntervalSince1970: 0), totalTokens: 10)
        let first = ToolUsageSnapshot(client: .claudeCode, availability: .ready, dailyEntries: [entry],
                                      refreshedAt: Date(timeIntervalSince1970: 100))
        let rescanned = first.refreshed(at: Date(timeIntervalSince1970: 200))
        let grown = ToolUsageSnapshot(client: .claudeCode, availability: .ready,
                                      dailyEntries: [ToolUsageDailyEntry(date: entry.date, totalTokens: 11)],
                                      refreshedAt: Date(timeIntervalSince1970: 200))

        XCTAssertTrue(first.hasSameContent(as: rescanned))
        XCTAssertNotEqual(first, rescanned)
        XCTAssertFalse(ToolUsageStore.snapshotContentChanged(from: [.claudeCode: first], to: [.claudeCode: rescanned]))
        XCTAssertTrue(ToolUsageStore.snapshotContentChanged(from: [.claudeCode: first], to: [.claudeCode: grown]))
        XCTAssertTrue(ToolUsageStore.snapshotContentChanged(from: [:], to: [.claudeCode: first]))
    }

    func testGateAlwaysScansWithoutAWatchableRoot() {
        var gate = LocalScanGate()
        gate.watch([URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/sessions")])
        XCTAssertNil(gate.monitor)
        gate.markScanStarted(uptime: 100)
        XCTAssertTrue(gate.shouldScan(maximumAge: 900, uptime: 101))
    }

    func testGateSkipsUntilAFileEventOrTheSafetyWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScanSkippingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var gate = LocalScanGate()
        gate.watch([root])
        let monitor = try XCTUnwrap(gate.monitor)
        XCTAssertTrue(gate.shouldScan(maximumAge: 900, uptime: 100), "first scan always runs")
        gate.markScanStarted(uptime: 100)
        XCTAssertFalse(gate.shouldScan(maximumAge: 900, uptime: 200))
        XCTAssertTrue(gate.shouldScan(maximumAge: 900, uptime: 1_000), "safety window forces a rescan")
        let rebuilt = gate.watch([root])
        XCTAssertFalse(rebuilt, "same roots keep the running monitor")

        let before = monitor.currentChangeCount
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let deadline = Date().addingTimeInterval(15)
        while monitor.currentChangeCount == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertNotEqual(monitor.currentChangeCount, before)
        XCTAssertTrue(gate.shouldScan(maximumAge: 900, uptime: 200))
    }
}
