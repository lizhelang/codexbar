import Foundation
import XCTest
@testable import codexbar

final class CursorBillingCSVParserTests: XCTestCase {
    private let parser = CursorBillingCSVParser()
    private let now = Date(timeIntervalSince1970: 1_792_540_800) // 2026-10-21T00:00:00Z
    private let header = "Billing Item ID,Event Time,Product,Charge Category,Usage Type,Principal Type,Principal ID,Usage,Pricing Currency,Pricing Contracted,Model,User Email"

    func testParsesRemoteBotChatAndCursorTokensWithoutAccountOrSessionMetadata() throws {
        let usage = #"{"cache-write-text-tokens":"4","cached-prompt-text-tokens":"30","completion-text-tokens":"2","prompt-text-tokens":"10"}"#
        let records = try self.parser.parse(self.csv([
            self.row(id: "bot", product: "grok-bot", usage: usage, model: "grok-bot-default"),
            self.row(id: "chat", product: "grok-chat", usage: usage, model: "grok-4.1"),
            self.row(id: "editor", product: "cursor", usage: usage, model: ""),
        ]), now: self.now)
        XCTAssertEqual(records.map(\.id), ["cursor-billing:grok-bot:bot", "cursor-billing:grok-chat:chat", "cursor-billing:cursor:editor"])
        XCTAssertEqual(records.map(\.modelID), ["grok-bot-default", "grok-4.1", nil])
        for record in records {
            XCTAssertEqual(record.inputTokens, 10)
            XCTAssertEqual(record.outputTokens, 2)
            XCTAssertEqual(record.cacheReadTokens, 30)
            XCTAssertEqual(record.cacheWriteTokens, 4)
            XCTAssertEqual(record.totalTokens, 46)
            XCTAssertNil(record.sessionID)
            XCTAssertNil(record.sessionTitle)
            XCTAssertNil(record.projectPath)
            XCTAssertNil(record.costUSD)
            XCTAssertNil(record.costEvidence)
            XCTAssertEqual(record.billedCostUSD, 0)
        }
        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private@example.test") || encoded.contains("private-principal"))
    }

    func testRejectsUnknownProductInsteadOfMixingUnsupportedLedger() {
        for product in ["", "future-product"] {
            XCTAssertThrowsError(try self.parser.parse(self.csv([self.row(product: product)]), now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .invalidRow(2))
            }
        }
    }

    func testCanonicalizesSpacedTokenKeysAndDeduplicatesEqualAliases() throws {
        let usage = #"{"Prompt text tokens":"10","prompt-text-tokens":"10","Completion text tokens":"2","Cached prompt text tokens":"30","cache-write-text-tokens":"4"}"#
        let record = try XCTUnwrap(self.parser.parse(self.csv([self.row(usage: usage)]), now: self.now).first)
        XCTAssertEqual(record.totalTokens, 46)
        XCTAssertEqual(record.inputTokens, 10)
        let conflict = #"{"Prompt text tokens":"10","prompt-text-tokens":"11"}"#
        XCTAssertThrowsError(try self.parser.parse(self.csv([self.row(usage: conflict)]), now: self.now)) { error in
            XCTAssertEqual(error as? CursorBillingCSVError, .invalidRow(2))
        }
    }

    func testHeaderOnlyExportIsValidAndBlankDocumentIsNot() throws {
        XCTAssertEqual(try self.parser.parse(self.header + "\r\n", now: self.now), [])
        for text in ["", "\n\r\n", "\u{FEFF} \n"] {
            XCTAssertThrowsError(try self.parser.parse(text, now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .empty)
            }
        }
    }

    func testRequiresUniqueCompleteHeaderAndExactRowWidth() {
        for header in [self.header.replacingOccurrences(of: "Billing Item ID", with: "Item"),
                       self.header + ",Model", "Billing Item ID,Event Time,Usage"] {
            XCTAssertThrowsError(try self.parser.parse(header, now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .invalidHeader)
            }
        }
        XCTAssertThrowsError(try self.parser.parse(self.csv([self.row() + ",extra"]), now: self.now)) { error in
            XCTAssertEqual(error as? CursorBillingCSVError, .invalidRow(2))
        }
    }

    func testAllowsReorderedHeadersBOMCRLFAndQuotedCommas() throws {
        let columns = self.header.components(separatedBy: ",")
        let values = self.values(model: "grok, model")
        let reversedHeader = columns.reversed().joined(separator: ",")
        let reversedRow = values.reversed().map(self.quoted).joined(separator: ",")
        let records = try self.parser.parse("\u{FEFF}" + reversedHeader + "\r\n" + reversedRow + "\r\n", now: self.now)
        XCTAssertEqual(records.first?.modelID, "grok, model")
        XCTAssertEqual(records.first?.totalTokens, 12)
    }

    func testRejectsMalformedCSVQuotes() {
        for malformed in ["unterminated,\"value", "unquoted\"quote,value", "\"closed\"trailing,value"] {
            XCTAssertThrowsError(try self.parser.parse(self.csv([malformed]), now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .malformedCSV)
            }
        }
    }

    func testPreservesFractionalISOTimeAndExcludesFutureEvents() throws {
        let records = try self.parser.parse(self.csv([
            self.row(id: "old", time: "2026-10-20T10:00:00.123Z"),
            self.row(id: "same-zone", time: "2026-10-20T21:00:00.123+11:00"),
            self.row(id: "future", time: "2027-01-01T00:00:00Z"),
        ]), now: self.now)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].timestamp, records[1].timestamp)
        XCTAssertEqual(records[0].timestamp.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.123, accuracy: 0.000_001)
        for invalid in ["not-a-date", "2026-10-20", "2026-10-20T10:00:00Zsuffix"] {
            XCTAssertThrowsError(try self.parser.parse(self.csv([self.row(time: invalid)]), now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .invalidRow(2))
            }
        }
    }

    func testRejectsMalformedUsageAndUnknownTokenBuckets() {
        for usage in ["not-json", "[]", "null", #"{"prompt-text-tokens":null}"#,
                      #"{"prompt-text-tokens":true}"#, #"{"prompt-text-tokens":{}}"#,
                      #"{"new-kind-tokens":"100"}"#] {
            XCTAssertThrowsError(try self.parser.parse(self.csv([self.row(usage: usage)]), now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .invalidRow(2), usage)
            }
        }
    }

    func testRejectsNegativeFractionalAndOverflowingTokenCounters() {
        for counter in ["\"-1\"", "-1", "1.5", "\"1.5\"", "\"+1\"", "\" 1\"", "\"\"",
                        "\"9223372036854775808\"", "9223372036854775808"] {
            let usage = "{\"prompt-text-tokens\":\(counter)}"
            XCTAssertThrowsError(try self.parser.parse(self.csv([self.row(usage: usage)]), now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .invalidRow(2), counter)
            }
        }
        let overflow = "{\"prompt-text-tokens\":\"\(Int.max)\",\"completion-text-tokens\":\"1\"}"
        XCTAssertThrowsError(try self.parser.parse(self.csv([self.row(usage: overflow)]), now: self.now)) { error in
            XCTAssertEqual(error as? CursorBillingCSVError, .invalidRow(2))
        }
    }

    func testPreservesIntegerPrecisionAboveDoubleRange() throws {
        let exact = 9_007_199_254_740_993
        for counter in ["\"\(exact)\"", "\(exact)"] {
            let usage = "{\"prompt-text-tokens\":\(counter)}"
            let records = try self.parser.parse(self.csv([self.row(usage: usage)]), now: self.now)
            XCTAssertEqual(records.first?.inputTokens, exact)
            XCTAssertEqual(records.first?.totalTokens, exact)
        }
    }

    func testStableBillingIDRemovesExactDuplicatesAndRejectsConflicts() throws {
        let original = self.row(id: "stable")
        let duplicate = try self.parser.parse(self.csv([original, original]), now: self.now)
        XCTAssertEqual(duplicate.count, 1)
        for changed in [self.row(id: "stable", usage: #"{"prompt-text-tokens":"999"}"#),
                        self.row(id: "stable", model: "another-model")] {
            XCTAssertThrowsError(try self.parser.parse(self.csv([original, changed]), now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .duplicateConflict(3))
            }
        }
        XCTAssertEqual(try self.parser.parse(self.csv([original, self.row(id: "different")]), now: self.now).count, 2)
    }

    func testBilledPriceDoesNotReplaceUsageValueOrAssumeNonUSDCurrency() throws {
        let rows = [self.row(id: "included", price: "0"), self.row(id: "paid", price: "0.123456"),
                    self.row(id: "non-usd", currency: "EUR", price: "5"), self.row(id: "unknown", price: "")]
        let records = try self.parser.parse(self.csv(rows), now: self.now)
        XCTAssertEqual(records.map(\.billedCostUSD), [0, 0.123456, nil, nil])
        XCTAssertTrue(records.allSatisfy { $0.costUSD == nil && $0.costEvidence == nil })
        for invalid in ["-1", "NaN", "Infinity", "$1.25", String(repeating: "9", count: 400)] {
            XCTAssertThrowsError(try self.parser.parse(self.csv([self.row(price: invalid)]), now: self.now)) { error in
                XCTAssertEqual(error as? CursorBillingCSVError, .invalidRow(2))
            }
        }
    }

    private func csv(_ rows: [String]) -> String { ([self.header] + rows).joined(separator: "\n") }

    private func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private func values(id: String = "fixture", time: String = "2026-10-20T10:00:00.123Z", product: String = "grok-bot",
                        usage: String = #"{"prompt-text-tokens":"10","completion-text-tokens":"2"}"#,
                        model: String = "grok-model", currency: String = "USD", price: String = "0") -> [String] {
        [id, time, product, "included", "model", "user", "private-principal", usage, currency, price, model, "private@example.test"]
    }

    private func row(id: String = "fixture", time: String = "2026-10-20T10:00:00.123Z", product: String = "grok-bot",
                     usage: String = #"{"prompt-text-tokens":"10","completion-text-tokens":"2"}"#,
                     model: String = "grok-model", currency: String = "USD", price: String = "0") -> String {
        self.values(id: id, time: time, product: product, usage: usage, model: model, currency: currency, price: price)
            .map(self.quoted).joined(separator: ",")
    }
}
