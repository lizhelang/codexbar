import XCTest

final class ISO8601ParsingTests: XCTestCase {
    func testCanonicalUTCShapesMatchFoundation() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for value in ["2026-09-02T00:47:48.123Z"] {
            let expected = try XCTUnwrap(formatter.date(from: value))
            XCTAssertEqual(
                try XCTUnwrap(ISO8601Parsing.parse(value)).timeIntervalSince1970,
                expected.timeIntervalSince1970,
                accuracy: 1e-6
            )
        }

        let leapDayBase = try XCTUnwrap(ISO8601Parsing.parse("2024-02-29T23:59:59Z"))
        let leapDayFractional = try XCTUnwrap(ISO8601Parsing.parse("2024-02-29T23:59:59.123456789Z"))
        XCTAssertEqual(
            leapDayFractional.timeIntervalSince1970 - leapDayBase.timeIntervalSince1970,
            0.123456789,
            accuracy: 1e-6
        )

        let basic = "2026-09-02T00:47:48Z"
        let basicFormatter = ISO8601DateFormatter()
        basicFormatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(
            try XCTUnwrap(ISO8601Parsing.parse(basic)).timeIntervalSince1970,
            try XCTUnwrap(basicFormatter.date(from: basic)).timeIntervalSince1970,
            accuracy: 1e-9
        )
    }

    func testOffsetTimestampStillUsesCompatibilityFallback() throws {
        let offset = "2026-09-02T10:47:48+10:00"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(
            try XCTUnwrap(ISO8601Parsing.parse(offset)).timeIntervalSince1970,
            try XCTUnwrap(formatter.date(from: offset)).timeIntervalSince1970,
            accuracy: 1e-9
        )
    }

    func testInvalidCalendarDateIsRejected() {
        XCTAssertNil(ISO8601Parsing.parse("not-a-date"))
    }
}
