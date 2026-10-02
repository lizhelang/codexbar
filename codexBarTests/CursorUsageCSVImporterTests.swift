import Foundation
import XCTest
@testable import codexbar

final class CursorUsageCSVImporterTests: XCTestCase {
    func testParsesUsageExportAndMarksIncludedCostUnknown() throws {
        let csv = """
        Date,Kind,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        2026-09-30T01:00:00Z,Usage-based,model-a,40,30,10,20,100,$0.02
        2026-09-30T02:00:00Z,Included,model-a,100,100,50,50,300,Included
        """
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = try CursorUsageCSVImporter().parse(csv, calendar: calendar)
        XCTAssertEqual(snapshot.client, .cursor)
        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.evidence, .imported)
        XCTAssertEqual(snapshot.dailyEntries.count, 1)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 400)
        XCTAssertEqual(snapshot.dailyEntries[0].cacheWriteTokens, 140)
        XCTAssertNil(snapshot.dailyEntries[0].costUSD)
        XCTAssertEqual(snapshot.usageRecords.map(\.modelID), ["model-a", "model-a"])
        XCTAssertTrue(snapshot.usageRecords.allSatisfy { $0.sessionID == nil })
        XCTAssertEqual(snapshot.usageRecords.map(\.totalTokens), [100, 300])
    }

    func testRejectsMissingTokenColumns() {
        XCTAssertThrowsError(try CursorUsageCSVImporter().parse("Date,Model\n2026-09-30,model-a")) { error in
            XCTAssertEqual(error as? CursorUsageCSVImportError, .missingTokens)
        }
    }

    func testQuotedFieldsWithCommasDoNotShiftColumns() throws {
        let csv = "Date,Model,Total Tokens,Cost\n2026-09-30,\"model, variant\",\"1,234\",$1.25"
        let snapshot = try CursorUsageCSVImporter().parse(csv)
        XCTAssertEqual(snapshot.dailyEntries.first?.totalTokens, 1_234)
        XCTAssertEqual(snapshot.dailyEntries.first?.costUSD, 1.25)
    }

    func testSumsDisjointInputColumnsWithoutTotalColumn() throws {
        let csv = "Date,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\n2026-09-30,40,30,10,20,$0.02"
        let snapshot = try CursorUsageCSVImporter().parse(csv)
        XCTAssertEqual(snapshot.dailyEntries.first?.totalTokens, 100)
        XCTAssertEqual(snapshot.dailyEntries.first?.inputTokens, 30)
        XCTAssertEqual(snapshot.dailyEntries.first?.cacheWriteTokens, 40)
    }

    func testRejectsInvalidDatedRowInsteadOfSilentlyUndercounting() {
        let csv = "Date,Total Tokens\n2026-09-30,100\nnot-a-date,200"
        XCTAssertThrowsError(try CursorUsageCSVImporter().parse(csv)) { error in
            XCTAssertEqual(error as? CursorUsageCSVImportError, .invalidUsageRow(3))
        }
    }

    func testSkipsValidZeroTokenRows() throws {
        let csv = "Date,Kind,Total Tokens,Cost\n2026-09-30,Included,,Free\n2026-09-30,Included,10,Included"
        let snapshot = try CursorUsageCSVImporter().parse(csv)
        XCTAssertEqual(snapshot.dailyEntries.first?.totalTokens, 10)
        XCTAssertTrue(snapshot.statusDetail?.contains("skipped 1 zero-token") == true)
    }

    func testRejectsDailyTokenOverflow() {
        let csv = "Date,Total Tokens\n2026-09-30,\(Int.max)\n2026-09-30,1"
        XCTAssertThrowsError(try CursorUsageCSVImporter().parse(csv)) { error in
            XCTAssertEqual(error as? CursorUsageCSVImportError, .invalidUsageRow(3))
        }
    }
}
