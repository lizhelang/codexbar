import Foundation
import XCTest

final class OpenAIProfileServiceTests: CodexBarTestCase {
    func testFetchProfileSendsExpectedRequestAndTrimsResponse() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "user-profile__acct_profile",
            email: "profile@example.com",
            remoteAccountID: "acct_profile",
            userID: "user-profile",
            includeAccountUserID: true
        )

        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://chatgpt.com/backend-api/calpico/chatgpt/profile/user-profile"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(account.accessToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct_profile")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "oai-language"), "zh-CN")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://chatgpt.com/")
            XCTAssertFalse(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") ?? false)

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "username": "  myorg-dev  ",
                "display_name": "  My Org Dev  ",
            ], options: [.sortedKeys])
            return (response, data)
        }

        let service = OpenAIProfileService(urlSession: self.makeMockSession())
        let profile = await service.fetchProfile(account: account)

        XCTAssertEqual(profile?.username, "myorg-dev")
        XCTAssertEqual(profile?.displayName, "My Org Dev")
    }

    func testFetchProfileReturnsSnapshotForDecodableEmptyProfile() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "user-empty__acct_profile",
            email: "empty@example.com",
            remoteAccountID: "acct_profile",
            userID: "user-empty",
            includeAccountUserID: true
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"username":" ","display_name":null}"#.utf8))
        }

        let service = OpenAIProfileService(urlSession: self.makeMockSession())
        let profile = await service.fetchProfile(account: account)

        XCTAssertNotNil(profile)
        XCTAssertNil(profile?.username)
        XCTAssertNil(profile?.displayName)
    }

    func testFetchProfileRejectsSuccessfulPayloadWithoutProfileFields() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "user-unrecognized__acct_profile",
            email: "unrecognized@example.com",
            remoteAccountID: "acct_profile",
            userID: "user-unrecognized",
            includeAccountUserID: true
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"ok"}"#.utf8))
        }

        let service = OpenAIProfileService(urlSession: self.makeMockSession())
        let profile = await service.fetchProfile(account: account)

        XCTAssertNil(profile)
    }

    func testFetchProfileReturnsNilWithoutUserIDOrOnHTTPFailure() async throws {
        let accountWithoutUserID = try self.makeOAuthAccount(
            accountID: "acct-no-user",
            email: "no-user@example.com",
            includeAccountUserID: true
        )
        var account = accountWithoutUserID
        account.accessToken = try self.makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-no-user",
            ],
        ])

        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let service = OpenAIProfileService(urlSession: self.makeMockSession())
        let missingUserProfile = await service.fetchProfile(account: account)
        XCTAssertNil(missingUserProfile)
        XCTAssertEqual(requestCount, 0)

        let accountWithUserID = try self.makeOAuthAccount(
            accountID: "user-failing__acct_profile",
            email: "failing@example.com",
            remoteAccountID: "acct_profile",
            userID: "user-failing",
            includeAccountUserID: true
        )
        let failedProfile = await service.fetchProfile(account: accountWithUserID)
        XCTAssertNil(failedProfile)
        XCTAssertEqual(requestCount, 1)
    }
}
