import CFNetwork
import Foundation
import Network

extension Notification.Name {
    static let openAIAccountGatewayDidRouteAccount = Notification.Name(
        "lzl.codexbar.openai-gateway.did-route-account"
    )
}

protocol OpenAIAccountGatewayControlling: AnyObject {
    func startIfNeeded()
    func stop()
    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    )
    func currentRoutedAccountID() -> String?
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot]
    @discardableResult func clearStickyBinding(threadID: String) -> Bool
}

enum OpenAIAccountGatewayConfiguration {
    static let host = "localhost"
    static let port: UInt16 = 1456
    static let apiKey = "codexbar-local-gateway"
    static let originator = "codexbar"
    static let reasoningIncludeMarker = "reasoning.encrypted_content"
    static let upstreamResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let upstreamResponsesCompactURL = URL(string: "https://chatgpt.com/backend-api/codex/responses/compact")!

    static var baseURLString: String {
        "http://\(self.host):\(self.port)/v1"
    }
}

struct OpenAIAccountGatewayRuntimeConfiguration {
    var host: String
    var port: UInt16
    var upstreamResponsesURL: URL
    var upstreamResponsesCompactURL: URL

    static let live = OpenAIAccountGatewayRuntimeConfiguration(
        host: OpenAIAccountGatewayConfiguration.host,
        port: OpenAIAccountGatewayConfiguration.port,
        upstreamResponsesURL: OpenAIAccountGatewayConfiguration.upstreamResponsesURL,
        upstreamResponsesCompactURL: OpenAIAccountGatewayConfiguration.upstreamResponsesCompactURL
    )
}

enum OpenAIAccountGatewayUpstreamProxyResolutionMode: Equatable {
    case systemDefault
    case loopbackProxySafe
}

private enum OpenAIAccountGatewaySystemProxyKind: CaseIterable {
    case http
    case https
    case socks

    var enableKey: String {
        switch self {
        case .http:
            return kCFNetworkProxiesHTTPEnable as String
        case .https:
            return kCFNetworkProxiesHTTPSEnable as String
        case .socks:
            return kCFNetworkProxiesSOCKSEnable as String
        }
    }

    var hostKey: String {
        switch self {
        case .http:
            return kCFNetworkProxiesHTTPProxy as String
        case .https:
            return kCFNetworkProxiesHTTPSProxy as String
        case .socks:
            return kCFNetworkProxiesSOCKSProxy as String
        }
    }

    var portKey: String {
        switch self {
        case .http:
            return kCFNetworkProxiesHTTPPort as String
        case .https:
            return kCFNetworkProxiesHTTPSPort as String
        case .socks:
            return kCFNetworkProxiesSOCKSPort as String
        }
    }
}

struct OpenAIAccountGatewaySystemProxyEndpoint: Equatable {
    let kind: String
    let host: String
    let port: Int

    var isLoopback: Bool {
        let normalizedHost = self.host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalizedHost == "localhost" || normalizedHost == "127.0.0.1" || normalizedHost == "::1"
    }
}

struct OpenAIAccountGatewaySystemProxySnapshot: Equatable {
    let http: OpenAIAccountGatewaySystemProxyEndpoint?
    let https: OpenAIAccountGatewaySystemProxyEndpoint?
    let socks: OpenAIAccountGatewaySystemProxyEndpoint?

    var hasEnabledProxy: Bool {
        self.http != nil || self.https != nil || self.socks != nil
    }

    static func captureCurrent() -> OpenAIAccountGatewaySystemProxySnapshot? {
        guard let unmanagedSettings = CFNetworkCopySystemProxySettings() else {
            return nil
        }
        let settings = unmanagedSettings.takeRetainedValue() as NSDictionary
        return self.init(settings: settings as? [AnyHashable: Any] ?? [:])
    }

    init(http: OpenAIAccountGatewaySystemProxyEndpoint?, https: OpenAIAccountGatewaySystemProxyEndpoint?, socks: OpenAIAccountGatewaySystemProxyEndpoint?) {
        self.http = http
        self.https = https
        self.socks = socks
    }

    init?(settings: [AnyHashable: Any]) {
        let http = Self.proxyEndpoint(kind: .http, settings: settings)
        let https = Self.proxyEndpoint(kind: .https, settings: settings)
        let socks = Self.proxyEndpoint(kind: .socks, settings: settings)
        if http == nil, https == nil, socks == nil {
            return nil
        }
        self.init(http: http, https: https, socks: socks)
    }

    func applyingLoopbackSafePolicy() -> (effectiveSnapshot: OpenAIAccountGatewaySystemProxySnapshot?, applied: Bool) {
        let filtered = OpenAIAccountGatewaySystemProxySnapshot(
            http: self.http?.isLoopback == true ? nil : self.http,
            https: self.https?.isLoopback == true ? nil : self.https,
            socks: self.socks?.isLoopback == true ? nil : self.socks
        )
        let applied = filtered != self
        return (
            effectiveSnapshot: filtered.hasEnabledProxy ? filtered : nil,
            applied: applied
        )
    }

    var connectionProxyDictionary: [AnyHashable: Any] {
        var dictionary = Self.disabledConnectionProxyDictionary
        if let http = self.http {
            dictionary[kCFNetworkProxiesHTTPEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPProxy as String] = http.host
            dictionary[kCFNetworkProxiesHTTPPort as String] = http.port
        }
        if let https = self.https {
            dictionary[kCFNetworkProxiesHTTPSEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPSProxy as String] = https.host
            dictionary[kCFNetworkProxiesHTTPSPort as String] = https.port
        }
        if let socks = self.socks {
            dictionary[kCFNetworkProxiesSOCKSEnable as String] = 1
            dictionary[kCFNetworkProxiesSOCKSProxy as String] = socks.host
            dictionary[kCFNetworkProxiesSOCKSPort as String] = socks.port
        }
        return dictionary
    }

    static var disabledConnectionProxyDictionary: [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
        ]
    }

    private static func proxyEndpoint(
        kind: OpenAIAccountGatewaySystemProxyKind,
        settings: [AnyHashable: Any]
    ) -> OpenAIAccountGatewaySystemProxyEndpoint? {
        let enabled: Bool?
        switch settings[kind.enableKey] {
        case let value as Bool:
            enabled = value
        case let value as NSNumber:
            enabled = value.boolValue
        case let value as Int:
            enabled = value != 0
        case let value as String:
            enabled = Int(value).map { $0 != 0 }
        default:
            enabled = nil
        }

        let port: Int?
        switch settings[kind.portKey] {
        case let value as Int:
            port = value
        case let value as NSNumber:
            port = value.intValue
        case let value as String:
            port = Int(value)
        default:
            port = nil
        }

        guard enabled == true,
              let host = (settings[kind.hostKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              let port,
              port > 0 else {
            return nil
        }

        return OpenAIAccountGatewaySystemProxyEndpoint(
            kind: String(describing: kind),
            host: host,
            port: port
        )
    }
}

struct OpenAIAccountGatewayResolvedUpstreamTransportPolicy: Equatable {
    let proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode
    let systemProxySnapshot: OpenAIAccountGatewaySystemProxySnapshot?
    let effectiveProxySnapshot: OpenAIAccountGatewaySystemProxySnapshot?
    let loopbackProxySafeApplied: Bool

    var connectionProxyDictionary: [AnyHashable: Any]? {
        if let effectiveProxySnapshot {
            return effectiveProxySnapshot.connectionProxyDictionary
        }
        if self.loopbackProxySafeApplied {
            return OpenAIAccountGatewaySystemProxySnapshot.disabledConnectionProxyDictionary
        }
        return nil
    }
}

struct OpenAIAccountGatewayUpstreamTransportConfiguration {
    var requestTimeout: TimeInterval
    var resourceTimeout: TimeInterval
    var webSocketReadyBudget: TimeInterval
    var waitsForConnectivity: Bool
    var proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode
    var proxySnapshotProvider: () -> OpenAIAccountGatewaySystemProxySnapshot?

    init(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        webSocketReadyBudget: TimeInterval,
        waitsForConnectivity: Bool,
        proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode = .loopbackProxySafe,
        proxySnapshotProvider: @escaping () -> OpenAIAccountGatewaySystemProxySnapshot? = {
            OpenAIAccountGatewaySystemProxySnapshot.captureCurrent()
        }
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.webSocketReadyBudget = webSocketReadyBudget
        self.waitsForConnectivity = waitsForConnectivity
        self.proxyResolutionMode = proxyResolutionMode
        self.proxySnapshotProvider = proxySnapshotProvider
    }

    static let live = OpenAIAccountGatewayUpstreamTransportConfiguration(
        requestTimeout: 30,
        resourceTimeout: 120,
        webSocketReadyBudget: 8,
        waitsForConnectivity: false
    )

    func resolvedURLSessionConfiguration() -> (
        configuration: URLSessionConfiguration,
        policy: OpenAIAccountGatewayResolvedUpstreamTransportPolicy
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = self.requestTimeout
        configuration.timeoutIntervalForResource = self.resourceTimeout
        configuration.waitsForConnectivity = self.waitsForConnectivity
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let snapshot = self.proxySnapshotProvider()
        let snapshotDTO = PortableCoreGatewayProxySnapshot.legacy(from: snapshot)
        let policy =
            ((try? RustPortableCoreAdapter.shared.resolveGatewayTransportPolicy(
                PortableCoreGatewayTransportPolicyRequest(
                    proxyResolutionMode: self.proxyResolutionMode == .loopbackProxySafe ? "loopbackProxySafe" : "systemDefault",
                    systemProxySnapshot: snapshotDTO
                ),
                buildIfNeeded: false
            )) ?? PortableCoreGatewayTransportPolicyResult.failClosed(
                proxyResolutionMode: self.proxyResolutionMode == .loopbackProxySafe ? "loopbackProxySafe" : "systemDefault",
                systemProxySnapshot: snapshotDTO
            ))
            .resolvedPolicy()
        if let connectionProxyDictionary = policy.connectionProxyDictionary {
            configuration.connectionProxyDictionary = connectionProxyDictionary
        }
        return (configuration, policy)
    }
}

enum OpenAIAccountGatewayFailoverDisposition: Equatable {
    case failover
    case doNotFailover
}

enum OpenAIAccountGatewayFailureClass: String, Equatable {
    case accountStatus
    case upstreamStatus
    case transport
    case protocolViolation
}

enum OpenAIAccountGatewayUpstreamFailure: Error {
    case accountStatus(Int)
    case upstreamStatus(Int)
    case transport(Error)
    case protocolViolation(Error)

    var failoverDisposition: OpenAIAccountGatewayFailoverDisposition {
        switch self {
        case .accountStatus, .upstreamStatus:
            return .failover
        case .transport, .protocolViolation:
            return .doNotFailover
        }
    }

    var failureClass: OpenAIAccountGatewayFailureClass {
        switch self {
        case .accountStatus:
            return .accountStatus
        case .upstreamStatus:
            return .upstreamStatus
        case .transport:
            return .transport
        case .protocolViolation:
            return .protocolViolation
        }
    }

    var statusCode: Int? {
        switch self {
        case .accountStatus(let statusCode), .upstreamStatus(let statusCode):
            return statusCode
        case .transport, .protocolViolation:
            return nil
        }
    }

    var underlyingError: Error? {
        switch self {
        case .transport(let error), .protocolViolation(let error):
            return error
        case .accountStatus, .upstreamStatus:
            return nil
        }
    }
}

struct OpenAIAccountGatewayUpstreamFailureDiagnostic: Equatable {
    let route: String
    let failureClass: OpenAIAccountGatewayFailureClass
    let statusCode: Int?
    let errorDomain: String?
    let errorCode: Int?
    let loopbackProxySafeApplied: Bool
}

private struct OpenAIAccountGatewaySnapshot {
    var accounts: [TokenAccount]
    var quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var stickyBindings: [String: StickyBinding]
    var runtimeBlockedUntilByAccountID: [String: Date]
}

private struct StickyBinding {
    let accountID: String
    let updatedAt: Date
}

private struct RuntimeBlockedAccount {
    let retryAt: Date
}

struct OpenAIAccountProtocolSignal {
    let message: String?
    let retryAt: Date?
}

enum OpenAIAccountGatewayProtocolPreviewDecision {
    case needMoreData
    case streamNow
    case accountSignal(OpenAIAccountProtocolSignal)
}

private enum OpenAIAccountGatewayPOSTDisposition {
    case streamed(bindSticky: Bool)
    case accountSignal(OpenAIAccountProtocolSignal)
}

private enum OpenAIAccountGatewayPOSTAttemptOutcome<Success> {
    case completed(Success, bindSticky: Bool, alreadyBound: Bool)
    case retryNextCandidate
}

private struct OpenAIAccountGatewayPreBytePOSTFailure: Error {
    let failure: OpenAIAccountGatewayUpstreamFailure
}

struct ParsedGatewayRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    init(portableCore request: PortableCoreGatewayParsedRequest) {
        self.method = request.method
        self.path = request.path
        self.headers = request.headers
        self.body = Data(request.bodyText.utf8)
    }
}

private struct ParsedWebSocketFrame {
    let opcode: UInt8
    let payload: Data
    let isFinal: Bool

    init(portableCore frame: PortableCoreGatewayParsedWebSocketFrame) {
        self.opcode = frame.opcode
        self.payload = Data(frame.payloadBytes)
        self.isFinal = frame.isFinal
    }
}

private struct WebSocketFragmentState {
    var opcode: UInt8?
    var payload = Data()
}

private enum OpenAIAccountGatewayResponsesRoute {
    case responses
    case compact

    init?(requestPath: String) {
        switch requestPath {
        case "/v1/responses":
            self = .responses
        case "/v1/responses/compact":
            self = .compact
        default:
            return nil
        }
    }

    func upstreamURL(using configuration: OpenAIAccountGatewayRuntimeConfiguration) -> URL {
        switch self {
        case .responses:
            return configuration.upstreamResponsesURL
        case .compact:
            return configuration.upstreamResponsesCompactURL
        }
    }

    var diagnosticName: String {
        switch self {
        case .responses:
            return "responses"
        case .compact:
            return "compact"
        }
    }
}

final class OpenAIAccountGatewayService: OpenAIAccountGatewayControlling {
    static let shared = OpenAIAccountGatewayService()
    nonisolated static let mockRequestBodyPropertyKey = "codexbar.mockRequestBody"

    private let listenerQueue = DispatchQueue(label: "lzl.codexbar.openai-gateway.listener")
    private let stateQueue = DispatchQueue(label: "lzl.codexbar.openai-gateway.state")
    private let urlSession: URLSession
    private let upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration
    private let upstreamTransportPolicy: OpenAIAccountGatewayResolvedUpstreamTransportPolicy
    private let runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration
    private let routeJournalStore: OpenAIAggregateRouteJournalStoring
    private let diagnosticsReporter: (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void

    private var listener: NWListener?
    private var accounts: [TokenAccount] = []
    private var quotaSortSettings = CodexBarOpenAISettings.QuotaSortSettings()
    private var accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount
    private var stickyBindings: [String: StickyBinding] = [:]
    private var runtimeBlockedAccounts: [String: RuntimeBlockedAccount] = [:]
    private var lastRoutedAccountID: String?

    init(
        urlSession: URLSession? = nil,
        upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration = .live,
        runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration = .live,
        routeJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(),
        diagnosticsReporter: @escaping (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void = { diagnostic in
            let status = diagnostic.statusCode.map(String.init) ?? "-"
            let errorDomain = diagnostic.errorDomain ?? "-"
            let errorCode = diagnostic.errorCode.map(String.init) ?? "-"
            NSLog(
                "codexbar OpenAI gateway upstream failure route=%@ failureClass=%@ status=%@ errorDomain=%@ errorCode=%@ loopbackProxySafe=%@",
                diagnostic.route,
                diagnostic.failureClass.rawValue,
                status,
                errorDomain,
                errorCode,
                diagnostic.loopbackProxySafeApplied ? "true" : "false"
            )
        }
    ) {
        let resolvedTransportConfiguration = upstreamTransportConfiguration.resolvedURLSessionConfiguration()
        self.urlSession = urlSession ?? URLSession(configuration: resolvedTransportConfiguration.configuration)
        self.upstreamTransportConfiguration = upstreamTransportConfiguration
        self.upstreamTransportPolicy = resolvedTransportConfiguration.policy
        self.runtimeConfiguration = runtimeConfiguration
        self.routeJournalStore = routeJournalStore
        self.diagnosticsReporter = diagnosticsReporter
    }

    func startIfNeeded() {
        self.listenerQueue.async {
            guard self.listener == nil else { return }

            do {
                let port = NWEndpoint.Port(rawValue: self.runtimeConfiguration.port)!
                let listener = try NWListener(using: .tcp, on: port)
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    connection.start(queue: self.listenerQueue)
                    self.receiveRequest(on: connection, accumulated: Data())
                }
                listener.stateUpdateHandler = { state in
                    if case .failed = state {
                        self.listenerQueue.async {
                            self.listener = nil
                        }
                    }
                }
                self.listener = listener
                listener.start(queue: self.listenerQueue)
            } catch {
                NSLog("codexbar OpenAI gateway failed to start: %@", error.localizedDescription)
            }
        }
    }

    func stop() {
        self.listenerQueue.sync {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    ) {
        let now = Date()
        let normalized =
            (try? RustPortableCoreAdapter.shared.normalizeGatewayState(
            PortableCoreGatewayStateNormalizationRequest(
                currentRoutedAccountId: self.currentRoutedAccountID(),
                knownAccountIds: accounts.map(\.accountId),
                stickyBindings: self.portableStickyBindingsSnapshot(),
                runtimeBlockedAccounts: self.stateQueue.sync {
                    self.runtimeBlockedAccounts.map {
                        PortableCoreGatewayRuntimeBlockedAccountStateInput(
                            accountId: $0.key,
                            retryAt: $0.value.retryAt.timeIntervalSince1970
                        )
                    }
                },
                now: now.timeIntervalSince1970,
                stickyExpirationIntervalSeconds: 60 * 60 * 6,
                stickyMaxEntries: 256
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayStateNormalizationResult.failClosed(
            currentRoutedAccountId: self.currentRoutedAccountID(),
            knownAccountIds: accounts.map(\.accountId),
            stickyBindings: self.portableStickyBindingsSnapshot(),
            runtimeBlockedAccounts: self.stateQueue.sync {
                self.runtimeBlockedAccounts.map {
                    PortableCoreGatewayRuntimeBlockedAccountStateInput(
                        accountId: $0.key,
                        retryAt: $0.value.retryAt.timeIntervalSince1970
                    )
                }
            },
            now: now.timeIntervalSince1970,
            stickyExpirationIntervalSeconds: 60 * 60 * 6,
            stickyMaxEntries: 256
        )
        self.stateQueue.async {
            self.accounts = accounts
            self.quotaSortSettings = quotaSortSettings
            self.accountUsageMode = accountUsageMode
            self.lastRoutedAccountID = normalized.nextRoutedAccountId
            self.applyStickyBindings(normalized.stickyBindings)
            self.runtimeBlockedAccounts = Dictionary(
                uniqueKeysWithValues: normalized.runtimeBlockedAccounts.map {
                    ($0.accountId, RuntimeBlockedAccount(retryAt: Date(timeIntervalSince1970: $0.retryAt)))
                }
            )
        }
    }

    func currentRoutedAccountID() -> String? {
        self.stateQueue.sync {
            self.lastRoutedAccountID
        }
    }

    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] {
        self.stateQueue.sync {
            self.stickyBindings.map { key, value in
                OpenAIAggregateStickyBindingSnapshot(
                    threadID: key,
                    accountID: value.accountID,
                    updatedAt: value.updatedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.threadID < rhs.threadID
            }
        }
    }

    @discardableResult
    func clearStickyBinding(threadID: String) -> Bool {
        let result =
            (try? RustPortableCoreAdapter.shared.clearGatewayStickyState(
            PortableCoreGatewayStickyClearRequest(
                threadID: threadID,
                accountId: nil,
                stickyBindings: self.portableStickyBindingsSnapshot()
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayStickyClearResult.failClosed(
            threadID: threadID,
            accountId: nil,
            stickyBindings: self.portableStickyBindingsSnapshot()
        )
        return self.stateQueue.sync {
            self.applyStickyBindings(result.stickyBindings)
            return result.cleared
        }
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NSLog("codexbar OpenAI gateway receive failed: %@", error.localizedDescription)
                connection.cancel()
                return
            }

            var combined = accumulated
            if let data {
                combined.append(data)
            }

            if let requestText = String(data: combined, encoding: .utf8) {
                let result =
                    (try? RustPortableCoreAdapter.shared.parseGatewayRequest(
                        PortableCoreGatewayRequestParseRequest(rawText: requestText),
                        buildIfNeeded: false
                    )) ?? PortableCoreGatewayRequestParseResult.failClosed()
                if let parsedRequest = result.parsedRequest {
                    let request = ParsedGatewayRequest(portableCore: parsedRequest)
                    switch (request.method.uppercased(), request.path) {
                    case ("GET", "/v1/responses"):
                        Task {
                            guard request.headers["upgrade"]?.lowercased() == "websocket",
                                  let secKey = request.headers["sec-websocket-key"],
                                  secKey.isEmpty == false else {
                                self.sendJSONResponse(
                                    on: connection,
                                    statusCode: 400,
                                    body: #"{"error":{"message":"websocket upgrade headers are missing"}}"#
                                )
                                return
                            }

                            let stickyKeyRequest = PortableCoreGatewayStickyKeyResolutionRequest(
                                sessionID: request.headers["session_id"],
                                windowID: request.headers["x-codex-window-id"]
                            )
                            let stickyKey =
                                ((try? RustPortableCoreAdapter.shared.resolveGatewayStickyKey(
                                    stickyKeyRequest,
                                    buildIfNeeded: false
                                )) ?? PortableCoreGatewayStickyKeyResolutionResult.failClosed(
                                    request: stickyKeyRequest
                                )).stickyKey
                            do {
                                let established = try await self.routeUpstreamWebSocketCandidate(
                                    request: request,
                                    stickyKey: stickyKey
                                ) { account, requestedProtocol, readyBudget in
                                    guard var components = URLComponents(
                                        url: self.runtimeConfiguration.upstreamResponsesURL,
                                        resolvingAgainstBaseURL: false
                                    ) else {
                                        throw URLError(.badURL)
                                    }
                                    components.scheme = "wss"
                                    guard let upstreamURL = components.url else { throw URLError(.badURL) }

                                    var upstreamRequest = URLRequest(url: upstreamURL)
                                    for (name, value) in request.headers {
                                        switch name {
                                        case "host",
                                             "connection",
                                             "upgrade",
                                             "sec-websocket-version",
                                             "sec-websocket-key",
                                             "sec-websocket-extensions",
                                             "authorization",
                                             "chatgpt-account-id",
                                             "originator":
                                            continue
                                        default:
                                            upstreamRequest.setValue(value, forHTTPHeaderField: name)
                                        }
                                    }

                                    upstreamRequest.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "authorization")
                                    upstreamRequest.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
                                    upstreamRequest.setValue(OpenAIAccountGatewayConfiguration.originator, forHTTPHeaderField: "originator")

                                    let task = self.urlSession.webSocketTask(with: upstreamRequest)
                                    task.resume()
                                    do {
                                        let selectedProtocol = try await withThrowingTaskGroup(of: String?.self) { group in
                                            group.addTask { [weak self] in
                                                guard let self else { return nil }
                                                do {
                                                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                                        task.sendPing { error in
                                                            if let error {
                                                                continuation.resume(throwing: error)
                                                            } else {
                                                                continuation.resume()
                                                            }
                                                        }
                                                    }
                                                } catch {
                                                    if let failure = error as? OpenAIAccountGatewayUpstreamFailure {
                                                        throw failure
                                                    }

                                                    let httpResponse = task.response as? HTTPURLResponse
                                                    let request = PortableCoreGatewayWebSocketReadyValidationRequest(
                                                        hasHTTPResponse: httpResponse != nil,
                                                        responseStatusCode: httpResponse?.statusCode,
                                                        requestedProtocol: nil,
                                                        negotiatedProtocol: httpResponse?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"),
                                                        readyErrorOccurred: true
                                                    )
                                                    let result =
                                                        (try? RustPortableCoreAdapter.shared.validateGatewayWebSocketReady(
                                                            request,
                                                            buildIfNeeded: false
                                                        )) ?? PortableCoreGatewayWebSocketReadyValidationResult.failClosed(
                                                            request: request
                                                        )
                                                    switch result.outcome {
                                                    case OpenAIAccountGatewayFailureClass.accountStatus.rawValue:
                                                        throw OpenAIAccountGatewayUpstreamFailure.accountStatus(result.statusCode ?? 401)
                                                    case OpenAIAccountGatewayFailureClass.upstreamStatus.rawValue:
                                                        throw OpenAIAccountGatewayUpstreamFailure.upstreamStatus(result.statusCode ?? 502)
                                                    case OpenAIAccountGatewayFailureClass.protocolViolation.rawValue:
                                                        throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(error)
                                                    default:
                                                        throw OpenAIAccountGatewayUpstreamFailure.transport(error)
                                                    }
                                                }
                                                let httpResponse = task.response as? HTTPURLResponse
                                                let request = PortableCoreGatewayWebSocketReadyValidationRequest(
                                                    hasHTTPResponse: httpResponse != nil,
                                                    responseStatusCode: httpResponse?.statusCode,
                                                    requestedProtocol: requestedProtocol,
                                                    negotiatedProtocol: httpResponse?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"),
                                                    readyErrorOccurred: false
                                                )
                                                let result =
                                                    (try? RustPortableCoreAdapter.shared.validateGatewayWebSocketReady(
                                                        request,
                                                        buildIfNeeded: false
                                                    )) ?? PortableCoreGatewayWebSocketReadyValidationResult.failClosed(
                                                        request: request
                                                    )
                                                switch result.outcome {
                                                case "ok":
                                                    return result.selectedProtocol
                                                case OpenAIAccountGatewayFailureClass.accountStatus.rawValue:
                                                    throw OpenAIAccountGatewayUpstreamFailure.accountStatus(result.statusCode ?? 401)
                                                case OpenAIAccountGatewayFailureClass.upstreamStatus.rawValue:
                                                    throw OpenAIAccountGatewayUpstreamFailure.upstreamStatus(result.statusCode ?? 502)
                                                case OpenAIAccountGatewayFailureClass.protocolViolation.rawValue:
                                                    throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badServerResponse))
                                                default:
                                                    throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.cannotParseResponse))
                                                }
                                            }
                                            group.addTask {
                                                let nanoseconds = UInt64((readyBudget * 1_000_000_000).rounded())
                                                try await Task.sleep(nanoseconds: nanoseconds)
                                                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
                                            }

                                            guard let result = try await group.next() else {
                                                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
                                            }
                                            group.cancelAll()
                                            return result
                                        }
                                        return (task: task, selectedProtocol: selectedProtocol)
                                    } catch {
                                        task.cancel(with: .goingAway, reason: nil)
                                        throw error
                                    }
                                }
                                self.bind(stickyKey: stickyKey, accountID: established.account.accountId)
                                let handshakeRequest = PortableCoreGatewayWebSocketHandshakeRequest(
                                    secWebSocketKey: secKey,
                                    selectedProtocol: established.selectedProtocol
                                )
                                let response =
                                    (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketHandshake(
                                        handshakeRequest,
                                        buildIfNeeded: false
                                    )) ?? PortableCoreGatewayWebSocketHandshakeResult.failClosed(
                                        request: handshakeRequest
                                    )
                                try await self.send(Data(response.responseText.utf8), on: connection)

                                Task { [weak self] in
                                    guard let self else { return }
                                    func renderFrame(opcode: UInt8, payload: Data = Data(), isFinal: Bool = true) -> Data {
                                        let request = PortableCoreGatewayWebSocketFrameRenderRequest(
                                            opcode: opcode,
                                            payloadBytes: Array(payload),
                                            isFinal: isFinal
                                        )
                                        let result =
                                            (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketFrame(
                                                request,
                                                buildIfNeeded: false
                                            )) ?? PortableCoreGatewayWebSocketFrameRenderResult.failClosed(
                                                request: request
                                            )
                                        return Data(result.frameBytes)
                                    }
                                    do {
                                        while true {
                                            let message = try await established.task.receive()
                                            let frame: Data
                                            switch message {
                                            case .string(let text):
                                                _ = self.handleInBandAccountSignalIfNeeded(
                                                    text: text,
                                                    accountID: established.account.accountId,
                                                    stickyKey: stickyKey
                                                )
                                                frame = renderFrame(opcode: 0x1, payload: Data(text.utf8))
                                            case .data(let data):
                                                if let text = String(data: data, encoding: .utf8) {
                                                    _ = self.handleInBandAccountSignalIfNeeded(
                                                        text: text,
                                                        accountID: established.account.accountId,
                                                        stickyKey: stickyKey
                                                    )
                                                }
                                                frame = renderFrame(opcode: 0x2, payload: data)
                                            @unknown default:
                                                let closePayloadRequest = PortableCoreGatewayWebSocketClosePayloadRequest(code: 1011)
                                                let closePayloadResult =
                                                    (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketClosePayload(
                                                        closePayloadRequest,
                                                        buildIfNeeded: false
                                                    )) ?? PortableCoreGatewayWebSocketClosePayloadResult.failClosed(
                                                        request: closePayloadRequest
                                                    )
                                                frame = renderFrame(
                                                    opcode: 0x8,
                                                    payload: Data(closePayloadResult.payloadBytes)
                                                )
                                            }
                                            try await self.send(frame, on: connection)
                                        }
                                    } catch {
                                        let closePayloadRequest = PortableCoreGatewayWebSocketClosePayloadRequest(code: 1000)
                                        let closePayloadResult =
                                            (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketClosePayload(
                                                closePayloadRequest,
                                                buildIfNeeded: false
                                            )) ?? PortableCoreGatewayWebSocketClosePayloadResult.failClosed(
                                                request: closePayloadRequest
                                            )
                                        try? await self.send(
                                            renderFrame(
                                                opcode: 0x8,
                                                payload: Data(closePayloadResult.payloadBytes)
                                            ),
                                            on: connection
                                        )
                                        established.task.cancel(with: .goingAway, reason: nil)
                                        self.clearBinding(stickyKey: stickyKey, accountID: established.account.accountId)
                                        connection.cancel()
                                    }
                                }
                                self.receiveClientWebSocketMessages(
                                    on: connection,
                                    upstreamTask: established.task,
                                    buffer: Data(),
                                    fragments: WebSocketFragmentState(),
                                    stickyKey: stickyKey,
                                    accountID: established.account.accountId
                                )
                            } catch {
                                self.sendJSONResponse(
                                    on: connection,
                                    statusCode: 502,
                                    body: #"{"error":{"message":"failed to establish upstream websocket"}}"#
                                )
                            }
                        }
                    case ("POST", "/v1/responses"), ("POST", "/v1/responses/compact"):
                        Task {
                            let route: OpenAIAccountGatewayResponsesRoute =
                                request.path == "/v1/responses" ? .responses : .compact
                            _ = await self.routePOSTResponsesCandidates(
                                request,
                                route: route,
                                onNoCandidates: {
                                    self.sendJSONResponse(
                                        on: connection,
                                        statusCode: 503,
                                        body: #"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#
                                    )
                                },
                                onSyntheticGatewayFailure: {
                                    self.sendJSONResponse(
                                        on: connection,
                                        statusCode: 502,
                                        body: #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
                                    )
                                }
                            ) { response, bytes, account, stickyKey, allowInBandFailover, _ in
                                let disposition = try await self.stream(
                                    result: (response, bytes),
                                    account: account,
                                    stickyKey: stickyKey,
                                    to: connection,
                                    allowInBandFailover: allowInBandFailover
                                )
                                switch disposition {
                                case .streamed(let alreadyBound):
                                    return .completed((), bindSticky: false, alreadyBound: alreadyBound)
                                case .accountSignal:
                                    return .retryNextCandidate
                                }
                            }
                        }
                    default:
                        self.sendJSONResponse(
                            on: connection,
                            statusCode: 404,
                            body: #"{"error":{"message":"not found"}}"#
                        )
                    }
                    return
                }
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, accumulated: combined)
        }
    }

    private func bind(stickyKey: String?, accountID: String) {
        let result =
            (try? RustPortableCoreAdapter.shared.bindGatewayStickyState(
            PortableCoreGatewayStickyBindRequest(
                currentRoutedAccountId: self.currentRoutedAccountID(),
                stickyKey: stickyKey,
                accountId: accountID,
                now: Date().timeIntervalSince1970,
                stickyBindings: self.portableStickyBindingsSnapshot(),
                expirationIntervalSeconds: 60 * 60 * 6,
                maxEntries: 256
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayStickyBindResult.failClosed(
            currentRoutedAccountId: self.currentRoutedAccountID(),
            stickyKey: stickyKey,
            accountId: accountID,
            now: Date().timeIntervalSince1970,
            stickyBindings: self.portableStickyBindingsSnapshot(),
            expirationIntervalSeconds: 60 * 60 * 6,
            maxEntries: 256
        )
        self.stateQueue.sync {
            self.lastRoutedAccountID = result.nextRoutedAccountId
            self.applyStickyBindings(result.stickyBindings)
        }
        if result.shouldRecordRoute, let stickyKey, stickyKey.isEmpty == false {
            self.routeJournalStore.recordRoute(
                threadID: stickyKey,
                accountID: accountID,
                timestamp: Date()
            )
        }
        if result.routeChanged {
            NotificationCenter.default.post(
                name: .openAIAccountGatewayDidRouteAccount,
                object: self,
                userInfo: ["accountID": accountID]
            )
        }
    }

    private func clearBinding(stickyKey: String?, accountID: String) {
        guard let stickyKey, stickyKey.isEmpty == false else { return }
        let result =
            (try? RustPortableCoreAdapter.shared.clearGatewayStickyState(
            PortableCoreGatewayStickyClearRequest(
                threadID: stickyKey,
                accountId: accountID,
                stickyBindings: self.portableStickyBindingsSnapshot()
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayStickyClearResult.failClosed(
            threadID: stickyKey,
            accountId: accountID,
            stickyBindings: self.portableStickyBindingsSnapshot()
        )
        self.stateQueue.sync {
            self.applyStickyBindings(result.stickyBindings)
        }
    }

    private func portableStickyBindingsSnapshot() -> [PortableCoreGatewayStickyBindingStateInput] {
        self.stateQueue.sync {
            self.stickyBindings.map { key, value in
                PortableCoreGatewayStickyBindingStateInput(
                    threadID: key,
                    accountId: value.accountID,
                    updatedAt: value.updatedAt.timeIntervalSince1970
                )
            }
        }
    }

    private func applyStickyBindings(_ bindings: [PortableCoreGatewayStickyBindingStateInput]) {
        self.stickyBindings = Dictionary(
            uniqueKeysWithValues: bindings.map {
                (
                    $0.threadID,
                    StickyBinding(
                        accountID: $0.accountId,
                        updatedAt: Date(timeIntervalSince1970: $0.updatedAt)
                    )
                )
            }
        )
    }

    private func runtimeBlockAccount(
        _ account: TokenAccount,
        suggestedRetryAt: Date?
    ) {
        let now = Date()
        let statusPolicy =
            (try? RustPortableCoreAdapter.shared.resolveGatewayStatusPolicy(
            PortableCoreGatewayStatusPolicyRequest(
                statusCode: 429,
                now: now.timeIntervalSince1970,
                allowFallbackRuntimeBlock: true,
                suggestedRetryAt: suggestedRetryAt?.timeIntervalSince1970,
                retryAfterValue: nil,
                account: .legacy(from: account)
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayStatusPolicyResult.failClosed(
            statusCode: 429,
            now: now.timeIntervalSince1970,
            allowFallbackRuntimeBlock: true,
            suggestedRetryAt: suggestedRetryAt?.timeIntervalSince1970,
            retryAfterValue: nil,
            account: .legacy(from: account)
        )
        let retryAt = Date(
            timeIntervalSince1970: statusPolicy.runtimeBlockRetryAt
                ?? suggestedRetryAt?.timeIntervalSince1970
                ?? now.addingTimeInterval(10 * 60).timeIntervalSince1970
        )
        let result =
            (try? RustPortableCoreAdapter.shared.applyGatewayRuntimeBlock(
            PortableCoreGatewayRuntimeBlockApplyRequest(
                currentRoutedAccountId: self.currentRoutedAccountID(),
                blockedAccountId: account.accountId,
                retryAt: retryAt.timeIntervalSince1970,
                now: Date().timeIntervalSince1970,
                runtimeBlockedAccounts: self.stateQueue.sync {
                    self.runtimeBlockedAccounts.map {
                        PortableCoreGatewayRuntimeBlockedAccountStateInput(
                            accountId: $0.key,
                            retryAt: $0.value.retryAt.timeIntervalSince1970
                        )
                    }
                }
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayRuntimeBlockApplyResult.failClosed(
            currentRoutedAccountId: self.currentRoutedAccountID(),
            blockedAccountId: account.accountId,
            retryAt: retryAt.timeIntervalSince1970,
            now: Date().timeIntervalSince1970,
            runtimeBlockedAccounts: self.stateQueue.sync {
                self.runtimeBlockedAccounts.map {
                    PortableCoreGatewayRuntimeBlockedAccountStateInput(
                        accountId: $0.key,
                        retryAt: $0.value.retryAt.timeIntervalSince1970
                    )
                }
            }
        )
        self.stateQueue.sync {
            self.lastRoutedAccountID = result.nextRoutedAccountId
            self.runtimeBlockedAccounts = Dictionary(
                uniqueKeysWithValues: result.runtimeBlockedAccounts.map {
                    ($0.accountId, RuntimeBlockedAccount(retryAt: Date(timeIntervalSince1970: $0.retryAt)))
                }
            )
        }
    }

    private func handleInBandAccountSignalIfNeeded(
        text: String,
        accountID: String,
        stickyKey: String?
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        let signal =
            ((try? RustPortableCoreAdapter.shared.interpretGatewayProtocolSignal(
                PortableCoreGatewayProtocolSignalInterpretationRequest(
                    payloadText: trimmed,
                    now: Date().timeIntervalSince1970
                ),
                buildIfNeeded: false
            )) ?? PortableCoreGatewayProtocolSignalInterpretationResult.failClosed())
            .accountProtocolSignal()
        guard let signal else {
            return false
        }

        let account = self.stateQueue.sync {
            self.accounts.first(where: { $0.accountId == accountID })
        }
        guard let account else { return false }

        self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
        self.clearBinding(stickyKey: stickyKey, accountID: accountID)
        return true
    }

    private func routeUpstreamWebSocketCandidate<TaskType>(
        request: ParsedGatewayRequest,
        stickyKey: String?,
        attempt: (_ account: TokenAccount, _ requestedProtocol: String?, _ readyBudget: TimeInterval) async throws
            -> (task: TaskType, selectedProtocol: String?)
    ) async throws -> (task: TaskType, account: TokenAccount, selectedProtocol: String?) {
        let snapshot = self.stateQueue.sync {
            OpenAIAccountGatewaySnapshot(
                accounts: self.accounts,
                quotaSortSettings: self.quotaSortSettings,
                accountUsageMode: self.accountUsageMode,
                stickyBindings: self.stickyBindings,
                runtimeBlockedUntilByAccountID: self.runtimeBlockedAccounts.mapValues(\.retryAt)
            )
        }
        let candidateRequest = PortableCoreGatewayCandidatePlanRequest(
            accountUsageMode: snapshot.accountUsageMode.rawValue,
            now: Date().timeIntervalSince1970,
            quotaSortSettings: .legacy(from: snapshot.quotaSortSettings),
            accounts: snapshot.accounts.map(PortableCoreGatewayAccountInput.legacy(from:)),
            stickyKey: stickyKey,
            stickyBindings: snapshot.stickyBindings.map { key, value in
                PortableCoreGatewayStickyBindingInput(
                    stickyKey: key,
                    accountId: value.accountID,
                    updatedAt: value.updatedAt.timeIntervalSince1970
                )
            },
            runtimeBlockedAccounts: snapshot.runtimeBlockedUntilByAccountID.map { accountID, retryAt in
                PortableCoreGatewayRuntimeBlockedAccountInput(
                    accountId: accountID,
                    retryAt: retryAt.timeIntervalSince1970
                )
            }
        )
        let candidatePlan =
            (try? RustPortableCoreAdapter.shared.planGatewayCandidates(candidateRequest)) ??
            PortableCoreGatewayCandidatePlanResult.failClosed()
        let accountByID = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.accountId, $0) })
        let candidates = candidatePlan.accountIds.compactMap { accountByID[$0] }
        guard candidates.isEmpty == false else {
            throw URLError(.userAuthenticationRequired)
        }

        let requestedProtocol = request.headers["sec-websocket-protocol"]
        let readyBudget = self.upstreamTransportConfiguration.webSocketReadyBudget
        var lastFailure: Error = URLError(.cannotConnectToHost)
        var usedStickyContextRecovery = false

        for (index, account) in candidates.enumerated() {
            do {
                let established = try await attempt(account, requestedProtocol, readyBudget)
                return (established.task, account, established.selectedProtocol)
            } catch {
                let failure: OpenAIAccountGatewayUpstreamFailure
                if let classified = error as? OpenAIAccountGatewayUpstreamFailure {
                    failure = classified
                } else {
                    let nsError = error as NSError
                    let classificationRequest = PortableCoreGatewayTransportFailureClassificationRequest(
                        errorDomain: nsError.domain,
                        errorCode: nsError.code,
                        allowProtocolViolation: false
                    )
                    let classification =
                        (try? RustPortableCoreAdapter.shared.classifyGatewayTransportFailure(
                            classificationRequest,
                            buildIfNeeded: false
                        )) ?? PortableCoreGatewayTransportFailureClassificationResult.failClosed(
                            request: classificationRequest
                        )
                    switch classification.failureClass {
                    case OpenAIAccountGatewayFailureClass.protocolViolation.rawValue:
                        failure = .protocolViolation(error)
                    default:
                        failure = .transport(error)
                    }
                }
                lastFailure = failure
                if case .accountStatus(let statusCode) = failure {
                    let policy = self.gatewayStatusPolicy(
                        statusCode: statusCode,
                        response: nil,
                        account: account
                    )
                    if policy.shouldRuntimeBlockAccount {
                    self.runtimeBlockAccount(
                        account,
                        suggestedRetryAt: policy.runtimeBlockRetryAt.flatMap { Date(timeIntervalSince1970: $0) }
                    )
                    }
                }
                if usedStickyContextRecovery {
                    throw failure
                }
                if failure.failoverDisposition == .failover,
                   index < candidates.count - 1 {
                    continue
                }
                if self.shouldAttemptStickyContextRecovery(
                    failure: failure,
                    snapshot: snapshot,
                    stickyKey: stickyKey,
                    failedAccountID: account.accountId,
                    candidateIndex: index,
                    candidateCount: candidates.count,
                    usedStickyContextRecovery: usedStickyContextRecovery
                ) {
                    usedStickyContextRecovery = true
                    continue
                }
                throw failure
            }
        }

        throw lastFailure
    }

    private func shouldAttemptStickyContextRecovery(
        failure: OpenAIAccountGatewayUpstreamFailure,
        snapshot: OpenAIAccountGatewaySnapshot,
        stickyKey: String?,
        failedAccountID: String,
        candidateIndex: Int,
        candidateCount: Int,
        usedStickyContextRecovery: Bool
    ) -> Bool {
        let stickyBindingMatchesFailedAccount =
            stickyKey
            .flatMap { key in snapshot.stickyBindings[key]?.accountID == failedAccountID ? true : nil }
            ?? false

        let result =
            (try? RustPortableCoreAdapter.shared.resolveGatewayStickyRecoveryPolicy(
            PortableCoreGatewayStickyRecoveryPolicyRequest(
                failureClass: failure.failureClass.rawValue,
                stickyBindingMatchesFailedAccount: stickyBindingMatchesFailedAccount,
                candidateIndex: candidateIndex,
                candidateCount: candidateCount,
                usedStickyContextRecovery: usedStickyContextRecovery
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayStickyRecoveryPolicyResult.failClosed()
        return result.shouldAttemptStickyContextRecovery
    }

    nonisolated private func classifyPOSTFailure(_ error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        if let failure = error as? OpenAIAccountGatewayUpstreamFailure {
            return failure
        }
        let nsError = error as NSError
        let request = PortableCoreGatewayTransportFailureClassificationRequest(
            errorDomain: nsError.domain,
            errorCode: nsError.code,
            allowProtocolViolation: true
        )
        let classification =
            (try? RustPortableCoreAdapter.shared.classifyGatewayTransportFailure(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayTransportFailureClassificationResult.failClosed(
                request: request
            )

        switch classification.failureClass {
        case OpenAIAccountGatewayFailureClass.protocolViolation.rawValue:
            return .protocolViolation(error)
        default:
            return .transport(error)
        }
    }

    private func routePOSTResponsesCandidates<Success>(
        _ request: ParsedGatewayRequest,
        route: OpenAIAccountGatewayResponsesRoute,
        onNoCandidates: () -> Success,
        onSyntheticGatewayFailure: () -> Success,
        consumeResult: (
            _ response: HTTPURLResponse,
            _ bytes: URLSession.AsyncBytes,
            _ account: TokenAccount,
            _ stickyKey: String?,
            _ allowInBandFailover: Bool,
            _ usedStickyContextRecovery: Bool
        ) async throws -> OpenAIAccountGatewayPOSTAttemptOutcome<Success>
    ) async -> Success {
        let snapshot = self.stateQueue.sync {
            OpenAIAccountGatewaySnapshot(
                accounts: self.accounts,
                quotaSortSettings: self.quotaSortSettings,
                accountUsageMode: self.accountUsageMode,
                stickyBindings: self.stickyBindings,
                runtimeBlockedUntilByAccountID: self.runtimeBlockedAccounts.mapValues(\.retryAt)
            )
        }
        let stickyKeyRequest = PortableCoreGatewayStickyKeyResolutionRequest(
            sessionID: request.headers["session_id"],
            windowID: request.headers["x-codex-window-id"]
        )
        let stickyKey =
            ((try? RustPortableCoreAdapter.shared.resolveGatewayStickyKey(
                stickyKeyRequest,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayStickyKeyResolutionResult.failClosed(
                request: stickyKeyRequest
            )).stickyKey
        let candidateRequest = PortableCoreGatewayCandidatePlanRequest(
            accountUsageMode: snapshot.accountUsageMode.rawValue,
            now: Date().timeIntervalSince1970,
            quotaSortSettings: .legacy(from: snapshot.quotaSortSettings),
            accounts: snapshot.accounts.map(PortableCoreGatewayAccountInput.legacy(from:)),
            stickyKey: stickyKey,
            stickyBindings: snapshot.stickyBindings.map { key, value in
                PortableCoreGatewayStickyBindingInput(
                    stickyKey: key,
                    accountId: value.accountID,
                    updatedAt: value.updatedAt.timeIntervalSince1970
                )
            },
            runtimeBlockedAccounts: snapshot.runtimeBlockedUntilByAccountID.map { accountID, retryAt in
                PortableCoreGatewayRuntimeBlockedAccountInput(
                    accountId: accountID,
                    retryAt: retryAt.timeIntervalSince1970
                )
            }
        )
        let candidatePlan =
            (try? RustPortableCoreAdapter.shared.planGatewayCandidates(candidateRequest)) ??
            PortableCoreGatewayCandidatePlanResult.failClosed()
        let accountByID = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.accountId, $0) })
        let candidates = candidatePlan.accountIds.compactMap { accountByID[$0] }
        var usedStickyContextRecovery = false

        guard candidates.isEmpty == false else {
            return onNoCandidates()
        }

        for (index, account) in candidates.enumerated() {
            let canTryNextCandidate = usedStickyContextRecovery == false && index < candidates.count - 1
            do {
                let normalizedBody: Data
                if let object = try? JSONSerialization.jsonObject(with: request.body) {
                    let bodyJson = JSONValue(any: object)
                    let result =
                        (try? RustPortableCoreAdapter.shared.normalizeOpenAIResponsesRequest(
                            PortableCoreOpenAIResponsesRequestNormalizationRequest(
                                route: route == .compact ? "/v1/responses/compact" : "/v1/responses",
                                bodyJson: bodyJson
                            ),
                            buildIfNeeded: false
                        )) ?? PortableCoreOpenAIResponsesRequestNormalizationResult.failClosed(bodyJson: bodyJson)
                    if let normalized = result.normalizedJson.anyValue as? [String: Any],
                       JSONSerialization.isValidJSONObject(normalized),
                       let data = try? JSONSerialization.data(withJSONObject: normalized) {
                        normalizedBody = data
                    } else {
                        normalizedBody = request.body
                    }
                } else {
                    normalizedBody = request.body
                }
                var upstreamRequest = URLRequest(url: route.upstreamURL(using: self.runtimeConfiguration))
                upstreamRequest.httpMethod = "POST"
                upstreamRequest.httpBody = normalizedBody
                let mutableRequest = (upstreamRequest as NSURLRequest).mutableCopy() as! NSMutableURLRequest
                URLProtocol.setProperty(
                    normalizedBody,
                    forKey: Self.mockRequestBodyPropertyKey,
                    in: mutableRequest
                )
                upstreamRequest = mutableRequest as URLRequest

                for (name, value) in request.headers {
                    switch name {
                    case "host", "content-length", "authorization", "chatgpt-account-id", "connection", "originator":
                        continue
                    default:
                        upstreamRequest.setValue(value, forHTTPHeaderField: name)
                    }
                }

                upstreamRequest.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "authorization")
                upstreamRequest.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
                upstreamRequest.setValue(OpenAIAccountGatewayConfiguration.originator, forHTTPHeaderField: "originator")

                let (bytes, response) = try await self.urlSession.bytes(for: upstreamRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badServerResponse))
                }
                let result = (response: httpResponse, bytes: bytes)
                let statusPolicy = self.gatewayStatusPolicy(
                    statusCode: result.response.statusCode,
                    response: result.response,
                    account: account
                )
                let responseFailure = statusPolicy.gatewayFailure(statusCode: result.response.statusCode)
                if let failure = responseFailure {
                    let underlyingError = failure.underlyingError as NSError?
                    self.diagnosticsReporter(
                        OpenAIAccountGatewayUpstreamFailureDiagnostic(
                            route: route.diagnosticName,
                            failureClass: failure.failureClass,
                            statusCode: failure.statusCode,
                            errorDomain: underlyingError?.domain,
                            errorCode: underlyingError?.code,
                            loopbackProxySafeApplied: self.upstreamTransportPolicy.loopbackProxySafeApplied
                        )
                    )
                }
                if statusPolicy.shouldRuntimeBlockAccount {
                    self.runtimeBlockAccount(
                        account,
                        suggestedRetryAt: statusPolicy.runtimeBlockRetryAt.flatMap { Date(timeIntervalSince1970: $0) }
                    )
                }
                if statusPolicy.shouldRetry,
                   canTryNextCandidate {
                    self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                    continue
                }

                do {
                    let outcome = try await consumeResult(
                        result.response,
                        result.bytes,
                        account,
                        stickyKey,
                        canTryNextCandidate,
                        usedStickyContextRecovery
                    )
                    switch outcome {
                    case .completed(let success, let bindSticky, let alreadyBound):
                        let shouldBindSticky =
                            ((try? RustPortableCoreAdapter.shared.decideGatewayPostCompletionBinding(
                                PortableCoreGatewayPostCompletionBindingDecisionRequest(
                                    allowsBinding: bindSticky,
                                    usedStickyContextRecovery: usedStickyContextRecovery,
                                    statusCode: result.response.statusCode
                                ),
                                buildIfNeeded: false
                            )) ?? PortableCoreGatewayPostCompletionBindingDecisionResult.failClosed(
                                allowsBinding: bindSticky,
                                usedStickyContextRecovery: usedStickyContextRecovery,
                                statusCode: result.response.statusCode
                            )).shouldBindSticky
                        if alreadyBound == false && shouldBindSticky {
                            self.bind(stickyKey: stickyKey, accountID: account.accountId)
                        }
                        return success
                    case .retryNextCandidate:
                        continue
                    }
                } catch {
                    let failure: OpenAIAccountGatewayUpstreamFailure
                    if let preByteFailure = error as? OpenAIAccountGatewayPreBytePOSTFailure {
                        failure = preByteFailure.failure
                    } else {
                        failure = self.classifyPOSTFailure(error)
                    }
                    let underlyingError = failure.underlyingError as NSError?
                    self.diagnosticsReporter(
                        OpenAIAccountGatewayUpstreamFailureDiagnostic(
                            route: route.diagnosticName,
                            failureClass: failure.failureClass,
                            statusCode: failure.statusCode,
                            errorDomain: underlyingError?.domain,
                            errorCode: underlyingError?.code,
                            loopbackProxySafeApplied: self.upstreamTransportPolicy.loopbackProxySafeApplied
                        )
                    )
                    if case .accountStatus(let statusCode) = failure {
                        let statusPolicy = self.gatewayStatusPolicy(
                            statusCode: statusCode,
                            response: nil,
                            account: account
                        )
                        if statusPolicy.shouldRuntimeBlockAccount {
                            self.runtimeBlockAccount(
                                account,
                                suggestedRetryAt: statusPolicy.runtimeBlockRetryAt.flatMap { Date(timeIntervalSince1970: $0) }
                            )
                        }
                    }
                    if failure.failoverDisposition == .failover,
                       canTryNextCandidate {
                        self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                        continue
                    }
                    if error is OpenAIAccountGatewayPreBytePOSTFailure,
                       self.shouldAttemptStickyContextRecovery(
                            failure: failure,
                            snapshot: snapshot,
                            stickyKey: stickyKey,
                            failedAccountID: account.accountId,
                            candidateIndex: index,
                            candidateCount: candidates.count,
                            usedStickyContextRecovery: usedStickyContextRecovery
                       ) {
                        usedStickyContextRecovery = true
                        continue
                    }
                    return onSyntheticGatewayFailure()
                }
            } catch {
                let failure: OpenAIAccountGatewayUpstreamFailure
                if let preByteFailure = error as? OpenAIAccountGatewayPreBytePOSTFailure {
                    failure = preByteFailure.failure
                } else {
                    failure = self.classifyPOSTFailure(error)
                }
                let underlyingError = failure.underlyingError as NSError?
                self.diagnosticsReporter(
                    OpenAIAccountGatewayUpstreamFailureDiagnostic(
                        route: route.diagnosticName,
                        failureClass: failure.failureClass,
                        statusCode: failure.statusCode,
                        errorDomain: underlyingError?.domain,
                        errorCode: underlyingError?.code,
                        loopbackProxySafeApplied: self.upstreamTransportPolicy.loopbackProxySafeApplied
                    )
                )
                if case .accountStatus(let statusCode) = failure {
                    let statusPolicy = self.gatewayStatusPolicy(
                        statusCode: statusCode,
                        response: nil,
                        account: account
                    )
                    if statusPolicy.shouldRuntimeBlockAccount {
                        self.runtimeBlockAccount(
                            account,
                            suggestedRetryAt: statusPolicy.runtimeBlockRetryAt.flatMap { Date(timeIntervalSince1970: $0) }
                        )
                    }
                }
                if failure.failoverDisposition == .failover,
                   canTryNextCandidate {
                    self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                    continue
                }
                if self.shouldAttemptStickyContextRecovery(
                    failure: failure,
                    snapshot: snapshot,
                    stickyKey: stickyKey,
                    failedAccountID: account.accountId,
                    candidateIndex: index,
                    candidateCount: candidates.count,
                    usedStickyContextRecovery: usedStickyContextRecovery
                ) {
                    usedStickyContextRecovery = true
                    continue
                }
                return onSyntheticGatewayFailure()
            }
        }

        return onSyntheticGatewayFailure()
    }

    private func gatewayStatusPolicy(
        statusCode: Int,
        response: HTTPURLResponse?,
        account: TokenAccount?
    ) -> PortableCoreGatewayStatusPolicyResult {
        (try? RustPortableCoreAdapter.shared.resolveGatewayStatusPolicy(
            PortableCoreGatewayStatusPolicyRequest(
                statusCode: statusCode,
                now: Date().timeIntervalSince1970,
                allowFallbackRuntimeBlock: false,
                suggestedRetryAt: nil,
                retryAfterValue: response?.value(forHTTPHeaderField: "Retry-After"),
                account: account.map(PortableCoreGatewayAccountInput.legacy(from:))
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayStatusPolicyResult.failClosed(
            statusCode: statusCode,
            now: Date().timeIntervalSince1970,
            allowFallbackRuntimeBlock: false,
            suggestedRetryAt: nil,
            retryAfterValue: response?.value(forHTTPHeaderField: "Retry-After"),
            account: account.map(PortableCoreGatewayAccountInput.legacy(from:))
        )
    }

    private func stream(
        result: (response: HTTPURLResponse, bytes: URLSession.AsyncBytes),
        account: TokenAccount,
        stickyKey: String?,
        to connection: NWConnection,
        allowInBandFailover: Bool
    ) async throws -> OpenAIAccountGatewayPOSTDisposition {
        let headerRenderRequest = PortableCoreGatewayResponseHeadRenderRequest(
            statusCode: result.response.statusCode,
            headerFields: result.response.allHeaderFields.compactMap { nameAny, valueAny in
                guard let name = nameAny as? String,
                      let value = valueAny as? String else {
                    return nil
                }
                return PortableCoreGatewayResponseHeaderFieldInput(name: name, value: value)
            }
        )
        let renderedHeaders =
            (try? RustPortableCoreAdapter.shared.renderGatewayResponseHead(
                headerRenderRequest,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayResponseHeadRenderResult.failClosed(
                request: headerRenderRequest
            )
        let headers = renderedHeaders.headerText
        let isEventStream = result.response
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/event-stream") == true
        var didSendHeaders = false
        var didAttemptDownstreamWrite = false

        var buffer = Data()
        var iterator = result.bytes.makeAsyncIterator()
        while true {
            let nextByte: UInt8?
            do {
                nextByte = try await iterator.next()
            } catch {
                if didAttemptDownstreamWrite == false {
                    throw OpenAIAccountGatewayPreBytePOSTFailure(
                        failure: self.classifyPOSTFailure(error)
                    )
                }
                throw error
            }

            guard let byte = nextByte else { break }
            buffer.append(byte)
            if didSendHeaders == false {
                let previewDecision =
                    ((try? RustPortableCoreAdapter.shared.decideGatewayProtocolPreview(
                        PortableCoreGatewayProtocolPreviewDecisionRequest(
                            payloadText: String(data: buffer, encoding: .utf8),
                            now: Date().timeIntervalSince1970,
                            byteCount: buffer.count,
                            isEventStream: isEventStream,
                            isFinal: false
                        ),
                        buildIfNeeded: false
                    )) ?? PortableCoreGatewayProtocolPreviewDecisionResult.failClosed())
                    .protocolPreviewDecision()
                switch previewDecision {
                case .needMoreData:
                    continue
                case .streamNow:
                    didAttemptDownstreamWrite = true
                    try await self.send(Data(headers.utf8), on: connection)
                    didSendHeaders = true
                case .accountSignal(let signal):
                    self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
                    self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                    if allowInBandFailover {
                        return .accountSignal(signal)
                    }
                    didAttemptDownstreamWrite = true
                    try await self.send(Data(headers.utf8), on: connection)
                    didSendHeaders = true
                }
            }
            if buffer.count >= 8192 {
                didAttemptDownstreamWrite = true
                try await self.send(buffer, on: connection)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        var bindSticky = true
        if didSendHeaders == false {
            let previewDecision =
                ((try? RustPortableCoreAdapter.shared.decideGatewayProtocolPreview(
                    PortableCoreGatewayProtocolPreviewDecisionRequest(
                        payloadText: String(data: buffer, encoding: .utf8),
                        now: Date().timeIntervalSince1970,
                        byteCount: buffer.count,
                        isEventStream: isEventStream,
                        isFinal: true
                    ),
                    buildIfNeeded: false
                )) ?? PortableCoreGatewayProtocolPreviewDecisionResult.failClosed())
                .protocolPreviewDecision()
            switch previewDecision {
            case .needMoreData, .streamNow:
                didAttemptDownstreamWrite = true
                try await self.send(Data(headers.utf8), on: connection)
                didSendHeaders = true
            case .accountSignal(let signal):
                self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
                self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                bindSticky = false
                if allowInBandFailover {
                    return .accountSignal(signal)
                }
                didAttemptDownstreamWrite = true
                try await self.send(Data(headers.utf8), on: connection)
                didSendHeaders = true
            }
        }

        if buffer.isEmpty == false {
            didAttemptDownstreamWrite = true
            try await self.send(buffer, on: connection)
        }

        let shouldBindSticky =
            ((try? RustPortableCoreAdapter.shared.decideGatewayPostCompletionBinding(
                PortableCoreGatewayPostCompletionBindingDecisionRequest(
                    allowsBinding: true,
                    usedStickyContextRecovery: false,
                    statusCode: result.response.statusCode
                ),
                buildIfNeeded: false
            )) ?? PortableCoreGatewayPostCompletionBindingDecisionResult.failClosed(
                allowsBinding: true,
                usedStickyContextRecovery: false,
                statusCode: result.response.statusCode
            )).shouldBindSticky
        let didBindSticky = bindSticky && shouldBindSticky
        if didBindSticky {
            self.bind(stickyKey: stickyKey, accountID: account.accountId)
        }

        connection.cancel()
        return .streamed(bindSticky: didBindSticky)
    }

    private func receiveClientWebSocketMessages(
        on connection: NWConnection,
        upstreamTask: URLSessionWebSocketTask,
        buffer: Data,
        fragments: WebSocketFragmentState,
        stickyKey: String?,
        accountID: String
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task {
                if let error {
                    upstreamTask.cancel(with: .goingAway, reason: nil)
                    self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                    connection.cancel()
                    NSLog("codexbar websocket receive failed: %@", error.localizedDescription)
                    return
                }

                var buffer = buffer
                if let data {
                    buffer.append(data)
                }

                var fragments = fragments
                func renderFrame(opcode: UInt8, payload: Data = Data(), isFinal: Bool = true) -> Data {
                    let request = PortableCoreGatewayWebSocketFrameRenderRequest(
                        opcode: opcode,
                        payloadBytes: Array(payload),
                        isFinal: isFinal
                    )
                    let result =
                        (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketFrame(
                            request,
                            buildIfNeeded: false
                        )) ?? PortableCoreGatewayWebSocketFrameRenderResult.failClosed(
                            request: request
                        )
                    return Data(result.frameBytes)
                }
                do {
                    frameParseLoop: while true {
                        let frameParseResult =
                            (try? RustPortableCoreAdapter.shared.parseGatewayWebSocketFrame(
                                PortableCoreGatewayWebSocketFrameParseRequest(
                                    frameBytes: Array(buffer),
                                    expectMasked: true
                                ),
                                buildIfNeeded: false
                        )) ?? PortableCoreGatewayWebSocketFrameParseResult.failClosed()
                        let frame: ParsedWebSocketFrame
                        switch frameParseResult.outcome {
                        case "needMoreData":
                            break frameParseLoop
                        case "parsed":
                            guard let parsedFrame = frameParseResult.parsedFrame else {
                                throw URLError(.cannotParseResponse)
                            }
                            buffer.removeSubrange(0..<parsedFrame.consumedByteCount)
                            frame = ParsedWebSocketFrame(portableCore: parsedFrame)
                        case "decodeError":
                            throw URLError(.cannotDecodeRawData)
                        default:
                            throw URLError(.cannotParseResponse)
                        }
                        switch frame.opcode {
                        case 0x0:
                            guard let fragmentedOpcode = fragments.opcode else {
                                throw URLError(.cannotParseResponse)
                            }
                            fragments.payload.append(frame.payload)
                            guard frame.isFinal else { continue }
                            let payload = fragments.payload
                            fragments = WebSocketFragmentState()
                            switch fragmentedOpcode {
                            case 0x1:
                                guard let text = String(data: payload, encoding: .utf8) else {
                                    throw URLError(.cannotDecodeContentData)
                                }
                                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                    upstreamTask.send(.string(text)) { error in
                                        if let error {
                                            continuation.resume(throwing: error)
                                        } else {
                                            continuation.resume()
                                        }
                                    }
                                }
                            case 0x2:
                                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                    upstreamTask.send(.data(payload)) { error in
                                        if let error {
                                            continuation.resume(throwing: error)
                                        } else {
                                            continuation.resume()
                                        }
                                    }
                                }
                            default:
                                throw URLError(.unsupportedURL)
                            }
                        case 0x1, 0x2:
                            if frame.isFinal {
                                switch frame.opcode {
                                case 0x1:
                                    guard let text = String(data: frame.payload, encoding: .utf8) else {
                                        throw URLError(.cannotDecodeContentData)
                                    }
                                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                        upstreamTask.send(.string(text)) { error in
                                            if let error {
                                                continuation.resume(throwing: error)
                                            } else {
                                                continuation.resume()
                                            }
                                        }
                                    }
                                case 0x2:
                                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                        upstreamTask.send(.data(frame.payload)) { error in
                                            if let error {
                                                continuation.resume(throwing: error)
                                            } else {
                                                continuation.resume()
                                            }
                                        }
                                    }
                                default:
                                    throw URLError(.unsupportedURL)
                                }
                            } else {
                                fragments.opcode = frame.opcode
                                fragments.payload = frame.payload
                            }
                        case 0x8:
                            let payload = frame.payload
                            try? await self.send(
                                renderFrame(opcode: 0x8, payload: payload),
                                on: connection
                            )
                            upstreamTask.cancel(with: .normalClosure, reason: payload)
                            self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                            connection.cancel()
                        case 0x9:
                            try? await self.send(
                                renderFrame(opcode: 0xA, payload: frame.payload),
                                on: connection
                            )
                        case 0xA:
                            break
                        default:
                            throw URLError(.cannotParseResponse)
                        }
                    }
                } catch {
                    let closePayloadRequest = PortableCoreGatewayWebSocketClosePayloadRequest(code: 1002)
                    let closePayloadResult =
                        (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketClosePayload(
                            closePayloadRequest,
                            buildIfNeeded: false
                        )) ?? PortableCoreGatewayWebSocketClosePayloadResult.failClosed(
                            request: closePayloadRequest
                        )
                    try? await self.send(
                        renderFrame(
                            opcode: 0x8,
                            payload: Data(closePayloadResult.payloadBytes)
                        ),
                        on: connection
                    )
                    upstreamTask.cancel(with: .protocolError, reason: nil)
                    self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                    connection.cancel()
                    return
                }

                if isComplete {
                    upstreamTask.cancel(with: .goingAway, reason: nil)
                    self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                    connection.cancel()
                    return
                }

                self.receiveClientWebSocketMessages(
                    on: connection,
                    upstreamTask: upstreamTask,
                    buffer: buffer,
                    fragments: fragments,
                    stickyKey: stickyKey,
                    accountID: accountID
                )
            }
        }
    }

    private func sendJSONResponse(on connection: NWConnection, statusCode: Int, body: String) {
        let data = Data(body.utf8)
        let head = [
            "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)",
            "Content-Type: application/json",
            "Content-Length: \(data.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

#if DEBUG
struct OpenAIAccountGatewayTestResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

extension OpenAIAccountGatewayService {
    func noteInBandAccountSignalForTesting(
        _ payload: String,
        accountID: String,
        stickyKey: String?
    ) -> Bool {
        self.handleInBandAccountSignalIfNeeded(
            text: payload,
            accountID: accountID,
            stickyKey: stickyKey
        )
    }

    func establishResponsesWebSocketProbeForTesting(
        request: ParsedGatewayRequest,
        bindOnSuccess: Bool = false,
        attempt: (_ account: TokenAccount, _ requestedProtocol: String?, _ readyBudget: TimeInterval) async throws
            -> String?
    ) async throws -> (accountID: String, selectedProtocol: String?) {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["sec-websocket-key"]?.isEmpty == false else {
            throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badURL))
        }

        let stickyKeyRequest = PortableCoreGatewayStickyKeyResolutionRequest(
            sessionID: request.headers["session_id"],
            windowID: request.headers["x-codex-window-id"]
        )
        let stickyKey =
            ((try? RustPortableCoreAdapter.shared.resolveGatewayStickyKey(
                stickyKeyRequest,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayStickyKeyResolutionResult.failClosed(
                request: stickyKeyRequest
            )).stickyKey
        let established = try await self.routeUpstreamWebSocketCandidate(
            request: request,
            stickyKey: stickyKey
        ) { account, requestedProtocol, readyBudget in
            let selectedProtocol = try await attempt(account, requestedProtocol, readyBudget)
            return ((), selectedProtocol)
        }

        if bindOnSuccess {
            self.bind(stickyKey: stickyKey, accountID: established.account.accountId)
        }

        return (established.account.accountId, established.selectedProtocol)
    }

    func postResponsesProbeForTesting(
        request: ParsedGatewayRequest,
        forcedConsumptionFailure: Error? = nil
    ) async throws -> OpenAIAccountGatewayTestResponse {
        guard let route = OpenAIAccountGatewayResponsesRoute(requestPath: request.path) else {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"not found"}}"#.utf8)
            )
        }

        return await self.routePOSTResponsesCandidates(
            request,
            route: route,
            onNoCandidates: {
                OpenAIAccountGatewayTestResponse(
                    statusCode: 503,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#.utf8)
                )
            },
            onSyntheticGatewayFailure: {
                OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#.utf8)
                )
            }
        ) { response, bytes, account, stickyKey, allowInBandFailover, _ in
            if let forcedConsumptionFailure {
                throw forcedConsumptionFailure
            }
            var body = Data()
            var iterator = bytes.makeAsyncIterator()
            while true {
                let nextByte: UInt8?
                do {
                    nextByte = try await iterator.next()
                } catch {
                    if body.isEmpty {
                        throw OpenAIAccountGatewayPreBytePOSTFailure(
                            failure: self.classifyPOSTFailure(error)
                        )
                    }
                    throw error
                }

                guard let byte = nextByte else { break }
                body.append(byte)
            }
            let trimmed = (String(data: body, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let signal =
                trimmed.isEmpty
                ? nil
                : ((try? RustPortableCoreAdapter.shared.interpretGatewayProtocolSignal(
                    PortableCoreGatewayProtocolSignalInterpretationRequest(
                        payloadText: trimmed,
                        now: Date().timeIntervalSince1970
                    ),
                    buildIfNeeded: false
                )) ?? PortableCoreGatewayProtocolSignalInterpretationResult.failClosed())
                .accountProtocolSignal()
            if let signal {
                self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
                self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                if allowInBandFailover {
                    return .retryNextCandidate
                }
                let errorPayload: [String: Any] = [
                    "error": ["message": signal.message ?? "You've hit your usage limit."]
                ]
                let errorBody = (
                    try? JSONSerialization.data(withJSONObject: errorPayload)
                ).flatMap { String(data: $0, encoding: .utf8) }
                    ?? #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
                return .completed(
                    OpenAIAccountGatewayTestResponse(
                        statusCode: 429,
                        headers: ["Content-Type": "application/json", "Connection": "close"],
                        body: Data(errorBody.utf8)
                    ),
                    bindSticky: false,
                    alreadyBound: false
                )
            }

            let headerRenderRequest = PortableCoreGatewayResponseHeadRenderRequest(
                statusCode: response.statusCode,
                headerFields: response.allHeaderFields.compactMap { nameAny, valueAny in
                    guard let name = nameAny as? String,
                          let value = valueAny as? String else {
                        return nil
                    }
                    return PortableCoreGatewayResponseHeaderFieldInput(name: name, value: value)
                }
            )
            let renderedHeaders =
                (try? RustPortableCoreAdapter.shared.renderGatewayResponseHead(
                    headerRenderRequest,
                    buildIfNeeded: false
                )) ?? PortableCoreGatewayResponseHeadRenderResult.failClosed(
                    request: headerRenderRequest
                )
            return .completed(
                OpenAIAccountGatewayTestResponse(
                    statusCode: response.statusCode,
                    headers: Dictionary(
                        uniqueKeysWithValues: renderedHeaders.filteredHeaders.map { ($0.name, $0.value) }
                    ),
                    body: body
                ),
                bindSticky: true,
                alreadyBound: false
            )
        }
    }

}
#endif
