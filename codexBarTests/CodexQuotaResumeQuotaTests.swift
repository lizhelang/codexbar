import Foundation
import XCTest

final class CodexQuotaResumeQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_500_000)
    private let accountID = "fixture-account"

    func testFreshExplicitAllowanceWithBothWindowsPermitsContinuation() {
        XCTAssertEqual(self.decision(self.payload(primaryUsed: 0, secondaryUsed: 57)), .allowed)
    }

    func testWeeklyExhaustionStillBlocksAfterFiveHourWindowRecovers() {
        let weeklyReset = self.now.addingTimeInterval(86_400)
        XCTAssertEqual(
            self.decision(self.payload(primaryUsed: 0, secondaryUsed: 100, allowed: false)),
            .blocked(nextCheckAt: weeklyReset)
        )
    }

    func testBothExhaustedWindowsWaitForLaterResetRegardlessOfWindowOrder() {
        var payload = self.payload(primaryUsed: 100, secondaryUsed: 100, allowed: false)
        var limit = payload["rate_limit"] as! [String: Any]
        let primary = limit["primary_window"]
        limit["primary_window"] = limit["secondary_window"]
        limit["secondary_window"] = primary
        payload["rate_limit"] = limit
        XCTAssertEqual(self.decision(payload), .blocked(nextCheckAt: self.now.addingTimeInterval(86_400)))
    }

    func testPassingResetTimeDoesNotByItselfAllowContinuation() {
        var payload = self.payload(primaryUsed: 100, secondaryUsed: 0, allowed: false)
        self.setWindowField(&payload, window: "primary_window", key: "reset_at", value: self.now.addingTimeInterval(-1).timeIntervalSince1970)
        XCTAssertEqual(self.decision(payload), .blocked(nextCheckAt: self.now.addingTimeInterval(30)))
    }

    func testExplicitlyAbsentSecondaryWindowIsDifferentFromMissingField() {
        var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
        var limit = payload["rate_limit"] as! [String: Any]
        limit["secondary_window"] = NSNull()
        payload["rate_limit"] = limit
        XCTAssertEqual(self.decision(payload), .allowed)
        limit.removeValue(forKey: "secondary_window")
        payload["rate_limit"] = limit
        self.assertUnavailable(self.decision(payload))
    }

    func testMissingOrMalformedWindowValuesAreNeverTreatedAsZero() {
        for window in ["primary_window", "secondary_window"] {
            for key in ["used_percent", "reset_at", "limit_window_seconds"] {
                var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
                self.setWindowField(&payload, window: window, key: key, value: nil)
                self.assertUnavailable(self.decision(payload))
                self.setWindowField(&payload, window: window, key: key, value: "0")
                self.assertUnavailable(self.decision(payload))
                self.setWindowField(&payload, window: window, key: key, value: true)
                self.assertUnavailable(self.decision(payload))
            }
        }
        for value in [Double.nan, Double.infinity, -1] {
            var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
            self.setWindowField(&payload, window: "primary_window", key: "used_percent", value: value)
            self.assertUnavailable(self.decision(payload))
        }
        for value in [0.0, -1.0, 0.5] {
            var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
            self.setWindowField(&payload, window: "primary_window", key: "limit_window_seconds", value: value)
            self.assertUnavailable(self.decision(payload))
        }
    }

    func testMissingNumericOrContradictoryPermissionFlagsDoNotAllowContinuation() {
        for flags: [String: Any] in [
            [:],
            ["allowed": 1, "limit_reached": 0],
            ["allowed": true, "limit_reached": true],
            ["allowed": false, "limit_reached": false],
        ] {
            var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
            var limit = payload["rate_limit"] as! [String: Any]
            limit.removeValue(forKey: "allowed")
            limit.removeValue(forKey: "limit_reached")
            limit.merge(flags, uniquingKeysWith: { _, new in new })
            payload["rate_limit"] = limit
            self.assertUnavailable(self.decision(payload))
        }
        self.assertUnavailable(self.decision(self.payload(primaryUsed: 100, secondaryUsed: 0)))
        self.assertUnavailable(self.decision(self.payload(primaryUsed: 0, secondaryUsed: 0, allowed: false)))
    }

    func testSnapshotMustBeFreshAndBelongToOriginalAccount() {
        let snapshot = CodexQuotaResumeQuota.parse(self.payload(primaryUsed: 0, secondaryUsed: 0), accountID: self.accountID, fetchedAt: self.now)
        self.assertUnavailable(snapshot.decision(expectedAccountID: "another-account", model: "gpt-6.1-sol", now: self.now))
        self.assertUnavailable(snapshot.decision(expectedAccountID: self.accountID, model: "gpt-6.1-sol", now: self.now.addingTimeInterval(61)))
        self.assertUnavailable(snapshot.decision(expectedAccountID: self.accountID, model: "gpt-6.1-sol", now: self.now.addingTimeInterval(-6)))
        XCTAssertEqual(snapshot.decision(expectedAccountID: self.accountID, model: "gpt-6.1-sol", now: self.now.addingTimeInterval(60)), .allowed)
        var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
        payload["account_id"] = "another-account"
        self.assertUnavailable(self.decision(payload))
    }

    func testIndependentReserveBucketCannotBorrowOrdinaryAllowance() {
        var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
        payload["additional_rate_limits"] = [[
            "limit_name": "gpt-reserve",
            "normal_model_slug": "gpt-6-luna",
            "rate_limit": ["allowed": false, "limit_reached": true],
        ]]
        self.assertUnavailable(self.decision(payload, model: "gpt-reserve"))
        self.assertUnavailable(self.decision(payload, model: "gpt-6-luna"))
        XCTAssertEqual(self.decision(payload, model: "gpt-6.1-sol"), .allowed)
        self.assertUnavailable(self.decision(self.payload(primaryUsed: 0, secondaryUsed: 0), model: "gpt-reserve"))
    }

    func testUnknownBucketMappingAndMissingModelFailClosed() {
        self.assertUnavailable(self.decision(self.payload(primaryUsed: 0, secondaryUsed: 0), model: nil))
        for extra: Any in ["unknown", [["limit_name": "premium"]], [["limit_name": "gpt-reserve", "normal_model_slug": 123]]] {
            var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
            payload["additional_rate_limits"] = extra
            self.assertUnavailable(self.decision(payload))
        }
        var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
        payload["rate_limits_by_limit_id"] = ["codex": [:]]
        self.assertUnavailable(self.decision(payload))
    }

    func testOtherAccountOrWorkspaceRestrictionsDoNotLookLikeRecovery() {
        for fields: [String: Any] in [
            ["spend_control_reached": true],
            ["spend_control_reached": 0],
            ["rate_limit_reached_type": "workspace_owner_credits_depleted"],
            ["rate_limit_reached_type": "workspace_member_usage_limit_reached"],
        ] {
            var payload = self.payload(primaryUsed: 0, secondaryUsed: 0)
            payload.merge(fields, uniquingKeysWith: { _, new in new })
            self.assertUnavailable(self.decision(payload))
        }
    }

    private func decision(_ payload: [String: Any], model: String? = "gpt-6.1-sol") -> CodexQuotaResumeQuota.Decision {
        CodexQuotaResumeQuota.parse(payload, accountID: self.accountID, fetchedAt: self.now)
            .decision(expectedAccountID: self.accountID, model: model, now: self.now)
    }

    private func payload(primaryUsed: Double, secondaryUsed: Double, allowed: Bool = true) -> [String: Any] {
        // 与 WhamServiceParsingTests 中服务端五小时／七天窗口 fixture 保持相同字段。
        [
            "plan_type": "plus",
            "rate_limit": [
                "allowed": allowed,
                "limit_reached": !allowed,
                "primary_window": [
                    "used_percent": primaryUsed,
                    "limit_window_seconds": 18_000,
                    "reset_at": self.now.addingTimeInterval(3_600).timeIntervalSince1970,
                ],
                "secondary_window": [
                    "used_percent": secondaryUsed,
                    "limit_window_seconds": 604_800,
                    "reset_at": self.now.addingTimeInterval(86_400).timeIntervalSince1970,
                ],
            ],
        ]
    }

    private func setWindowField(_ payload: inout [String: Any], window: String, key: String, value: Any?) {
        var limit = payload["rate_limit"] as! [String: Any]
        var fields = limit[window] as! [String: Any]
        fields[key] = value
        limit[window] = fields
        payload["rate_limit"] = limit
    }

    private func assertUnavailable(_ decision: CodexQuotaResumeQuota.Decision, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable = decision else {
            return XCTFail("不完整或不可信的额度不得自动续跑：\(decision)", file: file, line: line)
        }
    }
}
