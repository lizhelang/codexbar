import Foundation
import SQLite3
import XCTest
@testable import codexbar

final class AntigravityAccountTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private let oauthClient = AntigravityOAuthClientConfiguration(clientID: "fixture-client-id", clientSecret: "fixture-client-secret")

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-antigravity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.tempDirectoryURL = base
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try super.tearDownWithError()
    }

    func testTokenFileParseAndSerializeRoundTrip() throws {
        let sampleJSON = """
        {
          "token": {
            "access_token": "ya29.test-access-token",
            "token_type": "Bearer",
            "refresh_token": "1//test-refresh-token",
            "expiry": "2026-10-19T16:02:23.756136+11:00"
          },
          "auth_method": "consumer",
          "id_token": "\(Self.makeSampleJWT(sub: "1001", email: "alice@example.com", name: "Alice"))"
        }
        """
        let parsed = try AntigravityTokenFile.parse(data: Data(sampleJSON.utf8))
        XCTAssertEqual(parsed.token.accessToken, "ya29.test-access-token")
        XCTAssertEqual(parsed.token.tokenType, "Bearer")
        XCTAssertEqual(parsed.token.refreshToken, "1//test-refresh-token")
        XCTAssertEqual(parsed.authMethod, "consumer")

        let serialized = try parsed.serializedData()
        let reparsed = try AntigravityTokenFile.parse(data: serialized)
        XCTAssertEqual(reparsed.token.accessToken, parsed.token.accessToken)
        XCTAssertEqual(reparsed.token.refreshToken, parsed.token.refreshToken)
        XCTAssertEqual(reparsed.idToken, parsed.idToken)

        let claims = AntigravityJWTClaims.decode(jwt: reparsed.idToken)
        XCTAssertEqual(claims?.subject, "1001")
        XCTAssertEqual(claims?.email, "alice@example.com")
        XCTAssertEqual(claims?.name, "Alice")
    }

    func testVscdbProtobufRoundTripAndSQLiteSync() throws {
        let expiry = Date(timeIntervalSince1970: 1_792_386_143)
        let originalToken = AntigravityOAuthToken(
            accessToken: "ya29.vscdb-access",
            tokenType: "Bearer",
            refreshToken: "1//vscdb-refresh",
            expiry: expiry
        )

        let encoded = AntigravityVscdbProtobuf.encode(token: originalToken)
        let decoded = AntigravityVscdbProtobuf.decode(base64Topic: encoded)
        XCTAssertEqual(decoded, originalToken)

        let dbURL = self.tempDirectoryURL.appendingPathComponent("state.vscdb")
        try Self.createEmptyItemTableDatabase(at: dbURL)

        AntigravityLocalCredentialSync.writeTokenToVscdb(originalToken, at: dbURL)
        let readBack = AntigravityLocalCredentialSync.readTokenFromVscdb(at: dbURL)
        XCTAssertEqual(readBack, originalToken)
    }

    func testParseQuotaSummaryHandlesProto3ZeroFractionAndWindows() throws {
        let responseJSON = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "resetTime": "2026-10-19T10:00:00Z",
                  "remainingFraction": 0.95
                },
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "resetTime": "2026-10-25T10:00:00Z",
                  "remainingFraction": 0.98
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "resetTime": "2026-10-19T08:30:00Z"
                },
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "resetTime": "2026-10-22T09:00:00Z",
                  "remainingFraction": 1.0
                }
              ]
            },
            {
              "displayName": "Gemini 4 Argon",
              "buckets": [
                {
                  "bucketId": "gemini-argon-wtu-weekly",
                  "displayName": "Gemini 4 Argon Weekly Limit",
                  "window": "weekly",
                  "resetTime": "2026-10-26T04:12:02Z",
                  "remainingFraction": 0.5216532
                }
              ]
            }
          ]
        }
        """
        let windows = try AntigravityAccountService.parseQuotaSummary(data: Data(responseJSON.utf8))
        XCTAssertEqual(windows.count, 5)
        XCTAssertEqual(windows[0].id, "gemini-5h")
        XCTAssertEqual(windows[0].remainingPercent, 95)
        XCTAssertEqual(windows[1].id, "gemini-weekly")
        XCTAssertEqual(windows[1].remainingPercent, 98)
        XCTAssertEqual(windows[2].id, "3p-5h")
        XCTAssertEqual(windows[2].remainingPercent, 0)
        XCTAssertEqual(windows[2].usedPercent, 100)
        XCTAssertEqual(windows[3].id, "3p-weekly")
        XCTAssertEqual(windows[3].remainingPercent, 100)
        XCTAssertEqual(windows[4].id, "gemini-argon-wtu-weekly")
        XCTAssertEqual(windows[4].groupName, "Gemini 4 Argon")
        XCTAssertEqual(windows[4].shortLabel, "Gemini 4 Argon")
        XCTAssertEqual(windows[4].compactBadgeLabel, "Argon")
        XCTAssertEqual(windows[4].remainingPercent, 52)
    }

    func testQuotaSummaryRejectsUnknownOrMalformedUsageInsteadOfReportingZero() throws {
        let invalidResponses = [
            "{}",
            #"{"groups":[]}"#,
            #"{"groups":[{"buckets":[]}]}"#,
            #"{"groups":[{"buckets":[{"remainingFraction":0.5}]}]}"#,
            #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":true}]}]}"#,
            #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":null}]}]}"#,
            #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":"NaN"}]}]}"#,
            #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":-1}]}]}"#,
            #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":2}]}]}"#,
            #"{"groups":[{"buckets":[{"bucketId":"gemini-5h"},{"bucketId":"gemini-5h"}]}]}"#
        ]
        for response in invalidResponses {
            XCTAssertThrowsError(try AntigravityAccountService.parseQuotaSummary(data: Data(response.utf8)))
        }
        let numericString = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":"0.75"}]}]}"#
        let windows = try AntigravityAccountService.parseQuotaSummary(data: Data(numericString.utf8))
        XCTAssertEqual(windows.first?.remainingPercent, 75)
    }

    func testQuotaEndpointUnauthorizedRefreshesAndRetriesTheWholeProbeOnce() async throws {
        let transport = QueuedAntigravityTransport(responses: [
            (200, Self.codeAssistResponse), (401, "{}"),
            (200, #"{"access_token":"refreshed-access","expires_in":3600}"#),
            (200, Self.codeAssistResponse), (200, Self.quotaResponse)
        ])
        let service = AntigravityAccountService(transport: transport, clientConfiguration: self.oauthClient)
        let result = try await service.probeAccount(tokenFile: Self.sampleTokenFile(), forceRefresh: false)

        XCTAssertEqual(result.tokenFile.token.accessToken, "refreshed-access")
        XCTAssertEqual(result.quotaWindows.first?.remainingPercent, 75)
        let paths = await transport.requestPaths
        XCTAssertEqual(paths, [
            "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary",
            "/token", "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary"
        ])
    }

    func testProbeDoesNotLoopWhenFreshAuthorizationIsRejected() async throws {
        let transport = QueuedAntigravityTransport(responses: [
            (200, #"{"access_token":"refreshed-access","expires_in":3600}"#),
            (200, Self.codeAssistResponse), (401, "{}")
        ])
        let service = AntigravityAccountService(transport: transport, clientConfiguration: self.oauthClient)
        do {
            _ = try await service.probeAccount(tokenFile: Self.sampleTokenFile(), forceRefresh: true)
            XCTFail("A rejected fresh token must require authorization.")
        } catch {
            XCTAssertEqual(error as? AntigravityAccountError, .authorizationExpired)
        }
        let paths = await transport.requestPaths
        XCTAssertEqual(paths.count, 3)
    }

    func testRefreshDistinguishesRevokedAuthorizationFromTemporaryServerFailure() async throws {
        for (status, body, expected) in [
            (400, #"{"error":"invalid_grant"}"#, AntigravityAccountError.authorizationExpired),
            (503, "{}", AntigravityAccountError.tokenExchangeFailed("HTTP 503"))
        ] {
            let service = AntigravityAccountService(transport: QueuedAntigravityTransport(responses: [(status, body)]),
                                                    clientConfiguration: self.oauthClient)
            do {
                _ = try await service.refreshTokenFile(Self.sampleTokenFile())
                XCTFail("Refresh should fail.")
            } catch {
                XCTAssertEqual(error as? AntigravityAccountError, expected)
            }
        }
    }

    @MainActor
    func testRefreshPreservesApplicationCredentialsAndNewerPrivateCache() async throws {
        let standaloneURL = self.tempDirectoryURL.appendingPathComponent("local-token")
        let dbURL = self.tempDirectoryURL.appendingPathComponent("state.vscdb")
        try Self.createEmptyItemTableDatabase(at: dbURL)
        let localSync = AntigravityLocalCredentialSync(standaloneTokenFileURL: standaloneURL, vscdbURLs: [dbURL])
        let original = Self.sampleTokenFile()
        try localSync.writeLocalTokenFile(original)
        let originalData = try Data(contentsOf: standaloneURL)
        var refreshed = original.token
        refreshed.accessToken = "refreshed-access"
        refreshed.expiry = original.token.expiry.addingTimeInterval(3600)
        let store = AntigravityAccountStore(
            rootURL: self.tempDirectoryURL.appendingPathComponent("store"),
            service: MockAntigravityAccountService(refreshedToken: refreshed),
            localSync: localSync, autoDiscoverLocalCredentials: true
        )
        XCTAssertEqual(store.availableCount, 0, "Discovered accounts have unknown quota until fetched.")
        let account = try XCTUnwrap(store.activeAccount)
        await store.refreshAccount(account)
        XCTAssertEqual(try Data(contentsOf: standaloneURL), originalData)
        XCTAssertEqual(AntigravityLocalCredentialSync.readTokenFromVscdb(at: dbURL), original.token)
        XCTAssertEqual(store.loadCredentialFile(for: account.id)?.token, refreshed)

        store.load()
        XCTAssertEqual(store.loadCredentialFile(for: account.id)?.token, refreshed)
        XCTAssertEqual(store.availableCount, 1)
    }

    @MainActor
    func testRefreshFailurePreservesQuotaAndDoesNotMislabelServerOrPermissionErrorsAsLoginExpiry() async throws {
        let root = self.tempDirectoryURL.appendingPathComponent("store")
        let seededStore = AntigravityAccountStore(
            rootURL: root, service: MockAntigravityAccountService(),
            localSync: self.isolatedLocalSync, autoDiscoverLocalCredentials: false
        )
        let original = try await seededStore.importTokenFile(Self.sampleTokenFile(), activate: false)
        for (error, expectedStatus) in [
            (AntigravityAccountError.tokenExchangeFailed("HTTP 503"), AntigravityAccountStatus.error),
            (.quotaRequestFailed("HTTP 403"), .error),
            (.quotaRequestFailed("Missing quota groups"), .error),
            (.authorizationExpired, .reauthRequired)
        ] {
            let store = AntigravityAccountStore(
                rootURL: root, service: MockAntigravityAccountService(probeError: error),
                localSync: self.isolatedLocalSync, autoDiscoverLocalCredentials: false
            )
            await store.refreshAccount(original)
            XCTAssertEqual(store.activeAccount?.status, expectedStatus)
            XCTAssertEqual(store.activeAccount?.quotaWindows, original.quotaWindows)
            XCTAssertEqual(store.activeAccount?.lastUpdatedAt, original.lastUpdatedAt)
            XCTAssertEqual(store.availableCount, 0)
        }
    }

    @MainActor
    func testAccountRemainsAvailableWhenOnlyAnotherModelGroupIsExhausted() async throws {
        let store = AntigravityAccountStore(
            rootURL: self.tempDirectoryURL.appendingPathComponent("store"),
            service: MockAntigravityAccountService(),
            localSync: self.isolatedLocalSync, autoDiscoverLocalCredentials: false
        )
        var account = try await store.importTokenFile(Self.sampleTokenFile(), activate: false)
        account.quotaWindows[3].remainingFraction = 0
        XCTAssertTrue(account.quotaExhausted)
        XCTAssertTrue(account.hasAvailableQuota, "Gemini remains available when the Claude/GPT weekly limit is exhausted.")
        account.quotaWindows[1].remainingFraction = 0
        XCTAssertFalse(account.hasAvailableQuota, "A full 5h window does not bypass the same group's exhausted weekly limit.")
        account.quotaWindows = []
        XCTAssertFalse(account.hasAvailableQuota)
    }

    @MainActor
    func testAccountStoreDiscoveryImportAndSwitching() async throws {
        let standaloneURL = self.tempDirectoryURL.appendingPathComponent("jetski-standalone-oauth-token")
        let vscdbURL = self.tempDirectoryURL.appendingPathComponent("state.vscdb")
        try Self.createEmptyItemTableDatabase(at: vscdbURL)

        let localSync = AntigravityLocalCredentialSync(
            standaloneTokenFileURL: standaloneURL,
            vscdbURLs: [vscdbURL]
        )

        let tokenFileA = AntigravityTokenFile(
            token: AntigravityOAuthToken(
                accessToken: "ya29.account-a",
                tokenType: "Bearer",
                refreshToken: "1//refresh-a",
                expiry: Date().addingTimeInterval(3600)
            ),
            authMethod: "consumer",
            idToken: Self.makeSampleJWT(sub: "user-a", email: "usera@example.com", name: "User A")
        )
        try localSync.writeLocalTokenFile(tokenFileA)

        let mockService = MockAntigravityAccountService()
        let storeRoot = self.tempDirectoryURL.appendingPathComponent("store", isDirectory: true)
        let store = AntigravityAccountStore(
            rootURL: storeRoot,
            service: mockService,
            localSync: localSync,
            showsEmptySection: true,
            autoDiscoverLocalCredentials: true
        )

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.email, "usera@example.com")
        XCTAssertEqual(store.activeAccount?.email, "usera@example.com")

        await store.refreshAll(force: true)
        XCTAssertEqual(store.activeAccount?.planBadgeTitle, "PRO")
        XCTAssertEqual(store.activeAccount?.quotaWindows.count, 4)

        let tokenFileB = AntigravityTokenFile(
            token: AntigravityOAuthToken(
                accessToken: "ya29.account-b",
                tokenType: "Bearer",
                refreshToken: "1//refresh-b",
                expiry: Date().addingTimeInterval(3600)
            ),
            authMethod: "consumer",
            idToken: Self.makeSampleJWT(sub: "user-b", email: "userb@example.com", name: "User B")
        )
        let importedB = try await store.importTokenFile(tokenFileB, activate: true)
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(store.activeAccountID, importedB.id)
        XCTAssertEqual(localSync.readLocalTokenFile()?.token.refreshToken, "1//refresh-b")
        XCTAssertEqual(AntigravityLocalCredentialSync.readTokenFromVscdb(at: vscdbURL)?.refreshToken, "1//refresh-b")

        let accountA = try XCTUnwrap(store.accounts.first(where: { $0.email == "usera@example.com" }))
        try store.activateAccount(accountA)
        XCTAssertEqual(store.activeAccountID, accountA.id)
        XCTAssertEqual(localSync.readLocalTokenFile()?.token.refreshToken, "1//refresh-a")
        XCTAssertEqual(AntigravityLocalCredentialSync.readTokenFromVscdb(at: vscdbURL)?.refreshToken, "1//refresh-a")
    }

    private static func makeSampleJWT(sub: String, email: String, name: String) -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8).base64EncodedString()
        let payloadDict: [String: Any] = [
            "sub": sub,
            "email": email,
            "name": name
        ]
        let payloadData = try! JSONSerialization.data(withJSONObject: payloadDict)
        let payload = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).signature"
    }

    private static let codeAssistResponse =
        #"{"currentTier":{"id":"g1-pro-tier","name":"Google AI Pro"},"cloudaicompanionProject":"aicode-consumers"}"#
    private static let quotaResponse =
        #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75}]}]}"#

    private var isolatedLocalSync: AntigravityLocalCredentialSync {
        AntigravityLocalCredentialSync(
            standaloneTokenFileURL: self.tempDirectoryURL.appendingPathComponent("local-token"), vscdbURLs: []
        )
    }

    private static func sampleTokenFile() -> AntigravityTokenFile {
        AntigravityTokenFile(
            token: AntigravityOAuthToken(
                accessToken: "test-access", tokenType: "Bearer", refreshToken: "test-refresh",
                expiry: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3600)
            ),
            idToken: Self.makeSampleJWT(sub: "test-user", email: "test@example.com", name: "Test")
        )
    }

    private static func createEmptyItemTableDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "AntigravityAccountTests", code: 1)
        }
        defer { sqlite3_close(db) }
        _ = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);", nil, nil, nil)
    }
}

private struct MockAntigravityAccountService: AntigravityAccountServicing {
    var probeError: AntigravityAccountError? = nil
    var refreshedToken: AntigravityOAuthToken? = nil

    func makeAuthorizationSession(port: UInt16) throws -> AntigravityOAuthSession {
        AntigravityOAuthSession(
            state: "test-state",
            codeVerifier: "test-verifier",
            redirectURI: "http://localhost:\(port)/auth/callback",
            authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        )
    }

    func exchangeCallback(callbackInput: String, session: AntigravityOAuthSession) async throws -> AntigravityTokenFile {
        throw AntigravityAccountError.invalidOAuthCallback
    }

    func refreshTokenFile(_ tokenFile: AntigravityTokenFile) async throws -> AntigravityTokenFile {
        tokenFile
    }

    func probeAccount(tokenFile: AntigravityTokenFile, forceRefresh: Bool) async throws -> AntigravityAccountProbeResult {
        if let probeError { throw probeError }
        var tokenFile = tokenFile
        if let refreshedToken { tokenFile.token = refreshedToken }
        let claims = AntigravityJWTClaims.decode(jwt: tokenFile.idToken)
        return AntigravityAccountProbeResult(
            tokenFile: tokenFile,
            userID: claims?.subject,
            email: claims?.email ?? "unknown@example.com",
            displayName: claims?.name,
            tierID: "g1-pro-tier",
            tierName: "Google AI Pro",
            cloudAICompanionProject: "aicode-consumers",
            quotaWindows: [
                AntigravityQuotaWindow(
                    id: "gemini-5h",
                    groupName: "Gemini Models",
                    displayName: "Gemini 5h",
                    windowKind: "5h",
                    remainingFraction: 0.9,
                    resetAt: Date().addingTimeInterval(7200)
                ),
                AntigravityQuotaWindow(
                    id: "gemini-weekly",
                    groupName: "Gemini Models",
                    displayName: "Gemini Weekly",
                    windowKind: "weekly",
                    remainingFraction: 0.8,
                    resetAt: Date().addingTimeInterval(86400 * 3)
                ),
                AntigravityQuotaWindow(
                    id: "3p-5h",
                    groupName: "Claude and GPT models",
                    displayName: "Claude/GPT 5h",
                    windowKind: "5h",
                    remainingFraction: 0.5,
                    resetAt: Date().addingTimeInterval(3600)
                ),
                AntigravityQuotaWindow(
                    id: "3p-weekly",
                    groupName: "Claude and GPT models",
                    displayName: "Claude/GPT Weekly",
                    windowKind: "weekly",
                    remainingFraction: 0.65,
                    resetAt: Date().addingTimeInterval(86400 * 4)
                )
            ]
        )
    }
}

private actor QueuedAntigravityTransport: AntigravityHTTPTransporting {
    private var responses: [(Int, String)]
    private(set) var requestPaths: [String] = []

    init(responses: [(Int, String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        self.requestPaths.append(url.path)
        guard !self.responses.isEmpty else {
            throw AntigravityAccountError.quotaRequestFailed("Unexpected test request")
        }
        let (status, body) = self.responses.removeFirst()
        return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}
