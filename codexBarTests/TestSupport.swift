import Foundation
import XCTest

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

class CodexBarTestCase: XCTestCase {
    private var originalHome: String?
    private var temporaryHome: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.temporaryHome = tempDir
        self.originalHome = ProcessInfo.processInfo.environment["CODEXBAR_HOME"]
        setenv("CODEXBAR_HOME", tempDir.path, 1)
        MockURLProtocol.handler = nil
    }

    override func tearDownWithError() throws {
        if let originalHome {
            setenv("CODEXBAR_HOME", originalHome, 1)
        } else {
            unsetenv("CODEXBAR_HOME")
        }

        if let temporaryHome {
            try? FileManager.default.removeItem(at: temporaryHome)
        }
        MockURLProtocol.handler = nil
        try super.tearDownWithError()
    }

    func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func makeJWT(payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        return "\(self.base64URL(header)).\(self.base64URL(data)).signature"
    }

    func makeOAuthAccount(
        accountID: String,
        email: String,
        refreshToken: String? = nil,
        isActive: Bool = false,
        planType: String = "plus",
        localAccountID: String? = nil,
        remoteAccountID: String? = nil,
        accessTokenExpiresAt: Date = Date(timeIntervalSinceNow: 3_600),
        subscriptionActiveUntil: String = "2026-12-31T00:00:00Z",
        oauthClientID: String? = nil,
        tokenLastRefreshAt: Date? = nil
    ) throws -> TokenAccount {
        let resolvedLocalAccountID = localAccountID ?? accountID
        let resolvedRemoteAccountID = remoteAccountID ?? accountID
        let resolvedUserID: String
        if let userComponent = resolvedLocalAccountID.split(separator: "__").first, userComponent.hasPrefix("user-") {
            resolvedUserID = String(userComponent)
        } else {
            resolvedUserID = "user-\(resolvedLocalAccountID)"
        }
        let accessToken = try self.makeJWT(
            payload: [
                "exp": accessTokenExpiresAt.timeIntervalSince1970,
                "client_id": oauthClientID as Any,
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": resolvedRemoteAccountID,
                    "chatgpt_account_user_id": resolvedLocalAccountID,
                    "chatgpt_user_id": resolvedUserID,
                    "user_id": resolvedUserID,
                    "chatgpt_plan_type": planType,
                ],
            ]
        )
        let idToken = try self.makeJWT(
            payload: [
                "email": email,
                "https://api.openai.com/auth": [
                    "chatgpt_subscription_active_until": subscriptionActiveUntil,
                ],
            ]
        )
        var account = TokenAccount(
            email: email,
            accountId: resolvedLocalAccountID,
            openAIAccountId: resolvedRemoteAccountID,
            accessToken: accessToken,
            refreshToken: refreshToken ?? "refresh-\(accountID)",
            idToken: idToken,
            expiresAt: accessTokenExpiresAt,
            oauthClientID: oauthClientID,
            planType: planType,
            tokenLastRefreshAt: tokenLastRefreshAt
        )
        account.isActive = isActive
        return account
    }

    func writeAuthJSON(
        accessToken: String,
        refreshToken: String,
        idToken: String,
        remoteAccountID: String,
        clientID: String? = nil,
        lastRefresh: Date? = nil
    ) throws {
        var object: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "id_token": idToken,
                "account_id": remoteAccountID,
            ],
        ]
        if let clientID, clientID.isEmpty == false {
            object["client_id"] = clientID
        }
        if let lastRefresh {
            object["last_refresh"] = self.iso8601String(lastRefresh)
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try CodexPaths.writeSecureFile(data, to: CodexPaths.authURL)
    }

    func readAuthJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: CodexPaths.authURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func writeConfig(_ config: CodexBarConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try CodexPaths.writeSecureFile(data, to: CodexPaths.barConfigURL)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
