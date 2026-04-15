import AppKit
import Foundation
import SwiftUI

@MainActor
protocol OpenAILoginOAuthManaging: AnyObject {
    var pendingAuthURL: String? { get }
    func startOAuth(
        openBrowser: Bool,
        activate: Bool,
        completion: @escaping (Result<CompletedOpenAIOAuthFlow, Error>) -> Void
    )
    func completeOAuth(from input: String)
    func cancel()
}

protocol LocalhostOAuthCallbackServing: AnyObject {
    func start() throws
    func stop()
}

extension OAuthManager: OpenAILoginOAuthManaging {}
extension LocalhostOAuthCallbackServer: LocalhostOAuthCallbackServing {}

extension Notification.Name {
    static let openAILoginDidSucceed = Notification.Name("lzl.codexbar.openai-login.did-succeed")
    static let openAILoginDidFail = Notification.Name("lzl.codexbar.openai-login.did-fail")
}

private struct OpenAILoginWindowView: View {
    @ObservedObject private var oauth = OAuthManager.shared

    var body: some View {
        OpenAIManualOAuthSheet(
            authURL: oauth.pendingAuthURL ?? "",
            isAuthenticating: oauth.isAuthenticating,
            errorMessage: oauth.errorMessage,
            callbackInput: Binding(
                get: { oauth.callbackInput },
                set: { oauth.callbackInput = $0 }
            )
        ) { input in
            oauth.completeOAuth(from: input)
        } onOpenBrowser: {
            guard let authURL = oauth.pendingAuthURL, let url = URL(string: authURL) else { return }
            NSWorkspace.shared.open(url)
        } onCopyLink: {
            guard let authURL = oauth.pendingAuthURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(authURL, forType: .string)
        } onCancel: {
            OpenAILoginCoordinator.shared.cancel()
        }
    }
}

@MainActor
final class OpenAILoginCoordinator {
    static let shared = OpenAILoginCoordinator()

    static let windowID = "oauth-login"
    static let loginURLScheme = "com.codexbar.oauth"
    static let loginHost = "login"

    private let oauth: any OpenAILoginOAuthManaging
    private let callbackServerFactory: (@escaping @MainActor (String) -> Void) -> any LocalhostOAuthCallbackServing
    private let openWindowAction: () -> Void
    private let closeWindowAction: () -> Void
    private let openURLAction: (URL) -> Void

    private var callbackServer: (any LocalhostOAuthCallbackServing)?

    init(
        oauth: (any OpenAILoginOAuthManaging)? = nil,
        callbackServerFactory: ((@escaping @MainActor (String) -> Void) -> any LocalhostOAuthCallbackServing)? = nil,
        openWindowAction: (() -> Void)? = nil,
        closeWindowAction: (() -> Void)? = nil,
        openURLAction: ((URL) -> Void)? = nil
    ) {
        self.oauth = oauth ?? OAuthManager.shared
        self.callbackServerFactory = callbackServerFactory ?? {
            LocalhostOAuthCallbackServer(onCallback: $0)
        }
        self.openWindowAction = openWindowAction ?? Self.defaultOpenWindow
        self.closeWindowAction = closeWindowAction ?? Self.defaultCloseWindow
        self.openURLAction = openURLAction ?? { NSWorkspace.shared.open($0) }
    }

    func start() {
        oauth.startOAuth(openBrowser: false, activate: false) { result in
            self.stopCallbackServer()
            switch result {
            case .success(let completion):
                let store = TokenStore.shared
                store.load()
                Task {
                    await WhamService.shared.refreshOne(account: completion.account, store: store)
                }
                self.closeWindowAction()
                NotificationCenter.default.post(
                    name: .openAILoginDidSucceed,
                    object: nil,
                    userInfo: [
                        "active": completion.active,
                        "message": completion.active
                            ? "Updated Codex configuration. Changes apply to new sessions."
                            : "Saved OpenAI account.",
                    ]
                )
            case .failure(let error):
                NotificationCenter.default.post(
                    name: .openAILoginDidFail,
                    object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }

        self.startCallbackServer()
        self.openWindowAction()
        if let authURL = oauth.pendingAuthURL, let url = URL(string: authURL) {
            self.openURLAction(url)
        }
    }

    func cancel() {
        self.stopCallbackServer()
        self.oauth.cancel()
        self.closeWindowAction()
    }

    private static func defaultOpenWindow() {
        DetachedWindowPresenter.shared.show(
            id: Self.windowID,
            title: "OpenAI OAuth",
            size: CGSize(width: 560, height: 420)
        ) {
            OpenAILoginWindowView()
        }
    }

    private static func defaultCloseWindow() {
        DetachedWindowPresenter.shared.close(id: Self.windowID)
    }

    private func startCallbackServer() {
        self.stopCallbackServer()

        let server = self.callbackServerFactory { callbackURL in
            self.oauth.completeOAuth(from: callbackURL)
        }
        do {
            try server.start()
            self.callbackServer = server
        } catch {
            NSLog("codexbar localhost OAuth callback listener unavailable: %@", error.localizedDescription)
            self.callbackServer = nil
        }
    }

    private func stopCallbackServer() {
        self.callbackServer?.stop()
        self.callbackServer = nil
    }
}

enum CodexBarURLRouter {
    @MainActor
    static func handle(_ url: URL) {
        guard url.scheme?.caseInsensitiveCompare(OpenAILoginCoordinator.loginURLScheme) == .orderedSame else { return }

        let host = url.host?.lowercased()
        let path = url.path.lowercased()
        if host == OpenAILoginCoordinator.loginHost || path == "/\(OpenAILoginCoordinator.loginHost)" {
            OpenAILoginCoordinator.shared.start()
        }
    }
}
