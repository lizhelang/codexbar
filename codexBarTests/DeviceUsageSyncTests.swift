import Foundation
import Combine
import XCTest
@testable import codexbar

final class DeviceUsageSyncTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("codexbar-sync-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func snapshot(id: String = UUID().uuidString, tokens: Int = 50, generatedAt: Date = Date()) -> DeviceUsageSnapshot {
        DeviceUsageSnapshot(deviceID: id, deviceName: "Synthetic Mac", generatedAt: generatedAt, dailyEntries: [DeviceUsageDailyStat(date: Date(timeIntervalSince1970: 1_700_000_000), toolID: "codex", totalTokens: tokens, knownCostUSD: 1, costIsComplete: true)])
    }

    func testTwoFileDevicesExchangeAndNewerSnapshotReplacesWithoutDoubleCounting() throws {
        let storage = DeviceUsageSnapshotDirectory(url: try self.directory())
        let id = UUID().uuidString
        let first = self.snapshot(id: id, tokens: 10, generatedAt: Date().addingTimeInterval(-10))
        let updated = self.snapshot(id: id, tokens: 20)
        let second = self.snapshot(tokens: 30)
        try storage.write(first)
        try storage.write(second)
        try storage.write(updated)
        try storage.write(first)
        let loaded = try storage.read()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.reduce(0) { $0 + $1.totalTokens }, 50)
        XCTAssertEqual(DeviceUsageSnapshot.latestDevices(loaded, excluding: id).count, 1)
    }

    func testDirectoryRejectsSymlinkDocumentsAndOversizedInput() throws {
        let root = try self.directory()
        let target = root.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: target)
        let symlink = root.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertThrowsError(try DeviceUsageSnapshotDirectory.readRegularFile(symlink, maximumBytes: 100))
        XCTAssertThrowsError(try DeviceUsageSnapshotDirectory.readRegularFile(target, maximumBytes: 1))
        XCTAssertTrue(try DeviceUsageSnapshotDirectory(url: root).read().isEmpty)
    }

    func testSnapshotRejectsTraversalFutureDataDuplicateDaysAndInvalidNumbers() throws {
        XCTAssertThrowsError(try self.snapshot(id: "../escape").validate())
        XCTAssertThrowsError(try self.snapshot(tokens: -1).validate())
        XCTAssertThrowsError(try self.snapshot(generatedAt: Date().addingTimeInterval(600)).validate())
        let base = self.snapshot()
        let duplicate = DeviceUsageSnapshot(deviceID: base.deviceID, deviceName: base.deviceName, dailyEntries: base.dailyEntries + base.dailyEntries)
        XCTAssertThrowsError(try duplicate.validate())
        XCTAssertTrue(self.snapshot(generatedAt: Date().addingTimeInterval(-90_000)).isStale())
    }

    func testHubURLRejectsCredentialLeakPathsAndPublicCleartext() throws {
        XCTAssertThrowsError(try DeviceUsageHubClient.validatedURL("http://example.com"))
        XCTAssertThrowsError(try DeviceUsageHubClient.validatedURL("http://10.0.0.1.attacker.com"))
        XCTAssertThrowsError(try DeviceUsageHubClient.validatedURL("http://10.0..0.1"))
        XCTAssertThrowsError(try DeviceUsageHubClient.validatedURL("https://user:password@example.com"))
        XCTAssertThrowsError(try DeviceUsageHubClient.validatedURL("https://example.com/other-service"))
        XCTAssertNoThrow(try DeviceUsageHubClient.validatedURL("http://127.0.0.1:23948"))
        XCTAssertNoThrow(try DeviceUsageHubClient.validatedURL("http://192.168.1.2:23948"))
    }

    func testLoopbackHubUploadsReadsAndRejectsWrongKey() async throws {
        let storage = DeviceUsageSnapshotDirectory(url: try self.directory())
        let secret = String(repeating: "synthetic-key-", count: 4)
        let server = DeviceUsageHubServer(directory: storage, secret: secret)
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let client = DeviceUsageHubClient(baseURL: url, secret: secret)
        let first = try await client.exchange(self.snapshot(tokens: 10))
        XCTAssertEqual(first.count, 1)
        let second = try await client.exchange(self.snapshot(tokens: 20))
        XCTAssertEqual(second.reduce(0) { $0 + $1.totalTokens }, 30)
        do {
            _ = try await DeviceUsageHubClient(baseURL: url, secret: String(repeating: "wrong", count: 8)).exchange(nil)
            XCTFail("Hub accepted an invalid key")
        } catch DeviceUsageSyncError.unauthorized {} catch { XCTFail("Unexpected error: \(type(of: error))") }
    }

    @MainActor
    func testDefaultServiceDoesNotStartNetworkAndExcludesAccountWideCursor() throws {
        let service = DeviceUsageSyncService(storageURL: try self.directory(), startConfiguredMode: false)
        XCTAssertEqual(service.configuration.mode, .local)
        XCTAssertNil(service.listeningPort)
        var summary = LocalCostSummary.empty
        summary.updatedAt = Date()
        service.publishLocalUsage(codex: summary, tools: [.cursor: ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .server, dailyEntries: [ToolUsageDailyEntry(date: Date(), totalTokens: 999)])])
        XCTAssertEqual(service.localSnapshot?.totalTokens, 0)
        XCTAssertFalse(service.isSyncing)
        XCTAssertNil(service.lastSyncAt)
    }
    @MainActor
    func testPartialToolCostSurvivesDeviceSnapshotWithoutClaimingCompleteBill() throws {
        let service = DeviceUsageSyncService(storageURL: try self.directory(), startConfiguredMode: false)
        let tool = ToolUsageSnapshot(client: .openCode, availability: .ready, dailyEntries: [
            ToolUsageDailyEntry(date: Date(), totalTokens: 100, knownCostUSD: 1.25, costEvidence: .estimated)
        ])
        service.publishLocalUsage(codex: .empty, tools: [.openCode: tool])
        let entry = try XCTUnwrap(service.localSnapshot?.dailyEntries.first)
        XCTAssertEqual(entry.totalTokens, 100)
        XCTAssertEqual(entry.knownCostUSD, 1.25)
        XCTAssertFalse(entry.costIsComplete)
    }

    @MainActor
    func testDisablingToolsRemovesPreviouslyCachedUsageIncludingAllDisabled() throws {
        let service = DeviceUsageSyncService(storageURL: try self.directory(), startConfiguredMode: false)
        var summary = LocalCostSummary.empty
        summary.updatedAt = Date()
        summary.dailyEntries = [DailyCostEntry(id: "day", date: Date().addingTimeInterval(-100), costUSD: 1, totalTokens: 200)]
        service.publishLocalUsage(codex: summary, tools: [:])
        XCTAssertEqual(service.localSnapshot?.totalTokens, 200)
        service.publishLocalUsage(codex: .empty, tools: [:], enabledToolIDs: [])
        XCTAssertEqual(service.localSnapshot?.totalTokens, 0)
        XCTAssertTrue(service.localSnapshot?.dailyEntries.isEmpty == true)
    }

    @MainActor
    func testUnchangedStatisticsDoNotRepublishAndBackgroundCacheKeepsLatestValue() async throws {
        let root = try self.directory()
        let service = DeviceUsageSyncService(storageURL: root, startConfiguredMode: false)
        let firstDate = Date().addingTimeInterval(-60)
        var summary = LocalCostSummary.empty
        summary.updatedAt = firstDate
        summary.dailyEntries = [DailyCostEntry(id: "day", date: firstDate, costUSD: 1, totalTokens: 200)]
        var emissions = 0
        let subscription = service.$localSnapshot.dropFirst().sink { _ in emissions += 1 }
        defer { subscription.cancel() }

        service.publishLocalUsage(codex: summary, tools: [:], now: firstDate)
        summary.updatedAt = Date()
        service.publishLocalUsage(codex: summary, tools: [:])
        XCTAssertEqual(emissions, 1, "A scan with identical totals must not rebuild the device UI")
        XCTAssertEqual(service.localSnapshot?.generatedAt, firstDate)

        summary.dailyEntries = [DailyCostEntry(id: "day", date: firstDate, costUSD: 2, totalTokens: 400)]
        service.publishLocalUsage(codex: summary, tools: [:])
        await service.waitForPendingCacheWrites()
        let cached = try JSONDecoder().decode(DeviceUsageSnapshot.self, from: Data(contentsOf: root.appendingPathComponent("local-cache.json")))
        XCTAssertEqual(emissions, 2)
        XCTAssertEqual(cached.totalTokens, 400, "Serialized background writes must leave the newest totals on disk")
    }

}
