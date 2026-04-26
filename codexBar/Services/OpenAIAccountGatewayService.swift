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
        guard self.boolValue(settings[kind.enableKey]) == true,
              let host = (settings[kind.hostKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              let port = self.intValue(settings[kind.portKey]),
              port > 0 else {
            return nil
        }

        return OpenAIAccountGatewaySystemProxyEndpoint(
            kind: String(describing: kind),
            host: host,
            port: port
        )
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as Int:
            return value != 0
        case let value as String:
            return Int(value).map { $0 != 0 }
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
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

    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        self.resolvedURLSessionConfiguration().configuration
    }

    func resolvedTransportPolicy() -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        let snapshot = self.proxySnapshotProvider()
        let snapshotDTO = PortableCoreGatewayProxySnapshot.legacy(from: snapshot)
        let result = (try? RustPortableCoreAdapter.shared.resolveGatewayTransportPolicy(
            PortableCoreGatewayTransportPolicyRequest(
                proxyResolutionMode: self.proxyResolutionMode == .loopbackProxySafe ? "loopbackProxySafe" : "systemDefault",
                systemProxySnapshot: snapshotDTO
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayTransportPolicyResult.failClosed(
            proxyResolutionMode: self.proxyResolutionMode == .loopbackProxySafe ? "loopbackProxySafe" : "systemDefault",
            systemProxySnapshot: snapshotDTO
        )
        return result.resolvedPolicy()
    }

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
        let policy = self.resolvedTransportPolicy()
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
        diagnosticsReporter: @escaping (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void = OpenAIAccountGatewayService.liveDiagnosticsReporter
    ) {
        let resolvedTransportConfiguration = upstreamTransportConfiguration.resolvedURLSessionConfiguration()
        self.urlSession = urlSession ?? Self.makeDedicatedUpstreamSession(using: resolvedTransportConfiguration.configuration)
        self.upstreamTransportConfiguration = upstreamTransportConfiguration
        self.upstreamTransportPolicy = resolvedTransportConfiguration.policy
        self.runtimeConfiguration = runtimeConfiguration
        self.routeJournalStore = routeJournalStore
        self.diagnosticsReporter = diagnosticsReporter
    }

    private static func makeDedicatedUpstreamSession(
        using configuration: URLSessionConfiguration
    ) -> URLSession {
        URLSession(configuration: configuration)
    }

    nonisolated private static func liveDiagnosticsReporter(
        _ diagnostic: OpenAIAccountGatewayUpstreamFailureDiagnostic
    ) {
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

            if let request = self.parseRequest(from: combined) {
                self.handle(request: request, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, accumulated: combined)
        }
    }

    private func parseRequest(from data: Data) -> ParsedGatewayRequest? {
        guard let requestText = String(data: data, encoding: .utf8) else { return nil }
        let result =
            (try? RustPortableCoreAdapter.shared.parseGatewayRequest(
                PortableCoreGatewayRequestParseRequest(rawText: requestText),
                buildIfNeeded: false
            )) ?? PortableCoreGatewayRequestParseResult.failClosed()
        guard let parsedRequest = result.parsedRequest else { return nil }
        return ParsedGatewayRequest(portableCore: parsedRequest)
    }

    private func handle(request: ParsedGatewayRequest, on connection: NWConnection) {
        switch (request.method.uppercased(), request.path) {
        case ("GET", "/v1/responses"):
            Task {
                await self.handleResponsesWebSocketUpgrade(request: request, on: connection)
            }
        case ("POST", "/v1/responses"):
            Task {
                await self.forwardResponsesRequest(request, on: connection, route: .responses)
            }
        case ("POST", "/v1/responses/compact"):
            Task {
                await self.forwardResponsesRequest(request, on: connection, route: .compact)
            }
        default:
            self.sendJSONResponse(
                on: connection,
                statusCode: 404,
                body: #"{"error":{"message":"not found"}}"#
            )
        }
    }

    private func handleResponsesWebSocketUpgrade(
        request: ParsedGatewayRequest,
        on connection: NWConnection
    ) async {
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

        let stickyKey = self.stickySessionKey(for: request.headers)
        do {
            let established = try await self.establishUpstreamWebSocket(
                request: request,
                stickyKey: stickyKey
            )
            self.bind(stickyKey: stickyKey, accountID: established.account.accountId)
            let response = self.webSocketHandshakeResponse(
                for: secKey,
                selectedProtocol: established.selectedProtocol
            )
            try await self.send(Data(response.responseText.utf8), on: connection)

            self.pipeUpstreamMessages(
                upstreamTask: established.task,
                to: connection,
                stickyKey: stickyKey,
                accountID: established.account.accountId
            )
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

    private func snapshot() -> OpenAIAccountGatewaySnapshot {
        self.stateQueue.sync {
            OpenAIAccountGatewaySnapshot(
                accounts: self.accounts,
                quotaSortSettings: self.quotaSortSettings,
                accountUsageMode: self.accountUsageMode,
                stickyBindings: self.stickyBindings,
                runtimeBlockedUntilByAccountID: self.runtimeBlockedAccounts.mapValues(\.retryAt)
            )
        }
    }

    private func stickySessionKey(for headers: [String: String]) -> String? {
        let request = PortableCoreGatewayStickyKeyResolutionRequest(
            sessionID: headers["session_id"],
            windowID: headers["x-codex-window-id"]
        )
        let result =
            (try? RustPortableCoreAdapter.shared.resolveGatewayStickyKey(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayStickyKeyResolutionResult.failClosed(
                request: request
            )
        return result.stickyKey
    }

    private func candidates(for snapshot: OpenAIAccountGatewaySnapshot, stickyKey: String?) -> [TokenAccount] {
        let now = Date()
        let request = PortableCoreGatewayCandidatePlanRequest(
            accountUsageMode: snapshot.accountUsageMode.rawValue,
            now: now.timeIntervalSince1970,
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
        let plan =
            (try? RustPortableCoreAdapter.shared.planGatewayCandidates(request)) ??
            PortableCoreGatewayCandidatePlanResult.failClosed()
        let accountByID = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.accountId, $0) })
        return plan.accountIds.compactMap { accountByID[$0] }
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
        let retryAt = self.resolvedRuntimeBlockRetryAt(
            for: account,
            suggestedRetryAt: suggestedRetryAt
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

    private func resolvedRuntimeBlockRetryAt(
        for account: TokenAccount,
        suggestedRetryAt: Date?
    ) -> Date {
        let now = Date()
        let result =
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
        let retryAt = result.runtimeBlockRetryAt ?? (suggestedRetryAt?.timeIntervalSince1970 ?? now.addingTimeInterval(10 * 60).timeIntervalSince1970)
        return Date(timeIntervalSince1970: retryAt)
    }

    private func handleInBandAccountSignalIfNeeded(
        text: String,
        accountID: String,
        stickyKey: String?
    ) -> Bool {
        guard let signal = self.accountProtocolSignal(in: text),
              let account = self.account(withID: accountID) else {
            return false
        }

        self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
        self.clearBinding(stickyKey: stickyKey, accountID: accountID)
        return true
    }

    private func account(withID accountID: String) -> TokenAccount? {
        self.stateQueue.sync {
            self.accounts.first(where: { $0.accountId == accountID })
        }
    }

    private func forwardResponsesRequest(
        _ request: ParsedGatewayRequest,
        on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute
    ) async {
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

    private func proxyPOSTResponses(
        _ request: ParsedGatewayRequest,
        account: TokenAccount,
        route: OpenAIAccountGatewayResponsesRoute
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        let normalizedBody = self.normalizeRequestBody(request.body, route: route)
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

        return (httpResponse, bytes)
    }

    private func normalizeRequestBody(_ body: Data, route: OpenAIAccountGatewayResponsesRoute) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return body
        }
        let bodyJson = JSONValue(any: object)
        let result =
            (try? RustPortableCoreAdapter.shared.normalizeOpenAIResponsesRequest(
                PortableCoreOpenAIResponsesRequestNormalizationRequest(
                    route: route == .compact ? "/v1/responses/compact" : "/v1/responses",
                    bodyJson: bodyJson
                ),
                buildIfNeeded: false
            )) ?? PortableCoreOpenAIResponsesRequestNormalizationResult.failClosed(bodyJson: bodyJson)
        guard let normalized = result.normalizedJson.anyValue as? [String: Any],
              JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(withJSONObject: normalized) else {
            return body
        }
        return data
    }

    private func makeUpstreamWebSocketTask(
        request: ParsedGatewayRequest,
        account: TokenAccount
    ) throws -> URLSessionWebSocketTask {
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
        return task
    }

    private func routeUpstreamWebSocketCandidate<TaskType>(
        request: ParsedGatewayRequest,
        stickyKey: String?,
        attempt: (_ account: TokenAccount, _ requestedProtocol: String?, _ readyBudget: TimeInterval) async throws
            -> (task: TaskType, selectedProtocol: String?)
    ) async throws -> (task: TaskType, account: TokenAccount, selectedProtocol: String?) {
        let snapshot = self.snapshot()
        let candidates = self.candidates(for: snapshot, stickyKey: stickyKey)
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
                let failure = self.classifyWebSocketFailure(error)
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

    private func establishUpstreamWebSocket(
        request: ParsedGatewayRequest,
        stickyKey: String?
    ) async throws -> (task: URLSessionWebSocketTask, account: TokenAccount, selectedProtocol: String?) {
        try await self.routeUpstreamWebSocketCandidate(request: request, stickyKey: stickyKey) {
            account,
            requestedProtocol,
            readyBudget in
            let task = try self.makeUpstreamWebSocketTask(request: request, account: account)
            do {
                let selectedProtocol = try await self.awaitUpstreamWebSocketReady(
                    task,
                    requestedProtocol: requestedProtocol,
                    readyBudget: readyBudget
                )
                return (task, selectedProtocol)
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                throw error
            }
        }
    }

    private func awaitUpstreamWebSocketReady(
        _ task: URLSessionWebSocketTask,
        requestedProtocol: String?,
        readyBudget: TimeInterval
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                do {
                    try await self.sendPing(on: task)
                } catch {
                    throw self.classifyWebSocketReadyFailure(error, response: task.response)
                }
                return try self.validateUpstreamWebSocketHandshake(
                    task.response,
                    requestedProtocol: requestedProtocol
                )
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
    }

    private func sendPing(on task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated private func webSocketReadyValidationResult(
        response: URLResponse?,
        requestedProtocol: String?,
        readyErrorOccurred: Bool
    ) -> PortableCoreGatewayWebSocketReadyValidationResult {
        let httpResponse = response as? HTTPURLResponse
        let request = PortableCoreGatewayWebSocketReadyValidationRequest(
            hasHTTPResponse: httpResponse != nil,
            responseStatusCode: httpResponse?.statusCode,
            requestedProtocol: requestedProtocol,
            negotiatedProtocol: httpResponse?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"),
            readyErrorOccurred: readyErrorOccurred
        )
        return
            (try? RustPortableCoreAdapter.shared.validateGatewayWebSocketReady(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayWebSocketReadyValidationResult.failClosed(
                request: request
            )
    }

    nonisolated private func validateUpstreamWebSocketHandshake(
        _ response: URLResponse?,
        requestedProtocol: String?
    ) throws -> String? {
        let result = self.webSocketReadyValidationResult(
            response: response,
            requestedProtocol: requestedProtocol,
            readyErrorOccurred: false
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

    nonisolated private func classifyPOSTFailure(_ error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        if let failure = error as? OpenAIAccountGatewayUpstreamFailure {
            return failure
        }
        return self.gatewayTransportFailure(
            error: error,
            allowProtocolViolation: true
        )
    }

    nonisolated private func classifyWebSocketFailure(_ error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        if let failure = error as? OpenAIAccountGatewayUpstreamFailure {
            return failure
        }
        return self.gatewayTransportFailure(
            error: error,
            allowProtocolViolation: false
        )
    }

    nonisolated private func classifyWebSocketReadyFailure(
        _ error: Error,
        response: URLResponse?
    ) -> OpenAIAccountGatewayUpstreamFailure {
        if let failure = error as? OpenAIAccountGatewayUpstreamFailure {
            return failure
        }

        let result = self.webSocketReadyValidationResult(
            response: response,
            requestedProtocol: nil,
            readyErrorOccurred: true
        )
        switch result.outcome {
        case OpenAIAccountGatewayFailureClass.accountStatus.rawValue:
            return .accountStatus(result.statusCode ?? 401)
        case OpenAIAccountGatewayFailureClass.upstreamStatus.rawValue:
            return .upstreamStatus(result.statusCode ?? 502)
        case OpenAIAccountGatewayFailureClass.protocolViolation.rawValue:
            return .protocolViolation(error)
        default:
            return .transport(error)
        }
    }

    private func resolvedPOSTFailure(from error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        if let preByteFailure = error as? OpenAIAccountGatewayPreBytePOSTFailure {
            return preByteFailure.failure
        }
        return self.classifyPOSTFailure(error)
    }

    nonisolated private func gatewayTransportFailure(
        error: Error,
        allowProtocolViolation: Bool
    ) -> OpenAIAccountGatewayUpstreamFailure {
        let nsError = error as NSError
        let request = PortableCoreGatewayTransportFailureClassificationRequest(
            errorDomain: nsError.domain,
            errorCode: nsError.code,
            allowProtocolViolation: allowProtocolViolation
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
        let snapshot = self.snapshot()
        let stickyKey = self.stickySessionKey(for: request.headers)
        let candidates = self.candidates(for: snapshot, stickyKey: stickyKey)
        var usedStickyContextRecovery = false

        guard candidates.isEmpty == false else {
            return onNoCandidates()
        }

        for (index, account) in candidates.enumerated() {
            let canTryNextCandidate = usedStickyContextRecovery == false && index < candidates.count - 1
            do {
                let result = try await self.proxyPOSTResponses(request, account: account, route: route)
                let statusPolicy = self.gatewayStatusPolicy(
                    statusCode: result.response.statusCode,
                    response: result.response,
                    account: account
                )
                let responseFailure = statusPolicy.gatewayFailure(statusCode: result.response.statusCode)
                if let failure = responseFailure {
                    self.diagnosticsReporter(
                        self.makePOSTFailureDiagnostic(route: route, failure: failure)
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
                        if alreadyBound == false && self.shouldBindStickyAfterPOSTCompletion(
                            response: result.response,
                            usedStickyContextRecovery: usedStickyContextRecovery,
                            allowsBinding: bindSticky
                        ) {
                            self.bind(stickyKey: stickyKey, accountID: account.accountId)
                        }
                        return success
                    case .retryNextCandidate:
                        continue
                    }
                } catch {
                    let failure = self.resolvedPOSTFailure(from: error)
                    self.diagnosticsReporter(
                        self.makePOSTFailureDiagnostic(route: route, failure: failure)
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
                let failure = self.resolvedPOSTFailure(from: error)
                self.diagnosticsReporter(
                    self.makePOSTFailureDiagnostic(route: route, failure: failure)
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

    private func shouldBindStickyAfterPOSTCompletion(
        response: HTTPURLResponse,
        usedStickyContextRecovery: Bool,
        allowsBinding: Bool
    ) -> Bool {
        let result =
            (try? RustPortableCoreAdapter.shared.decideGatewayPostCompletionBinding(
                PortableCoreGatewayPostCompletionBindingDecisionRequest(
                    allowsBinding: allowsBinding,
                    usedStickyContextRecovery: usedStickyContextRecovery,
                    statusCode: response.statusCode
                ),
                buildIfNeeded: false
            )) ?? PortableCoreGatewayPostCompletionBindingDecisionResult.failClosed(
                allowsBinding: allowsBinding,
                usedStickyContextRecovery: usedStickyContextRecovery,
                statusCode: response.statusCode
            )
        return result.shouldBindSticky
    }

    private func makePOSTFailureDiagnostic(
        route: OpenAIAccountGatewayResponsesRoute,
        failure: OpenAIAccountGatewayUpstreamFailure
    ) -> OpenAIAccountGatewayUpstreamFailureDiagnostic {
        let underlyingError = failure.underlyingError as NSError?
        return OpenAIAccountGatewayUpstreamFailureDiagnostic(
            route: route.diagnosticName,
            failureClass: failure.failureClass,
            statusCode: failure.statusCode,
            errorDomain: underlyingError?.domain,
            errorCode: underlyingError?.code,
            loopbackProxySafeApplied: self.upstreamTransportPolicy.loopbackProxySafeApplied
        )
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
        let headers = self.renderResponseHeaders(from: result.response)
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
                switch self.protocolPreviewDecision(
                    buffer: buffer,
                    isEventStream: isEventStream,
                    isFinal: false
                ) {
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
            switch self.protocolPreviewDecision(
                buffer: buffer,
                isEventStream: isEventStream,
                isFinal: true
            ) {
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

        let didBindSticky =
            bindSticky &&
            self.shouldBindStickyAfterPOSTCompletion(
                response: result.response,
                usedStickyContextRecovery: false,
                allowsBinding: true
            )
        if didBindSticky {
            self.bind(stickyKey: stickyKey, accountID: account.accountId)
        }

        connection.cancel()
        return .streamed(bindSticky: didBindSticky)
    }

    private func protocolPreviewDecision(
        buffer: Data,
        isEventStream: Bool,
        isFinal: Bool
    ) -> OpenAIAccountGatewayProtocolPreviewDecision {
        let result =
            (try? RustPortableCoreAdapter.shared.decideGatewayProtocolPreview(
            PortableCoreGatewayProtocolPreviewDecisionRequest(
                payloadText: String(data: buffer, encoding: .utf8),
                now: Date().timeIntervalSince1970,
                byteCount: buffer.count,
                isEventStream: isEventStream,
                isFinal: isFinal
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayProtocolPreviewDecisionResult.failClosed()
        return result.protocolPreviewDecision()
    }

    private func accountProtocolSignal(in payload: String) -> OpenAIAccountProtocolSignal? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let interpreted =
            (try? RustPortableCoreAdapter.shared.interpretGatewayProtocolSignal(
            PortableCoreGatewayProtocolSignalInterpretationRequest(
                payloadText: trimmed,
                now: Date().timeIntervalSince1970
            ),
            buildIfNeeded: false
        )) ?? PortableCoreGatewayProtocolSignalInterpretationResult.failClosed()
        return interpreted.accountProtocolSignal()
    }

    private func renderResponseHeaders(from response: HTTPURLResponse) -> String {
        let request = PortableCoreGatewayResponseHeadRenderRequest(
            statusCode: response.statusCode,
            headerFields: response.allHeaderFields.compactMap { nameAny, valueAny in
                guard let name = nameAny as? String,
                      let value = valueAny as? String else {
                    return nil
                }
                return PortableCoreGatewayResponseHeaderFieldInput(name: name, value: value)
            }
        )
        let result =
            (try? RustPortableCoreAdapter.shared.renderGatewayResponseHead(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayResponseHeadRenderResult.failClosed(
                request: request
            )
        return result.headerText
    }

    private func webSocketHandshakeResponse(
        for secWebSocketKey: String,
        selectedProtocol: String? = nil
    ) -> PortableCoreGatewayWebSocketHandshakeResult {
        let request = PortableCoreGatewayWebSocketHandshakeRequest(
            secWebSocketKey: secWebSocketKey,
            selectedProtocol: selectedProtocol
        )
        return
            (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketHandshake(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayWebSocketHandshakeResult.failClosed(
                request: request
            )
    }

    private func webSocketFrameData(
        opcode: UInt8,
        payload: Data = Data(),
        isFinal: Bool = true
    ) -> Data {
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

    private func webSocketClosePayload(code: UInt16) -> Data {
        let request = PortableCoreGatewayWebSocketClosePayloadRequest(code: code)
        let result =
            (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketClosePayload(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayWebSocketClosePayloadResult.failClosed(
                request: request
            )
        return Data(result.payloadBytes)
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
                do {
                    while let frame = try self.parseNextWebSocketFrame(from: &buffer) {
                        try await self.handleClientWebSocketFrame(
                            frame,
                            fragments: &fragments,
                            connection: connection,
                            upstreamTask: upstreamTask,
                            stickyKey: stickyKey,
                            accountID: accountID
                        )
                    }
                } catch {
                    try? await self.send(
                        self.webSocketFrameData(
                            opcode: 0x8,
                            payload: self.webSocketClosePayload(code: 1002)
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

    private func handleClientWebSocketFrame(
        _ frame: ParsedWebSocketFrame,
        fragments: inout WebSocketFragmentState,
        connection: NWConnection,
        upstreamTask: URLSessionWebSocketTask,
        stickyKey: String?,
        accountID: String
    ) async throws {
        switch frame.opcode {
        case 0x0:
            guard let fragmentedOpcode = fragments.opcode else {
                throw URLError(.cannotParseResponse)
            }
            fragments.payload.append(frame.payload)
            guard frame.isFinal else { return }
            let payload = fragments.payload
            fragments = WebSocketFragmentState()
            try await self.forwardWebSocketMessage(
                opcode: fragmentedOpcode,
                payload: payload,
                upstreamTask: upstreamTask
            )
        case 0x1, 0x2:
            if frame.isFinal {
                try await self.forwardWebSocketMessage(
                    opcode: frame.opcode,
                    payload: frame.payload,
                    upstreamTask: upstreamTask
                )
            } else {
                fragments.opcode = frame.opcode
                fragments.payload = frame.payload
            }
        case 0x8:
            let payload = frame.payload
            try? await self.send(
                self.webSocketFrameData(opcode: 0x8, payload: payload),
                on: connection
            )
            upstreamTask.cancel(with: .normalClosure, reason: payload)
            self.clearBinding(stickyKey: stickyKey, accountID: accountID)
            connection.cancel()
        case 0x9:
            try? await self.send(
                self.webSocketFrameData(opcode: 0xA, payload: frame.payload),
                on: connection
            )
        case 0xA:
            break
        default:
            throw URLError(.cannotParseResponse)
        }
    }

    private func forwardWebSocketMessage(
        opcode: UInt8,
        payload: Data,
        upstreamTask: URLSessionWebSocketTask
    ) async throws {
        switch opcode {
        case 0x1:
            guard let text = String(data: payload, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            try await self.sendUpstreamWebSocketMessage(.string(text), on: upstreamTask)
        case 0x2:
            try await self.sendUpstreamWebSocketMessage(.data(payload), on: upstreamTask)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func sendUpstreamWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(message) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func pipeUpstreamMessages(
        upstreamTask: URLSessionWebSocketTask,
        to connection: NWConnection,
        stickyKey: String?,
        accountID: String
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    let message = try await upstreamTask.receive()
                    let frame: Data
                    switch message {
                    case .string(let text):
                        _ = self.handleInBandAccountSignalIfNeeded(
                            text: text,
                            accountID: accountID,
                            stickyKey: stickyKey
                        )
                        frame = self.webSocketFrameData(opcode: 0x1, payload: Data(text.utf8))
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            _ = self.handleInBandAccountSignalIfNeeded(
                                text: text,
                                accountID: accountID,
                                stickyKey: stickyKey
                            )
                        }
                        frame = self.webSocketFrameData(opcode: 0x2, payload: data)
                    @unknown default:
                        frame = self.webSocketFrameData(
                            opcode: 0x8,
                            payload: self.webSocketClosePayload(code: 1011)
                        )
                    }
                    try await self.send(frame, on: connection)
                }
            } catch {
                try? await self.send(
                    self.webSocketFrameData(
                        opcode: 0x8,
                        payload: self.webSocketClosePayload(code: 1000)
                    ),
                    on: connection
                )
                upstreamTask.cancel(with: .goingAway, reason: nil)
                self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                connection.cancel()
            }
        }
    }

    private func parseNextWebSocketFrame(from buffer: inout Data) throws -> ParsedWebSocketFrame? {
        let result =
            (try? RustPortableCoreAdapter.shared.parseGatewayWebSocketFrame(
                PortableCoreGatewayWebSocketFrameParseRequest(
                    frameBytes: Array(buffer),
                    expectMasked: true
                ),
                buildIfNeeded: false
            )) ?? PortableCoreGatewayWebSocketFrameParseResult.failClosed()
        switch result.outcome {
        case "needMoreData":
            return nil
        case "parsed":
            guard let frame = result.parsedFrame else {
                throw URLError(.cannotParseResponse)
            }
            buffer.removeSubrange(0..<frame.consumedByteCount)
            return ParsedWebSocketFrame(portableCore: frame)
        case "decodeError":
            throw URLError(.cannotDecodeRawData)
        default:
            throw URLError(.cannotParseResponse)
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
    func currentRoutedAccountIDForTesting() -> String? {
        self.currentRoutedAccountID()
    }

    func runtimeBlockedUntilForTesting(accountID: String) -> Date? {
        self.snapshot().runtimeBlockedUntilByAccountID[accountID]
    }

    func usesDedicatedUpstreamSessionForTesting() -> Bool {
        self.urlSession !== URLSession.shared
    }

    func upstreamTransportConfigurationForTesting() -> OpenAIAccountGatewayUpstreamTransportConfiguration {
        self.upstreamTransportConfiguration
    }

    func upstreamTransportPolicyForTesting() -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        self.upstreamTransportPolicy
    }

    func classifyPOSTFailureForTesting(_ error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        self.classifyPOSTFailure(error)
    }

    func upstreamFailureDiagnosticForTesting(
        routePath: String,
        failure: OpenAIAccountGatewayUpstreamFailure
    ) -> OpenAIAccountGatewayUpstreamFailureDiagnostic? {
        guard let route = OpenAIAccountGatewayResponsesRoute(requestPath: routePath) else {
            return nil
        }
        return self.makePOSTFailureDiagnostic(route: route, failure: failure)
    }

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

    func parseRequestForTesting(from data: Data) -> ParsedGatewayRequest? {
        self.parseRequest(from: data)
    }

    func stickySessionKeyForTesting(headers: [String: String]) -> String? {
        self.stickySessionKey(for: headers)
    }

    func webSocketUpgradeProbeForTesting(
        request: ParsedGatewayRequest
    ) -> OpenAIAccountGatewayTestResponse {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              let secKey = request.headers["sec-websocket-key"],
              secKey.isEmpty == false else {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"websocket upgrade headers are missing"}}"#.utf8)
            )
        }

        let snapshot = self.snapshot()
        let stickyKey = self.stickySessionKey(for: request.headers)
        guard let account = self.candidates(for: snapshot, stickyKey: stickyKey).first else {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#.utf8)
            )
        }

        self.bind(stickyKey: stickyKey, accountID: account.accountId)
        let handshake = self.webSocketHandshakeResponse(for: secKey)
        return OpenAIAccountGatewayTestResponse(
            statusCode: 101,
            headers: handshake.headerDictionary(),
            body: Data()
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

        let stickyKey = self.stickySessionKey(for: request.headers)
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
        request: ParsedGatewayRequest
    ) async throws -> OpenAIAccountGatewayTestResponse {
        try await self.bufferedResponsesRequestForTesting(request)
    }

    func postResponsesConsumeFailureProbeForTesting(
        request: ParsedGatewayRequest,
        failure: Error
    ) async -> OpenAIAccountGatewayTestResponse {
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
        ) { _, _, _, _, _, _ in
            throw failure
        }
    }

    private func bufferedResponsesRequestForTesting(
        _ request: ParsedGatewayRequest
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
            let body = try await self.readAllBytesForTesting(from: bytes)
            if let signal = self.accountProtocolSignal(in: String(data: body, encoding: .utf8) ?? "") {
                self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
                self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                if allowInBandFailover {
                    return .retryNextCandidate
                }
                return .completed(
                    OpenAIAccountGatewayTestResponse(
                        statusCode: 429,
                        headers: ["Content-Type": "application/json", "Connection": "close"],
                        body: Data(
                            self.gatewayErrorBody(
                                message: signal.message ?? "You've hit your usage limit."
                            ).utf8
                        )
                    ),
                    bindSticky: false,
                    alreadyBound: false
                )
            }

            return .completed(
                OpenAIAccountGatewayTestResponse(
                    statusCode: response.statusCode,
                    headers: self.responseHeadersForTesting(from: response),
                    body: body
                ),
                bindSticky: true,
                alreadyBound: false
            )
        }
    }

    private func responseHeadersForTesting(from response: HTTPURLResponse) -> [String: String] {
        let request = PortableCoreGatewayResponseHeadRenderRequest(
            statusCode: response.statusCode,
            headerFields: response.allHeaderFields.compactMap { nameAny, valueAny in
                guard let name = nameAny as? String,
                      let value = valueAny as? String else {
                    return nil
                }
                return PortableCoreGatewayResponseHeaderFieldInput(name: name, value: value)
            }
        )
        let result =
            (try? RustPortableCoreAdapter.shared.renderGatewayResponseHead(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreGatewayResponseHeadRenderResult.failClosed(
                request: request
            )
        return Dictionary(
            uniqueKeysWithValues: result.filteredHeaders.map { ($0.name, $0.value) }
        )
    }

    private func gatewayErrorBody(message: String) -> String {
        let payload: [String: Any] = ["error": ["message": message]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else {
            return #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
        }
        return body
    }

    private func readAllBytesForTesting(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        var iterator = bytes.makeAsyncIterator()
        while true {
            let nextByte: UInt8?
            do {
                nextByte = try await iterator.next()
            } catch {
                if data.isEmpty {
                    throw OpenAIAccountGatewayPreBytePOSTFailure(
                        failure: self.classifyPOSTFailure(error)
                    )
                }
                throw error
            }

            guard let byte = nextByte else { break }
            data.append(byte)
        }
        return data
    }
}
#endif
