import Foundation
import XCTest

final class LocalhostOAuthCallbackServerTests: XCTestCase {
    func testCallbackURLParsesValidRequestLine() {
        let request = """
        GET /auth/callback?code=abc123&state=xyz HTTP/1.1\r
        Host: localhost:1455\r
        Connection: close\r
        \r
        """

        let callbackURL = LocalhostOAuthCallbackServer.callbackURL(from: request)
        XCTAssertEqual(callbackURL, "http://localhost:1455/auth/callback?code=abc123&state=xyz")
    }

    func testCallbackURLRejectsNonCallbackRoutes() {
        let request = """
        GET /favicon.ico HTTP/1.1\r
        Host: localhost:1455\r
        \r
        """

        XCTAssertNil(LocalhostOAuthCallbackServer.callbackURL(from: request))
    }

    func testCallbackPathMustMatchExactlyAndCannotContainAFragment() {
        for path in ["/auth/callback-extra?code=x", "/auth/callback/extra?code=x",
                     "/auth/callback#fragment", "https://example.com/auth/callback"] {
            XCTAssertNil(LocalhostOAuthCallbackServer.callbackURL(from: "GET \(path) HTTP/1.1\r\n\r\n"))
        }
    }

    @MainActor
    func testInvalidStateDoesNotConsumeListenerAndCorrectedCallbackSucceeds() async throws {
        let received = self.expectation(description: "Validated callback")
        var callbacks: [String] = []
        let server = try self.startedServer(acceptsCallback: {
            URLComponents(string: $0)?.queryItems?.first(where: { $0.name == "state" })?.value == "fixture-state"
        }) {
            callbacks.append($0)
            received.fulfill()
        }
        defer { server.stop() }
        let wrongPath = try await self.status(port: server.port, path: "/callback-extra?code=fixture-code&state=fixture-state")
        XCTAssertEqual(wrongPath, 404)
        let wrongState = try await self.status(port: server.port, path: "/callback?code=fixture-code&state=wrong")
        XCTAssertEqual(wrongState, 400)
        XCTAssertTrue(callbacks.isEmpty)
        let valid = try await self.status(port: server.port, path: "/callback?code=fixture-code&state=fixture-state")
        XCTAssertEqual(valid, 200)
        await self.fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(callbacks.count, 1)
    }

    @MainActor
    func testRepeatedStopAndRestartDoNotCloseNewListener() async throws {
        let received = self.expectation(description: "Callback after restart")
        let server = try self.startedServer(acceptsCallback: { _ in true }) { _ in received.fulfill() }
        defer { server.stop() }
        for _ in 0..<8 {
            server.stop()
            try server.start()
        }
        let code = try await self.status(port: server.port, path: "/callback?code=fixture-code")
        XCTAssertEqual(code, 200)
        await self.fulfillment(of: [received], timeout: 2)
    }

    @MainActor
    private func startedServer(
        acceptsCallback: @escaping @Sendable (String) -> Bool,
        onCallback: @escaping @MainActor (String) -> Void
    ) throws -> LocalhostOAuthCallbackServer {
        for _ in 0..<20 {
            let server = LocalhostOAuthCallbackServer(port: UInt16.random(in: 40_000...50_000),
                callbackPath: "/callback", acceptsCallback: acceptsCallback, onCallback: onCallback)
            do { try server.start(); return server } catch { continue }
        }
        throw LocalhostOAuthCallbackServerError.socketCreationFailed
    }

    private func status(port: UInt16, path: String) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        return try XCTUnwrap(response as? HTTPURLResponse).statusCode
    }
}
