import Foundation
import XCTest

final class TokenAccountProfileTests: CodexBarTestCase {
    func testDisplayIdentifierPrefersUsernameThenDisplayNameThenEmailThenAccountID() {
        XCTAssertEqual(
            TokenAccount(
                email: "email@example.com",
                accountId: "acct",
                username: "  myorg-dev  ",
                displayName: "My Org Dev"
            ).displayIdentifier,
            "myorg-dev"
        )
        XCTAssertEqual(
            TokenAccount(
                email: "email@example.com",
                accountId: "acct",
                displayName: "  My Org Dev  "
            ).displayIdentifier,
            "My Org Dev"
        )
        XCTAssertEqual(
            TokenAccount(email: "  email@example.com  ", accountId: "acct").displayIdentifier,
            "email@example.com"
        )
        XCTAssertEqual(TokenAccount(accountId: "acct").displayIdentifier, "acct")
    }

    func testLegacyTokenAccountJSONDecodesWithoutProfileFields() throws {
        let json = """
        {
            "email": "legacy@example.com",
            "account_id": "acct_legacy",
            "access_token": "access",
            "refresh_token": "refresh",
            "id_token": "id"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let account = try decoder.decode(TokenAccount.self, from: Data(json.utf8))

        XCTAssertNil(account.username)
        XCTAssertNil(account.displayName)
        XCTAssertNil(account.profileLastCheckedAt)
        XCTAssertEqual(account.displayIdentifier, "legacy@example.com")
    }

    func testAccountBuilderInitializesDisplayNameFromIDTokenName() throws {
        let accessToken = try self.makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_named",
                "chatgpt_user_id": "user-named",
                "chatgpt_plan_type": "plus",
            ],
        ])
        let idToken = try self.makeJWT(payload: [
            "email": "named@example.com",
            "name": "  Named User  ",
        ])

        let account = AccountBuilder.build(
            from: OAuthTokens(
                accessToken: accessToken,
                refreshToken: "refresh",
                idToken: idToken
            )
        )

        XCTAssertEqual(account.displayName, "Named User")
        XCTAssertEqual(account.displayIdentifier, "Named User")
    }
}
