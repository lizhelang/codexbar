import AppKit
import Foundation
import SwiftUI

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

    private var callbackServer: LocalhostOAuthCallbackServer?

    private init() {}

    func start() {
        let oauth = OAuthManager.shared

        oauth.startOAuth(openBrowser: false, activate: false) { result in
            self.stopCallbackServer()
            switch result {
            case .success(let completion):
                let store = TokenStore.shared
                store.load()
                Task {
                    await WhamService.shared.refreshOne(account: completion.account, store: store)
                }
                DetachedWindowPresenter.shared.close(id: Self.windowID)
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

        self.startCallbackServer(for: oauth)
        self.openWindow()
        if let authURL = oauth.pendingAuthURL, let url = URL(string: authURL) {
            NSWorkspace.shared.open(url)
        }
    }

    func cancel() {
        self.stopCallbackServer()
        OAuthManager.shared.cancel()
        DetachedWindowPresenter.shared.close(id: Self.windowID)
    }

    private func openWindow() {
        DetachedWindowPresenter.shared.show(
            id: Self.windowID,
            title: "OpenAI OAuth",
            size: CGSize(width: 560, height: 420)
        ) {
            OpenAILoginWindowView()
        }
    }

    private func startCallbackServer(for oauth: OAuthManager) {
        self.stopCallbackServer()

        let server = LocalhostOAuthCallbackServer { callbackURL in
            oauth.completeOAuth(from: callbackURL)
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
