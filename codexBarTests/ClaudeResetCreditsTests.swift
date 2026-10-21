import Foundation
import XCTest
@testable import codexbar

final class ClaudeResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    func testOldQuotaCacheWithoutResetInventoryRemainsUnknownAndNewInventoryRoundTrips() throws {
        let old = Data(#"{"client":"claudeCode","status":"ready","providerName":"Claude","windows":[],"statusDetail":"legacy"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ToolQuotaSnapshot.self, from: old).resetCredits)

        let parsed = self.parse([self.grant("available", remaining: 2, expiresAt: self.now.addingTimeInterval(3600))])
        let restored = try JSONDecoder().decode(ToolQuotaSnapshot.self, from: JSONEncoder().encode(parsed))
        XCTAssertEqual(restored, parsed)
        XCTAssertEqual(restored.resetCredits?.availableCount(at: self.now), 2)
        XCTAssertEqual(restored.resetCredits?.availableCount(at: self.now.addingTimeInterval(3600)), 0,
                       "缓存中的卡片也应随真实到期时间失效")
    }

    func testInventoryFiltersPausedFutureExpiredAndSpentGrantsButKeepsUsableLaterStock() throws {
        var paused = self.grant("paused", remaining: 5); paused["paused"] = true
        var future = self.grant("future", remaining: 5); future["starts_at"] = self.iso(self.now.addingTimeInterval(60))
        let expired = self.grant("expired", remaining: 5, expiresAt: self.now)
        let spent = self.grant("spent", remaining: 0)
        var later = self.grant("usable-later", remaining: 2, expiresAt: self.now.addingTimeInterval(120))
        later["usable_now"] = false; later["clears"] = ["five_hour", "seven_day"]
        let noExpiry = self.grant("no-expiry", remaining: 1)
        let inventory = try XCTUnwrap(self.parse([noExpiry, paused, future, expired, spent, later]).resetCredits)
        XCTAssertEqual(inventory.activeGrants(at: self.now).map(\.id), ["usable-later", "no-expiry"])
        XCTAssertEqual(inventory.availableCount(at: self.now), 3)
        XCTAssertEqual(inventory.activeGrants(at: self.now).first?.usableNow, false,
                       "暂时不能使用不等于没有库存")
        XCTAssertEqual(inventory.activeGrants(at: self.now).first?.clears, ["five_hour", "seven_day"])
        XCTAssertFalse(inventory.hasMalformedGrants)
        XCTAssertEqual(inventory.availableCount(at: self.now.addingTimeInterval(120)), 6,
                       "重新展示时，应同时更新已经开始和刚刚到期的卡片")
    }

    func testPresentInvalidDateCannotBecomeAnUnlimitedLifetimeGrant() throws {
        for field in ["starts_at", "ends_at"] {
            for invalid in ["invalid-date", "", 123, true] as [Any] {
                var bad = self.grant("bad", remaining: 4); bad[field] = invalid
                let inventory = try XCTUnwrap(self.parse([bad, self.grant("valid", remaining: 1)]).resetCredits)
                XCTAssertEqual(inventory.grants.map(\.id), ["valid"], "\(field): \(invalid)")
                XCTAssertEqual(inventory.availableCount(at: self.now), 1)
                XCTAssertTrue(inventory.hasMalformedGrants)
            }
        }
        var inverted = self.grant("inverted", remaining: 3, expiresAt: self.now)
        inverted["starts_at"] = self.iso(self.now)
        let invalidRange = try XCTUnwrap(self.parse([inverted]).resetCredits)
        XCTAssertTrue(invalidRange.grants.isEmpty)
        XCTAssertTrue(invalidRange.hasMalformedGrants)
    }

    func testIneligibleInventoryIsDistinctFromMissingAndConfirmedEmptyInventory() throws {
        let notProvided = ToolQuotaService.parseClaude(["five_hour": ["utilization": 20]], now: self.now)
        XCTAssertNil(notProvided.resetCredits)
        let ineligible = ToolQuotaService.parseClaude([
            "five_hour": ["utilization": 20],
            "cedar_ember": ["eligible": false, "ineligible_reason": "surface", "grants": [self.grant("ignored", remaining: 2)]],
        ], now: self.now)
        let inventory = try XCTUnwrap(ineligible.resetCredits)
        XCTAssertFalse(inventory.eligible)
        XCTAssertEqual(inventory.ineligibleReason, "surface")
        XCTAssertTrue(inventory.activeGrants(at: self.now).isEmpty)
        let empty = try XCTUnwrap(self.parse([]).resetCredits)
        XCTAssertTrue(empty.eligible)
        XCTAssertFalse(empty.hasMalformedGrants)
        XCTAssertTrue(empty.grants.isEmpty)
        XCTAssertNotEqual(empty, inventory, "不支持当前入口不能丢失资格状态并被当成已确认空库存")
        for invalidEligible in [1, "true", NSNull()] as [Any] {
            XCTAssertNil(ToolQuotaService.parseClaude(["cedar_ember": ["eligible": invalidEligible, "grants": []]], now: self.now).resetCredits)
        }
    }

    func testMalformedCountsAndDuplicateIDsDoNotInflateResetStock() throws {
        let invalidCounts: [Any] = [-1, 1.5, Double.nan, Double.infinity, true, "NaN", 51]
        for invalid in invalidCounts {
            var bad = self.grant("bad", remaining: 1); bad["resets_left"] = invalid
            let inventory = try XCTUnwrap(self.parse([bad, self.grant("valid", remaining: 2)]).resetCredits)
            XCTAssertEqual(inventory.availableCount(at: self.now), 2)
            XCTAssertTrue(inventory.hasMalformedGrants)
        }
        let duplicate = try XCTUnwrap(self.parse([self.grant("same", remaining: 2), self.grant("same", remaining: 3)]).resetCredits)
        XCTAssertEqual(duplicate.availableCount(at: self.now), 2)
        XCTAssertTrue(duplicate.hasMalformedGrants)

        var invalidTotal = self.grant("bad-total", remaining: 2); invalidTotal["resets_total"] = 1
        var invalidPause = self.grant("bad-pause", remaining: 2); invalidPause["paused"] = 0
        var missingPause = self.grant("missing-pause", remaining: 2); missingPause.removeValue(forKey: "paused")
        let badFields = try XCTUnwrap(self.parse([invalidTotal, invalidPause, missingPause]).resetCredits)
        XCTAssertTrue(badFields.grants.isEmpty)
        XCTAssertTrue(badFields.hasMalformedGrants)
    }

    func testOversizedInventoryIsUnknownRatherThanTruncatedIntoAConfidentCount() {
        XCTAssertNil(self.parse([self.grant("one", remaining: 26), self.grant("two", remaining: 25)]).resetCredits)
        XCTAssertNil(self.parse((0..<201).map { self.grant("grant-\($0)", remaining: 0) }).resetCredits)
        XCTAssertNil(ToolQuotaService.parseClaude(["cedar_ember": ["eligible": true, "grants": "wrong-shape"]], now: self.now).resetCredits)
        XCTAssertNil(ToolQuotaService.parseClaude(["cedar_ember": ["eligible": true]], now: self.now).resetCredits)
    }

    @MainActor
    func testFailedRefreshPreservesResetOnlyInventoryWithFailureStateAcrossReload() async throws {
        for error in [ToolConnectionError.networkFailure, .authenticationRequired] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-reset-cache-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = self.parse([self.grant("cached", remaining: 2, expiresAt: self.now.addingTimeInterval(3600))])
            let service = ResetCreditStoreFixtureService(snapshot: original)
            let store = ToolConnectionStore(directory: directory, service: service)
            try await store.saveClaudeOAuth(accessToken: "fixture-reset-access")
            await service.fail(error)
            await store.refresh(profileID: "claudeCode", force: true, now: self.now.addingTimeInterval(60))
            let failure = try XCTUnwrap(store.quota(for: "claudeCode"))
            XCTAssertEqual(failure.status, error == .authenticationRequired ? .authenticationRequired : .failed)
            XCTAssertEqual(failure.resetCredits, original.resetCredits)
            XCTAssertEqual(failure.refreshedAt, original.refreshedAt)
            XCTAssertTrue(failure.windows.isEmpty)
            XCTAssertNil(failure.balance)
            XCTAssertTrue(failure.statusDetail.contains("尚未确认"))
            let restored = ToolConnectionStore(directory: directory, service: service)
            XCTAssertEqual(restored.quota(for: "claudeCode"), failure)
        }
    }

    @MainActor
    func testFreshIneligibleOrEmptyInventoryReplacesOldAvailableGrants() async throws {
        for inventory in [ClaudeResetCredits(eligible: false, ineligibleReason: "surface"), ClaudeResetCredits(eligible: true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-reset-new-state-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = ResetCreditStoreFixtureService(snapshot: self.parse([self.grant("old", remaining: 2)]))
            let store = ToolConnectionStore(directory: directory, service: service)
            try await store.saveClaudeOAuth(accessToken: "fixture-reset-access")
            let fresh = ToolQuotaSnapshot(client: .claudeCode, status: .unsupported, providerName: "Claude",
                refreshedAt: self.now.addingTimeInterval(60), statusDetail: "fixture fresh response", resetCredits: inventory)
            await service.replace(fresh)
            await store.refresh(profileID: "claudeCode", force: true, now: self.now.addingTimeInterval(60))
            XCTAssertEqual(store.quota(for: "claudeCode"), fresh, "明确的新资格/空库存不得被旧卡覆盖")
            let restored = ToolConnectionStore(directory: directory, service: service)
            XCTAssertEqual(restored.quota(for: "claudeCode"), fresh)
        }
    }

    private func parse(_ grants: [[String: Any]]) -> ToolQuotaSnapshot {
        ToolQuotaService.parseClaude(["cedar_ember": ["eligible": true, "grants": grants]], now: self.now)
    }

    private func grant(_ id: String, remaining: Int, expiresAt: Date? = nil) -> [String: Any] {
        var result: [String: Any] = ["id": id, "paused": false, "resets_left": remaining]
        if let expiresAt { result["ends_at"] = self.iso(expiresAt) }
        return result
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private actor ResetCreditStoreFixtureService: ToolConnectionServicing {
    private var snapshot: ToolQuotaSnapshot
    private var failure: ToolConnectionError?

    init(snapshot: ToolQuotaSnapshot) { self.snapshot = snapshot }
    func replace(_ snapshot: ToolQuotaSnapshot) { self.snapshot = snapshot; self.failure = nil }
    func fail(_ error: ToolConnectionError) { self.failure = error }
    func discover(client: ToolUsageClient, preferences: ApplicationPreferences) async throws -> [DiscoveredToolConnection] { [] }
    func organizations(sessionKey: String) async throws -> [ClaudeOrganization] { [] }
    func query(profile: ManagedToolConnection, credential: ManagedToolCredential, now: Date) async throws -> ManagedToolQuotaResult {
        if let failure { throw failure }
        return ManagedToolQuotaResult(snapshot: self.snapshot, displayLabel: "fixture@example.test",
            accountIdentity: "account:reset-fixture:organization:reset-org")
    }
}
