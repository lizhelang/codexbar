import Foundation
import XCTest

final class OpenAIOAuthFlowServiceTests: CodexBarTestCase {
    func testStartFlowPersistsRecoverableFlow() throws {
        let service = OpenAIOAuthFlowService(session: self.makeMockSession())

        let started = try service.startFlow()
        XCTAssertFalse(started.flowID.isEmpty)
        XCTAssertTrue(started.authURL.contains("code_challenge="))

        let flowURL = CodexPaths.oauthFlowsDirectoryURL.appendingPathComponent("\(started.flowID).json")
        let data = try Data(contentsOf: flowURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let flow = try decoder.decode(PendingOAuthFlow.self, from: data)

        XCTAssertEqual(flow.flowID, started.flowID)
        XCTAssertFalse(flow.codeVerifier.isEmpty)
        XCTAssertFalse(flow.expectedState.isEmpty)
    }

    func testCompleteFlowAcceptsCallbackURLAndCleansFlow() async throws {
        let accessToken = try self.makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_openai_alice",
                "chatgpt_plan_type": "pro",
            ],
        ])
        let idToken = try self.makeJWT(payload: [
            "email": "alice@example.com",
        ])

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": accessToken,
                "refresh_token": "refresh-token",
                "id_token": idToken,
            ], options: [.sortedKeys])
            return (response, data)
        }

        let service = OpenAIOAuthFlowService(session: self.makeMockSession())
        let started = try service.startFlow()
        let state = URLComponents(string: started.authURL)?
            .queryItems?
            .first(where: { $0.name == "state" })?
            .value

        let result = try await service.completeFlow(
            flowID: started.flowID,
            callbackURL: "http://localhost:1455/auth/callback?code=oauth-code&state=\(state ?? "")",
            activate: true
        )

        XCTAssertEqual(result.account.accountId, "acct_openai_alice")
        XCTAssertEqual(result.account.email, "alice@example.com")
        XCTAssertTrue(result.active)
        XCTAssertTrue(result.synchronized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.oauthFlowsDirectoryURL.appendingPathComponent("\(started.flowID).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.configTomlURL.path))
    }

    func testCompleteFlowAcceptsBareCodeWhenStateDiffers() async throws {
        let accessToken = try self.makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_state_mismatch",
                "chatgpt_plan_type": "plus",
            ],
        ])
        let idToken = try self.makeJWT(payload: [
            "email": "mismatch@example.com",
        ])

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": accessToken,
                "refresh_token": "refresh-token",
                "id_token": idToken,
            ], options: [.sortedKeys])
            return (response, data)
        }

        let service = OpenAIOAuthFlowService(session: self.makeMockSession())
        let started = try service.startFlow()

        let result = try await service.completeFlow(
            flowID: started.flowID,
            code: "oauth-code",
            returnedState: "different-state",
            activate: false
        )

        XCTAssertEqual(result.account.accountId, "acct_state_mismatch")
        XCTAssertEqual(result.account.email, "mismatch@example.com")
        XCTAssertFalse(result.active)
    }

    func testCompleteFlowUsesUserScopedAccountIDWhenPresent() async throws {
        let accessToken = try self.makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_team_shared",
                "chatgpt_account_user_id": "user-second__acct_team_shared",
                "chatgpt_user_id": "user-second",
                "user_id": "user-second",
                "chatgpt_plan_type": "team",
            ],
        ])
        let idToken = try self.makeJWT(payload: [
            "email": "second-team@example.com",
        ])

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": accessToken,
                "refresh_token": "refresh-token",
                "id_token": idToken,
            ], options: [.sortedKeys])
            return (response, data)
        }

        let service = OpenAIOAuthFlowService(session: self.makeMockSession())
        let started = try service.startFlow()

        let result = try await service.completeFlow(
            flowID: started.flowID,
            code: "oauth-code",
            returnedState: "different-state",
            activate: false
        )

        XCTAssertEqual(result.account.accountId, "user-second__acct_team_shared")
        XCTAssertEqual(result.account.remoteAccountId, "acct_team_shared")
        XCTAssertEqual(result.account.email, "second-team@example.com")
        XCTAssertFalse(result.active)
    }

    func testRefreshAccountPreservesExistingRefreshTokenWhenResponseOmitsIt() async throws {
        let refreshedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let refreshedAccessToken = try self.makeJWT(payload: [
            "exp": Date(timeIntervalSince1970: 1_780_003_600).timeIntervalSince1970,
            "client_id": "app_refresh_client",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_refresh",
                "chatgpt_account_user_id": "acct_refresh",
                "chatgpt_plan_type": "plus",
            ],
        ])
        let refreshedIDToken = try self.makeJWT(payload: [
            "email": "refresh@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_subscription_active_until": "2027-01-01T00:00:00Z",
            ],
        ])
        let account = try self.makeOAuthAccount(
            accountID: "acct_refresh",
            email: "refresh@example.com",
            refreshToken: "refresh-old",
            oauthClientID: "app_refresh_client",
            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_779_999_000)
        )

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": refreshedAccessToken,
                "id_token": refreshedIDToken,
            ], options: [.sortedKeys])
            return (response, data)
        }

        let service = OpenAIOAuthFlowService(
            session: self.makeMockSession(),
            now: { refreshedAt }
        )

        let refreshed = try await service.refreshAccount(account)

        XCTAssertEqual(refreshed.accessToken, refreshedAccessToken)
        XCTAssertEqual(refreshed.refreshToken, "refresh-old")
        XCTAssertEqual(refreshed.idToken, refreshedIDToken)
        XCTAssertEqual(refreshed.oauthClientID, "app_refresh_client")
        XCTAssertEqual(refreshed.tokenLastRefreshAt, refreshedAt)
        XCTAssertEqual(refreshed.accountId, account.accountId)
    }

    func testRefreshAccountTreatsInvalidGrantAsTerminalFailure() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "acct_invalid_grant",
            email: "invalid-grant@example.com",
            refreshToken: "refresh-invalid",
            oauthClientID: "app_invalid_grant"
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "error": "invalid_grant",
                "error_description": "refresh token revoked",
            ], options: [.sortedKeys])
            return (response, data)
        }

        let service = OpenAIOAuthFlowService(session: self.makeMockSession())

        do {
            _ = try await service.refreshAccount(account)
            XCTFail("Expected refresh to fail")
        } catch let error as OpenAIOAuthError {
            XCTAssertTrue(error.isTerminalAuthFailure)
            XCTAssertTrue(error.localizedDescription.contains("invalid_grant"))
        }
    }
}
