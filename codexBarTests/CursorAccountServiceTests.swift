import Foundation
import XCTest
@testable import codexbar

final class CursorAccountServiceTests: XCTestCase {
    private let cookie = "user_fixture%3A%3Aaa.bb.cc"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testNormalizesUpstreamCookieAndJWTFormatsWithoutHeaderInjection() throws {
        let payload = Data(#"{"sub":"auth0|user_fixture"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let jwt = "a.\(payload).b"
        for raw in [jwt, "'\(jwt)'", "user_fixture::\(jwt)", "\"user_fixture%3A%3A\(jwt)\"",
                    "Cookie: other=value; WorkosCursorSessionToken=user_fixture%3A%3A\(jwt); theme=dark"] {
            XCTAssertEqual(try CursorAccountService.normalize(raw), "user_fixture%3A%3A\(jwt)")
        }
        for raw in ["", "user_fixture%3A%3Aaa.bb.cc\r\nX-Leak: yes", "user_fixture%3A%3Aaa.bb.cc;other=leak", String(repeating: "a", count: 17_000)] {
            XCTAssertThrowsError(try CursorAccountService.normalize(raw)) { error in
                XCTAssertEqual(error as? CursorAccountError, .invalidCredential)
            }
        }
    }

    func testProbeVerifiesAuthIdentityAndPreservesIndependentQuotaPools() async throws {
        let transport = CursorAccountTransportFixture(routes: [
            "/api/auth/me": .json(["sub": "auth0|user_fixture", "email": "fixture@example.test", "name": "Fixture"]),
            "/api/usage-summary": .json(["membershipType": "pro", "individualUsage": ["plan": ["autoPercentUsed": 44, "apiPercentUsed": 71]],
                "billingCycleEnd": "2026-10-11T10:00:00Z"]),
            "/api/usage": .json([:]),
            "/api/dashboard/get-sand-usage-status": .json(["usagePercent": 12, "hasNonZeroIncludedLimit": true,
                "nextResetTimestampUtc": "2026-10-12T10:00:00Z"])
        ])
        let result = try await CursorAccountService(transport: transport).probe(sessionCookie: self.cookie, now: self.now)
        XCTAssertEqual(result.identity.userID, "user_fixture")
        XCTAssertEqual(result.identity.email, "fixture@example.test")
        XCTAssertEqual(result.identity.planType, "pro")
        XCTAssertEqual(result.quota.windows.map(\.id), ["autoPercentUsed", "apiPercentUsed", "grokBot"])
        XCTAssertEqual(result.quota.windows.map(\.usedPercent), [44, 71, 12])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "cursor.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=\(self.cookie)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://cursor.com/dashboard")
        }
        XCTAssertEqual(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "auth0|user_fixture")
        XCTAssertEqual(requests[3].httpMethod, "POST")
        XCTAssertEqual(requests[3].timeoutInterval, 5)
        XCTAssertEqual(requests[3].httpBody, Data("{}".utf8))
    }

    func testLegacyRequestAllowanceTakesPrecedenceOverNewModelPools() async throws {
        let transport = CursorAccountTransportFixture(routes: [
            "/api/auth/me": .json(["sub": "user_fixture"]),
            "/api/usage-summary": .json(["individualUsage": ["plan": ["autoPercentUsed": 44, "apiPercentUsed": 71], "onDemand": ["used": 400]]]),
            "/api/usage": .json(["gpt-4": ["numRequestsTotal": 25, "maxRequestUsage": 500]]),
        ])
        let result = try await CursorAccountService(transport: transport).probe(sessionCookie: self.cookie, now: self.now)
        XCTAssertEqual(result.quota.windows.map(\.id), ["requests", "onDemand"])
        XCTAssertEqual(result.quota.windows.first?.usedPercent, 5)
        XCTAssertEqual(result.quota.windows.first?.used, 25)
        XCTAssertEqual(result.quota.windows.first?.limit, 500)
    }

    func testIdentityMismatchStopsBeforeQuotaAndOptionalQueries() async throws {
        let transport = CursorAccountTransportFixture(routes: ["/api/auth/me": .json(["sub": "user_someoneElse", "email": "same@example.test"])])
        do {
            _ = try await CursorAccountService(transport: transport).probe(sessionCookie: self.cookie, now: self.now)
            XCTFail("Cookie user ID cannot be verified using another account or the same email")
        } catch { XCTAssertEqual(error as? CursorAccountError, .identityMismatch) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testValidationRejectsEmptySuccessfulSummaryAndAuthFailuresWithoutEchoingSecretBodies() async throws {
        for (path, response, expected) in [
            ("/api/auth/me", CursorAccountTransportFixture.Response(status: 401, body: Data(self.cookie.utf8)), CursorAccountError.authenticationRequired),
            ("/api/usage-summary", .json([:]), .invalidResponse),
        ] {
            var routes: [String: CursorAccountTransportFixture.Response] = ["/api/auth/me": .json(["sub": "user_fixture"])]
            routes[path] = response
            let transport = CursorAccountTransportFixture(routes: routes)
            do {
                _ = try await CursorAccountService(transport: transport).probe(sessionCookie: self.cookie, now: self.now)
                XCTFail("Invalid validation result must fail")
            } catch {
                XCTAssertEqual(error as? CursorAccountError, expected)
                XCTAssertFalse(error.localizedDescription.contains(self.cookie))
            }
        }
    }

    func testOptionalLegacyAndGrokFailuresDoNotDiscardValidatedQuota() async throws {
        let transport = CursorAccountTransportFixture(routes: [
            "/api/auth/me": .json(["sub": "user_fixture"]),
            "/api/usage-summary": .json(["membershipType": "pro", "individualUsage": ["plan": ["used": 1_000, "limit": 2_000]]]),
            "/api/usage": .init(status: 500, body: Data(self.cookie.utf8)),
            "/api/dashboard/get-sand-usage-status": .init(status: 401, body: Data(self.cookie.utf8)),
        ])
        let result = try await CursorAccountService(transport: transport).probe(sessionCookie: self.cookie, now: self.now)
        XCTAssertEqual(result.quota.status, .ready)
        XCTAssertEqual(result.quota.windows.first?.used, 10)
        XCTAssertEqual(result.quota.windows.first?.limit, 20)
        XCTAssertEqual(result.quota.windows.first?.usedPercent, 50)
    }

    func testRefusesUnexpectedResponseHostPortAndOversizedTransportPayload() async throws {
        for response in [
            CursorAccountTransportFixture.Response(status: 200, body: Data("{}".utf8), url: URL(string: "https://elsewhere.test/api/auth/me")),
            .init(status: 200, body: Data("{}".utf8), url: URL(string: "https://cursor.com:444/api/auth/me")),
            .init(status: 200, body: Data(repeating: 0x20, count: 4 * 1024 * 1024 + 1)),
        ] {
            let transport = CursorAccountTransportFixture(routes: ["/api/auth/me": response])
            do {
                _ = try await CursorAccountService(transport: transport).probe(sessionCookie: self.cookie, now: self.now)
                XCTFail("Response outside the bounded official request must fail")
            } catch {
                XCTAssertTrue(error as? CursorAccountError == .invalidResponse || error as? CursorAccountError == .responseTooLarge)
            }
        }
    }

    func testExplicitUsageSessionNeverReadsDesktopOrPersistsEchoedCookieMetadata() async throws {
        let transport = CursorAccountTransportFixture(routes: [
            "/api/dashboard/get-filtered-usage-events": .json(["totalUsageEventsCount": 1, "usageEventsDisplay": [[
                "timestamp": String(Int(self.now.timeIntervalSince1970 * 1_000) - 1_000),
                "model": self.cookie, "conversationId": self.cookie,
                "tokenUsage": ["inputTokens": 7, "outputTokens": 3, "totalCents": 2],
            ]]])
        ])
        let usage = try await CursorAccountService(transport: transport).usage(sessionCookie: self.cookie, now: self.now, calendar: .current)
        XCTAssertEqual(usage.dailyEntries.first?.totalTokens, 10)
        XCTAssertNil(usage.usageRecords.first?.modelID)
        XCTAssertNil(usage.usageRecords.first?.sessionID)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(usage), as: UTF8.self).contains(self.cookie))
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=\(self.cookie)")
    }
}

private actor CursorAccountTransportFixture: CursorUsageHTTPTransport {
    struct Response: Sendable {
        let status: Int
        let body: Data
        var url: URL? = nil
        static func json(_ object: [String: Any]) -> Self {
            Self(status: 200, body: try! JSONSerialization.data(withJSONObject: object))
        }
    }
    let routes: [String: Response]
    private(set) var requests: [URLRequest] = []
    init(routes: [String: Response]) { self.routes = routes }
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        guard let url = request.url, let response = self.routes[url.path] else { throw CursorUsageSyncError.networkFailure }
        return (response.body, HTTPURLResponse(url: response.url ?? url, statusCode: response.status, httpVersion: nil, headerFields: nil)!)
    }
}
