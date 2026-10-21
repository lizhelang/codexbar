import Foundation
import XCTest
@testable import codexbar

final class AntigravityOAuthClientConfigurationTests: XCTestCase {
    private let fixture = AntigravityOAuthClientConfiguration(clientID: "fixture-client-id", clientSecret: "fixture-client-secret")

    func testRuntimePrivateConfigurationIsReadableWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_VERIFY_PRIVATE_OAUTH_CONFIG"] == "1" else {
            throw XCTSkip("Private configuration validation is opt-in and never sends a network request")
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexbar/antigravity-oauth-client.json")
        let client = try AntigravityOAuthClientConfiguration.load(environment: [:], fileURL: file)
        XCTAssertFalse(client.clientID.isEmpty)
        XCTAssertFalse(client.clientSecret.isEmpty)
    }

    func testOwnerOnlyFileLoadsWithoutBundledDefaults() throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("client.json")
        XCTAssertThrowsError(try AntigravityOAuthClientConfiguration.load(environment: [:], fileURL: file))
        try self.write(self.fixture, to: file, mode: 0o600)
        XCTAssertEqual(try AntigravityOAuthClientConfiguration.load(environment: [:], fileURL: file), self.fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try AntigravityOAuthClientConfiguration.load(environment: [:], fileURL: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try AntigravityOAuthClientConfiguration.load(environment: [:], fileURL: link))
    }

    func testExplicitEnvironmentPairNeverMixesWithPrivateFile() throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("client.json")
        try self.write(self.fixture, to: file, mode: 0o600)
        let idKey = AntigravityOAuthClientConfiguration.clientIDEnvironmentKey
        let secretKey = AntigravityOAuthClientConfiguration.clientSecretEnvironmentKey
        XCTAssertThrowsError(try AntigravityOAuthClientConfiguration.load(environment: [idKey: "override"], fileURL: file))
        XCTAssertThrowsError(try AntigravityOAuthClientConfiguration.load(environment: [secretKey: "override"], fileURL: file))
        let configured = try AntigravityOAuthClientConfiguration.load(
            environment: [idKey: "override-client", secretKey: "override-secret"], fileURL: file)
        XCTAssertEqual(configured, AntigravityOAuthClientConfiguration(clientID: "override-client", clientSecret: "override-secret"))
    }

    func testInvalidConfigurationFailsWithAnOpaqueMessage() throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("client.json")
        for data in [Data("sensitive-fixture-malformed-json".utf8),
                     try JSONEncoder().encode(AntigravityOAuthClientConfiguration(clientID: "", clientSecret: "sensitive-fixture")),
                     try JSONEncoder().encode(AntigravityOAuthClientConfiguration(clientID: "fixture", clientSecret: "bad\nsecret")),
                     Data(repeating: 65, count: 17 * 1024)] {
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try AntigravityOAuthClientConfiguration.load(environment: [:], fileURL: file)) { error in
                XCTAssertEqual(error as? AntigravityAccountError, .oauthClientConfigurationUnavailable)
                XCTAssertFalse(error.localizedDescription.contains("sensitive-fixture"))
            }
        }
    }

    func testLoginAndRefreshUseTheInjectedClientPair() async throws {
        let transport = ConfigurationTestTransport()
        let service = AntigravityAccountService(transport: transport, clientConfiguration: self.fixture)
        let session = try service.makeAuthorizationSession(port: 1455)
        let query = try XCTUnwrap(URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, self.fixture.clientID)
        XCTAssertNil(query.first { $0.name == "client_secret" })
        let token = try await service.exchangeCode(code: "fixture-code", codeVerifier: session.codeVerifier, redirectURI: session.redirectURI)
        _ = try await service.refreshTokenFile(token)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
            XCTAssertEqual(request.url?.path, "/token")
            let body = try XCTUnwrap(request.httpBody)
            let fields = try XCTUnwrap(URLComponents(string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems)
            XCTAssertEqual(fields.first { $0.name == "client_id" }?.value, self.fixture.clientID)
            XCTAssertEqual(fields.first { $0.name == "client_secret" }?.value, self.fixture.clientSecret)
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oauth-client-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ configuration: AntigravityOAuthClientConfiguration, to file: URL, mode: Int) throws {
        try JSONEncoder().encode(configuration).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }
}

private actor ConfigurationTestTransport: AntigravityHTTPTransporting {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        let body = Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600}"#.utf8)
        return (body, try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
