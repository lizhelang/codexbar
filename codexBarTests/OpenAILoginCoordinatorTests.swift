import Foundation
import XCTest

@MainActor
final class OpenAILoginCoordinatorTests: XCTestCase {
    private final class OAuthManagerMock: OpenAILoginOAuthManaging {
        struct StartCall: Equatable {
            let openBrowser: Bool
            let activate: Bool
        }

        var pendingAuthURL: String?
        private(set) var startCalls: [StartCall] = []
        private(set) var completedInputs: [String] = []
        private(set) var cancelCallCount = 0

        func startOAuth(
            openBrowser: Bool,
            activate: Bool,
            completion: @escaping (Result<CompletedOpenAIOAuthFlow, Error>) -> Void
        ) {
            self.startCalls.append(StartCall(openBrowser: openBrowser, activate: activate))
        }

        func completeOAuth(from input: String) {
            self.completedInputs.append(input)
        }

        func cancel() {
            self.cancelCallCount += 1
        }
    }

    private final class CallbackServerMock: LocalhostOAuthCallbackServing {
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0

        func start() throws {
            self.startCallCount += 1
        }

        func stop() {
            self.stopCallCount += 1
        }
    }

    func testStartUsesInteractivePopupFlow() {
        let oauth = OAuthManagerMock()
        oauth.pendingAuthURL = "https://auth.openai.com/oauth/authorize?client_id=test"
        let callbackServer = CallbackServerMock()
        var didOpenWindow = false
        var openedURL: URL?

        let coordinator = OpenAILoginCoordinator(
            oauth: oauth,
            callbackServerFactory: { _ in callbackServer },
            openWindowAction: { didOpenWindow = true },
            closeWindowAction: {},
            openURLAction: { openedURL = $0 }
        )

        coordinator.start()

        XCTAssertEqual(oauth.startCalls, [.init(openBrowser: false, activate: false)])
        XCTAssertEqual(callbackServer.startCallCount, 1)
        XCTAssertTrue(didOpenWindow)
        XCTAssertEqual(openedURL?.absoluteString, oauth.pendingAuthURL)
    }

    func testCallbackServerFeedsCapturedURLBackIntoOAuthManager() {
        let oauth = OAuthManagerMock()
        oauth.pendingAuthURL = "https://auth.openai.com/oauth/authorize?client_id=test"
        let callbackServer = CallbackServerMock()
        var callbackHandler: (@MainActor (String) -> Void)?

        let coordinator = OpenAILoginCoordinator(
            oauth: oauth,
            callbackServerFactory: { handler in
                callbackHandler = handler
                return callbackServer
            },
            openWindowAction: {},
            closeWindowAction: {},
            openURLAction: { _ in }
        )

        coordinator.start()
        callbackHandler?("http://localhost:1455/auth/callback?code=oauth-code")

        XCTAssertEqual(callbackServer.startCallCount, 1)
        XCTAssertEqual(
            oauth.completedInputs,
            ["http://localhost:1455/auth/callback?code=oauth-code"]
        )
    }

    func testCancelStopsCallbackServerAndClosesWindow() {
        let oauth = OAuthManagerMock()
        oauth.pendingAuthURL = "https://auth.openai.com/oauth/authorize?client_id=test"
        let callbackServer = CallbackServerMock()
        var didCloseWindow = false

        let coordinator = OpenAILoginCoordinator(
            oauth: oauth,
            callbackServerFactory: { _ in callbackServer },
            openWindowAction: {},
            closeWindowAction: { didCloseWindow = true },
            openURLAction: { _ in }
        )

        coordinator.start()
        coordinator.cancel()

        XCTAssertEqual(callbackServer.startCallCount, 1)
        XCTAssertEqual(callbackServer.stopCallCount, 1)
        XCTAssertEqual(oauth.cancelCallCount, 1)
        XCTAssertTrue(didCloseWindow)
    }
}
