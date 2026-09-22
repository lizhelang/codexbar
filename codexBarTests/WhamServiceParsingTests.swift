import Foundation
import XCTest

final class WhamServiceParsingTests: XCTestCase {
    func testPlusAccountKeepsFiveHourPrimaryAndSevenDaySecondary() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 0.0,
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_775_372_003.0,
                ],
                "secondary_window": [
                    "used_percent": 100.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_690_771.0,
                ],
            ],
        ])

        XCTAssertEqual(result.primaryLimitWindowSeconds, 18_000)
        XCTAssertEqual(result.secondaryLimitWindowSeconds, 604_800)
        XCTAssertEqual(result.primaryUsedPercent, 0)
        XCTAssertEqual(result.secondaryUsedPercent, 100)
    }

    func testFreeAccountTreatsPrimaryAsWeeklyWhenApiSaysSevenDays() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "free",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 100.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_860_349.0,
                ],
                "secondary_window": NSNull(),
            ],
        ])

        XCTAssertEqual(result.primaryLimitWindowSeconds, 604_800)
        XCTAssertNil(result.secondaryLimitWindowSeconds)
        XCTAssertEqual(result.primaryUsedPercent, 100)
        XCTAssertEqual(result.secondaryUsedPercent, 0)
    }

    func testSecondaryWindowDurationIsPreservedEvenWhenUsageIsZero() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 0.0,
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_775_372_003.0,
                ],
                "secondary_window": [
                    "used_percent": 0.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_690_771.0,
                ],
            ],
        ])

        XCTAssertEqual(result.secondaryLimitWindowSeconds, 604_800)
        XCTAssertEqual(result.secondaryUsedPercent, 0)
        XCTAssertNotNil(result.secondaryResetAt)
    }

    func testDuplicateWeeklyWindowsAreCollapsedWhenParsingUsage() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 42.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_372_003.0,
                ],
                "secondary_window": [
                    "used_percent": 87.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_690_771.0,
                ],
            ],
        ])

        XCTAssertEqual(result.primaryLimitWindowSeconds, 604_800)
        XCTAssertNil(result.secondaryLimitWindowSeconds)
        XCTAssertEqual(result.primaryUsedPercent, 87)
        XCTAssertEqual(result.secondaryUsedPercent, 0)
        XCTAssertEqual(result.primaryResetAt, Date(timeIntervalSince1970: 1_775_690_771.0))
        XCTAssertNil(result.secondaryResetAt)
    }

    func testParsesLunaReserveFromAdditionalRateLimits() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 100.0,
                    "limit_window_seconds": 18_000,
                ],
            ],
            "additional_rate_limits": [[
                "limit_name": "gpt-reserve",
                "normal_model_slug": "gpt-5.6-luna",
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 3.0,
                        "limit_window_seconds": 604_800,
                        "reset_at": 1_790_646_284.0,
                    ],
                ],
            ]],
        ])

        XCTAssertEqual(result.lunaReserveUsedPercent, 3)
        XCTAssertEqual(result.lunaReserveLimitWindowSeconds, 604_800)
        XCTAssertEqual(result.lunaReserveResetAt, Date(timeIntervalSince1970: 1_790_646_284.0))
    }
}
