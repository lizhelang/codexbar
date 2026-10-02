import XCTest

@MainActor
final class SubscriptionRecordStoreTests: XCTestCase {
    func testRecordsPersistEditAndRemoveWithoutCredentials() throws {
        let suite = "SubscriptionRecordStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SubscriptionRecordStore(defaults: defaults)
        var record = SubscriptionRecord()
        record.provider = " Claude Code "
        record.planName = "Pro"
        record.amount = 20
        record.currency = "usd"
        try store.save(record)
        let reopened = SubscriptionRecordStore(defaults: defaults)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.records.first?.provider, "Claude Code")
        XCTAssertEqual(reopened.records.first?.currency, "USD")
        record.amount = 100
        try reopened.save(record)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.records.first?.amount, 100)
        try reopened.remove(id: record.id)
        XCTAssertTrue(SubscriptionRecordStore(defaults: defaults).records.isEmpty)
    }

    func testRejectsInvalidAmountAndRetainsPreviousRecord() throws {
        let suite = "SubscriptionRecordStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SubscriptionRecordStore(defaults: defaults)
        var record = SubscriptionRecord()
        record.amount = 20
        try store.save(record)
        record.amount = .nan
        XCTAssertThrowsError(try store.save(record))
        record.amount = -1
        XCTAssertThrowsError(try store.save(record))
        XCTAssertEqual(store.records.first?.amount, 20)
    }

    func testAutomaticRenewalUsesCalendarAndTopUpsDoNotRenew() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var record = SubscriptionRecord()
        record.startDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        XCTAssertEqual(record.estimatedNextRenewal(now: now, calendar: calendar), expected)
        record.kind = .topUp
        XCTAssertNil(record.estimatedNextRenewal(now: now, calendar: calendar))
        record.kind = .subscription
        record.autoRenew = false
        XCTAssertNil(record.estimatedNextRenewal(now: now, calendar: calendar))
    }
    func testMonthlyRenewalKeepsOriginalBillingDayAcrossFebruary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var record = SubscriptionRecord()
        record.startDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31)))
        XCTAssertEqual(record.estimatedNextRenewal(now: now, calendar: calendar), expected)
    }

}
