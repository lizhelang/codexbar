import CryptoKit
import Foundation
import XCTest

final class ClaudeLoginTests: XCTestCase {
    func testClaudeAuthorizationUsesPublicClientAndPKCE() throws {
        let session = try ClaudeOAuth.makeSession(port: 53621)
        let items = URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, ClaudeOAuth.clientID)
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "http://localhost:53621/callback")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, session.state)
        XCTAssertEqual(items.first { $0.name == "code_challenge" }?.value, Self.challenge(session.codeVerifier))
        XCTAssertFalse(session.authorizationURL.absoluteString.contains("client_secret"))
    }

    func testClaudeCallbackChecksStateAndExtractsCode() throws {
        let session = self.session()
        XCTAssertEqual(
            try ClaudeOAuth.authorizationCode(callbackURL: "http://localhost:1/callback?code=abc&state=state-1", session: session),
            "abc"
        )
        XCTAssertThrowsError(try ClaudeOAuth.authorizationCode(
            callbackURL: "http://localhost:1/callback?code=abc&state=other", session: session
        ))
        XCTAssertThrowsError(try ClaudeOAuth.authorizationCode(
            callbackURL: "http://localhost:1/callback?error=access_denied&state=state-1", session: session
        ))
    }

    func testClaudeTokenRequestDoesNotSendAClientSecret() throws {
        let request = try ClaudeOAuth.tokenRequest(code: "abc", session: self.session())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "platform.claude.com")
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(object?["grant_type"], "authorization_code")
        XCTAssertEqual(object?["code"], "abc")
        XCTAssertEqual(object?["client_id"], ClaudeOAuth.clientID)
        XCTAssertEqual(object?["redirect_uri"], "http://localhost:1/callback")
        XCTAssertEqual(object?["state"], "state-1")
        XCTAssertNil(object?["client_secret"])
    }

    func testManualCodeUsesItsOwnRedirectAndStillRequiresTheCurrentState() throws {
        let session = self.session()
        let response = try ClaudeOAuth.authorizationResponse("code-1#state-1", session: session)
        XCTAssertEqual(response.code, "code-1")
        XCTAssertTrue(response.manual)
        let request = try ClaudeOAuth.tokenRequest(code: response.code, session: session, manual: response.manual)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body?["redirect_uri"], ClaudeOAuth.manualRedirectURI)
        let manualURL = try XCTUnwrap(ClaudeOAuth.manualAuthorizationURL(session: try ClaudeOAuth.makeSession(port: 53621)))
        XCTAssertEqual(URLComponents(url: manualURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value,
                       ClaudeOAuth.manualRedirectURI)
        XCTAssertThrowsError(try ClaudeOAuth.authorizationResponse("code-1#old-state", session: session))
        XCTAssertThrowsError(try ClaudeOAuth.authorizationResponse("code-without-state", session: session))
        let local = try ClaudeOAuth.authorizationResponse("http://localhost:1/callback?code=abc&state=state-1", session: session)
        XCTAssertFalse(local.manual)
    }

    func testCallbackRejectsOtherOriginsPortsPathsAndDuplicatedParameters() {
        for url in [
            "https://elsewhere.test/callback?code=abc&state=state-1",
            "http://localhost:2/callback?code=abc&state=state-1",
            "http://localhost:1/callback/extra?code=abc&state=state-1",
            "http://localhost:1/callback?code=abc&state=state-1&state=state-1",
            "http://localhost:1/callback?code=abc&code=def&state=state-1",
            "http://localhost:1/callback?code=abc&state=state-1#untrusted",
        ] {
            XCTAssertThrowsError(try ClaudeOAuth.authorizationCode(callbackURL: url, session: self.session()))
        }
    }

    func testTokenResponsePreservesRefreshExpiryAndScopesAndRefreshRotation() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let data = Data(#"{"access_token":"access-one","refresh_token":"refresh-one","expires_in":3600,"scope":"user:profile user:inference"}"#.utf8)
        let credential = try ClaudeOAuth.credential(from: data, now: now)
        XCTAssertEqual(credential.oauthToken, "access-one")
        XCTAssertEqual(credential.oauthRefreshToken, "refresh-one")
        XCTAssertEqual(credential.oauthExpiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(credential.oauthScopes, ["user:profile", "user:inference"])
        let rotated = try ClaudeOAuth.credential(from: Data(#"{"access_token":"access-two","expires_in":7200}"#.utf8),
            now: now, previous: credential)
        XCTAssertEqual(rotated.oauthRefreshToken, "refresh-one")
        XCTAssertEqual(rotated.oauthExpiresAt, now.addingTimeInterval(7200))
        let request = try ClaudeOAuth.refreshRequest(refreshToken: "refresh-one", scopes: credential.oauthScopes)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body?["grant_type"], "refresh_token")
        XCTAssertEqual(body?["scope"], "user:profile user:inference")
        XCTAssertNil(body?["client_secret"])
    }

    func testClaudeAccessTokenParserReturnsOnlyTheAccessToken() throws {
        let data = Data(#"{"access_token":"test-access-token","refresh_token":"not-used"}"#.utf8)
        XCTAssertEqual(try ClaudeOAuth.accessToken(from: data), "test-access-token")
        XCTAssertThrowsError(try ClaudeOAuth.accessToken(from: Data(#"{}"#.utf8)))
    }

    private func session() -> ClaudeOAuthSession {
        ClaudeOAuthSession(
            state: "state-1",
            codeVerifier: "verifier-verifier-verifier-verifier-verifier",
            redirectURI: "http://localhost:1/callback",
            authorizationURL: URL(string: "https://claude.ai/oauth/authorize")!
        )
    }

    private static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
