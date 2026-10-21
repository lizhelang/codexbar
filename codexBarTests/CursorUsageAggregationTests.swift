import Foundation
import XCTest
@testable import codexbar

final class CursorUsageAggregationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testSoftwareUsageIncludesExpiredAccountHistoryAlongsideOtherAccount() {
        let old = self.account("user_old")
        let current = self.account("user_current")
        let result = CursorUsageAggregation.snapshot(accounts: [old, current], states: [
            old.id: .init(usage: self.usage(tokens: 32_491_543, availability: .failed), status: .authenticationRequired),
            current.id: .init(usage: self.usage(tokens: 10), status: .ready)
        ], calendar: self.calendar)
        XCTAssertEqual(result.dailyEntries.first?.totalTokens, 32_491_553)
        XCTAssertEqual(result.availability, .partial)
        XCTAssertTrue(result.statusDetail?.contains("2 个 Grok 账号") == true)
        XCTAssertTrue(result.statusDetail?.contains("1 个账号同步异常") == true)
    }

    func testSameIdentityContributesOnlyLatestSnapshotAcrossImportAndServer() {
        let first = self.account("source_csv", userID: "user_same")
        let second = self.account("source_server", userID: "user_same")
        let csv = self.usage(tokens: 100, evidence: .imported, refreshedAt: self.now.addingTimeInterval(-60))
        let server = self.usage(tokens: 80, refreshedAt: self.now)
        let result = CursorUsageAggregation.snapshot(accounts: [first, second], states: [
            first.id: .init(usage: csv, status: .ready), second.id: .init(usage: server, status: .ready)
        ], calendar: self.calendar)
        XCTAssertEqual(result.dailyEntries.first?.totalTokens, 80)
        XCTAssertEqual(result.usageRecords.count, 1)
        XCTAssertTrue(result.statusDetail?.contains("1 个 Grok 账号") == true)
    }

    func testSameEventIdentifierIsDeduplicatedWithinIdentityButNotAcrossAccounts() {
        let first = self.account("user_first")
        let second = self.account("user_second")
        let event = ToolUsageRecord(id: "event", timestamp: self.now, totalTokens: 10, costUSD: 0.5)
        let duplicate = ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .server,
            dailyEntries: [.init(date: self.calendar.startOfDay(for: self.now), totalTokens: 20, costUSD: 1)],
            usageRecords: [event, event], refreshedAt: self.now)
        let result = CursorUsageAggregation.snapshot(accounts: [first, second], states: [
            first.id: .init(usage: duplicate, status: .ready),
            second.id: .init(usage: self.usage(tokens: 10), status: .ready)
        ], calendar: self.calendar)
        XCTAssertEqual(result.dailyEntries.first?.totalTokens, 20)
        XCTAssertEqual(result.usageRecords.count, 2)
        XCTAssertEqual(Set(result.usageRecords.map(\.id)).count, 2)
    }

    func testPausedAccountsAreExcludedAndMissingEnabledAccountMakesKnownHistoryPartial() {
        var paused = self.account("user_paused")
        paused.isPaused = true
        let ready = self.account("user_ready")
        let missing = self.account("user_missing")
        let result = CursorUsageAggregation.snapshot(accounts: [paused, ready, missing], states: [
            paused.id: .init(usage: self.usage(tokens: 1_000), status: .paused),
            ready.id: .init(usage: self.usage(tokens: 10), status: .ready)
        ], calendar: self.calendar)
        XCTAssertEqual(result.dailyEntries.first?.totalTokens, 10)
        XCTAssertEqual(result.availability, .partial)
        XCTAssertTrue(result.statusDetail?.contains("2 个 Grok 账号") == true)
    }

    func testLegacyDailyOnlyHistoryAndKnownCostRemainAlongsideDetailedAccount() {
        let first = self.account("user_legacy")
        let second = self.account("user_detailed")
        let legacy = ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .imported,
            dailyEntries: [.init(date: self.now, totalTokens: 100, knownCostUSD: 2)], refreshedAt: self.now)
        let result = CursorUsageAggregation.snapshot(accounts: [first, second], states: [
            first.id: .init(usage: legacy, status: .ready),
            second.id: .init(usage: self.usage(tokens: 10), status: .ready)
        ], calendar: self.calendar)
        XCTAssertEqual(result.dailyEntries.first?.totalTokens, 110)
        XCTAssertNil(result.dailyEntries.first?.costUSD)
        XCTAssertEqual(result.dailyEntries.first?.knownCostUSD, 2.5)
        XCTAssertEqual(result.usageRecords.count, 1)
    }

    func testCompleteRecordsAreRebucketedUsingCurrentTimezone() {
        let account = self.account("user_timezone")
        let usage = self.usage(tokens: 10)
        var localCalendar = self.calendar
        localCalendar.timeZone = TimeZone(secondsFromGMT: 11 * 3600)!
        let result = CursorUsageAggregation.snapshot(accounts: [account], states: [
            account.id: .init(usage: usage, status: .ready)
        ], calendar: localCalendar)
        XCTAssertEqual(result.dailyEntries.first?.date, localCalendar.startOfDay(for: self.now))
        XCTAssertEqual(result.dailyEntries.first?.totalTokens, 10)
    }

    func testNoSuccessfulSourceDoesNotProduceReadyZero() {
        let account = self.account("user_missing")
        let result = CursorUsageAggregation.snapshot(accounts: [account], states: [
            account.id: .init(status: .authenticationRequired)
        ], calendar: self.calendar)
        XCTAssertEqual(result.availability, .failed)
        XCTAssertTrue(result.dailyEntries.isEmpty)
    }

    private func account(_ id: String, userID: String? = nil) -> CursorManagedAccount {
        CursorManagedAccount(id: id, userID: userID ?? id, email: nil, name: nil, planType: nil,
            alias: "", source: .manual, isPaused: false, createdAt: self.now, updatedAt: self.now)
    }

    private func usage(tokens: Int, availability: ToolUsageAvailability = .ready,
                       evidence: ToolUsageEvidence = .server, refreshedAt: Date? = nil) -> ToolUsageSnapshot {
        ToolUsageSnapshot(client: .cursor, availability: availability, evidence: evidence,
            dailyEntries: [.init(date: self.calendar.startOfDay(for: self.now), totalTokens: tokens, costUSD: 0.5)],
            usageRecords: [.init(id: "event", timestamp: self.now, totalTokens: tokens, costUSD: 0.5)],
            latestUsageAt: self.now, refreshedAt: refreshedAt ?? self.now)
    }
}
