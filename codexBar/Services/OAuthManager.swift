import AppKit
import Combine
import Foundation

@MainActor
final class OAuthManager: ObservableObject {
    static let shared = OAuthManager()

    @Published var isAuthenticating = false
    @Published var errorMessage: String?
    @Published var pendingAuthURL: String?
    @Published var callbackInput = ""
    @Published private(set) var activeFlowID: String?

    private let service: OpenAIOAuthFlowService
    private var completionMode: OpenAIOAuthCompletionMode = .account(activate: false)
    private var completionHandler: ((Result<CompletedOpenAIOAuthFlow, Error>) -> Void)?

    init(service: OpenAIOAuthFlowService? = nil) {
        self.service = service ?? OpenAIOAuthFlowService()
    }

    func startOAuth(
        openBrowser: Bool = true,
        activate: Bool = false,
        completion: @escaping (Result<CompletedOpenAIOAuthFlow, Error>) -> Void
    ) {
        self.startOAuth(
            openBrowser: openBrowser,
            completionMode: .account(activate: activate),
            completion: completion
        )
    }

    func startRemoteConnectionOAuth(
        openBrowser: Bool = true,
        completion: @escaping (Result<CompletedOpenAIOAuthFlow, Error>) -> Void
    ) {
        self.startOAuth(
            openBrowser: openBrowser,
            completionMode: .remoteConnection,
            completion: completion
        )
    }

    private func startOAuth(
        openBrowser: Bool,
        completionMode: OpenAIOAuthCompletionMode,
        completion: @escaping (Result<CompletedOpenAIOAuthFlow, Error>) -> Void
    ) {
        self.cancel()

        do {
            let started = try self.service.startFlow()
            self.isAuthenticating = true
            self.errorMessage = nil
            self.pendingAuthURL = started.authURL
            self.callbackInput = ""
            self.activeFlowID = started.flowID
            self.completionMode = completionMode
            self.completionHandler = completion

            if openBrowser, let url = URL(string: started.authURL) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            self.fail(error)
        }
    }

    func cancel() {
        if let activeFlowID {
            try? self.service.cancelFlow(flowID: activeFlowID)
        }
        self.isAuthenticating = false
        self.errorMessage = nil
        self.pendingAuthURL = nil
        self.callbackInput = ""
        self.activeFlowID = nil
        self.completionMode = .account(activate: false)
        self.completionHandler = nil
    }

    func completeOAuth(from input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            self.reportRecoverable(OpenAIOAuthError.invalidCallback)
            return
        }
        self.callbackInput = trimmed
        guard let activeFlowID else {
            self.reportRecoverable(OpenAIOAuthError.noPendingFlow)
            return
        }

        let completionMode = self.completionMode
        Task {
            do {
                let result = try await self.service.completeFlow(
                    flowID: activeFlowID,
                    callbackInput: trimmed,
                    completionMode: completionMode
                )
                await MainActor.run {
                    self.isAuthenticating = false
                    self.errorMessage = nil
                    self.pendingAuthURL = nil
                    self.callbackInput = ""
                    self.activeFlowID = nil
                    self.completionMode = .account(activate: false)
                    self.completionHandler?(.success(result))
                    self.completionHandler = nil
                }
            } catch {
                await MainActor.run {
                    self.reportRecoverable(error)
                }
            }
        }
    }

    private func fail(_ error: Error) {
        self.errorMessage = error.localizedDescription
        self.isAuthenticating = false
        self.pendingAuthURL = nil
        self.callbackInput = ""
        self.activeFlowID = nil
        self.completionMode = .account(activate: false)
        self.completionHandler?(.failure(error))
        self.completionHandler = nil
    }

    private func reportRecoverable(_ error: Error) {
        self.errorMessage = error.localizedDescription
    }
}
