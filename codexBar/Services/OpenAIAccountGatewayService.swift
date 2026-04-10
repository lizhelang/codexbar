import CryptoKit
import Foundation
import Network

protocol OpenAIAccountGatewayControlling: AnyObject {
    func startIfNeeded()
    func stop()
    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    )
}

enum OpenAIAccountGatewayConfiguration {
    static let host = "127.0.0.1"
    static let port: UInt16 = 1456
    static let apiKey = "codexbar-local-gateway"
    static let upstreamResponsesURL = URL(string: "https://api.openai.com/v1/responses")!

    static var baseURLString: String {
        "http://\(self.host):\(self.port)/v1"
    }
}

struct OpenAIAccountGatewayRuntimeConfiguration {
    var host: String
    var port: UInt16
    var upstreamResponsesURL: URL

    static let live = OpenAIAccountGatewayRuntimeConfiguration(
        host: OpenAIAccountGatewayConfiguration.host,
        port: OpenAIAccountGatewayConfiguration.port,
        upstreamResponsesURL: OpenAIAccountGatewayConfiguration.upstreamResponsesURL
    )
}

private struct OpenAIAccountGatewaySnapshot {
    var accounts: [TokenAccount]
    var quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var stickyBindings: [String: StickyBinding]
}

private struct StickyBinding {
    let accountID: String
    let updatedAt: Date
}

struct ParsedGatewayRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct ParsedWebSocketFrame {
    let opcode: UInt8
    let payload: Data
    let isFinal: Bool
}

private struct WebSocketFragmentState {
    var opcode: UInt8?
    var payload = Data()
}

final class OpenAIAccountGatewayService: OpenAIAccountGatewayControlling {
    static let shared = OpenAIAccountGatewayService()
    nonisolated static let mockRequestBodyPropertyKey = "codexbar.mockRequestBody"

    private let listenerQueue = DispatchQueue(label: "lzl.codexbar.openai-gateway.listener")
    private let stateQueue = DispatchQueue(label: "lzl.codexbar.openai-gateway.state")
    private let urlSession: URLSession
    private let runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration

    private var listener: NWListener?
    private var accounts: [TokenAccount] = []
    private var quotaSortSettings = CodexBarOpenAISettings.QuotaSortSettings()
    private var accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount
    private var stickyBindings: [String: StickyBinding] = [:]

    init(
        urlSession: URLSession = .shared,
        runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration = .live
    ) {
        self.urlSession = urlSession
        self.runtimeConfiguration = runtimeConfiguration
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
        self.stateQueue.async {
            self.accounts = accounts
            self.quotaSortSettings = quotaSortSettings
            self.accountUsageMode = accountUsageMode
            let knownIDs = Set(accounts.map(\.accountId))
            self.stickyBindings = self.stickyBindings.filter { knownIDs.contains($0.value.accountID) }
            self.pruneStickyBindingsLocked()
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
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else { return nil }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyOffset = headerRange.upperBound
        guard data.count >= bodyOffset + contentLength else { return nil }

        let body = data.subdata(in: bodyOffset..<(bodyOffset + contentLength))
        return ParsedGatewayRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private func handle(request: ParsedGatewayRequest, on connection: NWConnection) {
        switch (request.method.uppercased(), request.path) {
        case ("GET", "/v1/responses"):
            Task {
                await self.handleResponsesWebSocketUpgrade(request: request, on: connection)
            }
        case ("POST", "/v1/responses"):
            Task {
                await self.forwardResponsesRequest(request, on: connection)
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
            let response = self.makeWebSocketHandshakeResponse(
                for: secKey,
                selectedProtocol: established.selectedProtocol
            )
            try await self.send(Data(response.utf8), on: connection)

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
                stickyBindings: self.stickyBindings
            )
        }
    }

    private func stickySessionKey(for headers: [String: String]) -> String? {
        let candidates = [
            headers["session_id"],
            headers["x-codex-window-id"],
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
    }

    private func candidates(for snapshot: OpenAIAccountGatewaySnapshot, stickyKey: String?) -> [TokenAccount] {
        guard snapshot.accountUsageMode == .aggregateGateway else { return [] }

        let usable = snapshot.accounts.filter {
            $0.isAvailableForNextUseRouting
        }
        var ordered = usable.sorted {
            OpenAIAccountListLayout.accountPrecedes(
                $0,
                $1,
                quotaSortSettings: snapshot.quotaSortSettings
            )
        }

        if let stickyKey,
           let stickyAccountID = snapshot.stickyBindings[stickyKey]?.accountID,
           let index = ordered.firstIndex(where: { $0.accountId == stickyAccountID }) {
            let stickyAccount = ordered.remove(at: index)
            ordered.insert(stickyAccount, at: 0)
        }

        return ordered
    }

    private func bind(stickyKey: String?, accountID: String) {
        guard let stickyKey, stickyKey.isEmpty == false else { return }
        self.stateQueue.sync {
            self.stickyBindings[stickyKey] = StickyBinding(
                accountID: accountID,
                updatedAt: Date()
            )
            self.pruneStickyBindingsLocked()
        }
    }

    private func clearBinding(stickyKey: String?, accountID: String) {
        guard let stickyKey, stickyKey.isEmpty == false else { return }
        self.stateQueue.sync {
            guard self.stickyBindings[stickyKey]?.accountID == accountID else { return }
            self.stickyBindings.removeValue(forKey: stickyKey)
        }
    }

    private func pruneStickyBindingsLocked() {
        let expirationInterval: TimeInterval = 60 * 60 * 6
        let cutoff = Date().addingTimeInterval(-expirationInterval)
        self.stickyBindings = self.stickyBindings.filter { $0.value.updatedAt >= cutoff }

        let maxEntries = 256
        guard self.stickyBindings.count > maxEntries else { return }
        let sortedKeys = self.stickyBindings
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .map(\.key)
        for key in sortedKeys.prefix(self.stickyBindings.count - maxEntries) {
            self.stickyBindings.removeValue(forKey: key)
        }
    }

    private func forwardResponsesRequest(_ request: ParsedGatewayRequest, on connection: NWConnection) async {
        let snapshot = self.snapshot()
        let stickyKey = self.stickySessionKey(for: request.headers)
        let candidates = self.candidates(for: snapshot, stickyKey: stickyKey)

        guard candidates.isEmpty == false else {
            self.sendJSONResponse(
                on: connection,
                statusCode: 503,
                body: #"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#
            )
            return
        }

        for (index, account) in candidates.enumerated() {
            do {
                let result = try await self.proxyPOSTResponses(request, account: account)
                if self.shouldRetry(statusCode: result.response.statusCode),
                   index < candidates.count - 1 {
                    self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                    continue
                }

                self.bind(stickyKey: stickyKey, accountID: account.accountId)
                try await self.stream(result: result, to: connection)
                return
            } catch {
                if index == candidates.count - 1 {
                    self.sendJSONResponse(
                        on: connection,
                        statusCode: 502,
                        body: #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
                    )
                }
            }
        }
    }

    private func proxyPOSTResponses(
        _ request: ParsedGatewayRequest,
        account: TokenAccount
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        var upstreamRequest = URLRequest(url: self.runtimeConfiguration.upstreamResponsesURL)
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = request.body
        let mutableRequest = (upstreamRequest as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(
            request.body,
            forKey: Self.mockRequestBodyPropertyKey,
            in: mutableRequest
        )
        upstreamRequest = mutableRequest as URLRequest

        for (name, value) in request.headers {
            switch name {
            case "host", "content-length", "authorization", "chatgpt-account-id", "connection":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "authorization")
        upstreamRequest.setValue(account.openAIAccountId, forHTTPHeaderField: "chatgpt-account-id")

        let (bytes, response) = try await self.urlSession.bytes(for: upstreamRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        return (httpResponse, bytes)
    }

    private func makeUpstreamWebSocketTask(
        request: ParsedGatewayRequest,
        account: TokenAccount
    ) throws -> URLSessionWebSocketTask {
        guard let upstreamURL = URL(string: "wss://api.openai.com\(request.path)") else {
            throw URLError(.badURL)
        }

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
                 "chatgpt-account-id":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "authorization")
        upstreamRequest.setValue(account.openAIAccountId, forHTTPHeaderField: "chatgpt-account-id")

        let task = self.urlSession.webSocketTask(with: upstreamRequest)
        task.resume()
        return task
    }

    private func establishUpstreamWebSocket(
        request: ParsedGatewayRequest,
        stickyKey: String?
    ) async throws -> (task: URLSessionWebSocketTask, account: TokenAccount, selectedProtocol: String?) {
        let snapshot = self.snapshot()
        let candidates = self.candidates(for: snapshot, stickyKey: stickyKey)
        guard candidates.isEmpty == false else {
            throw URLError(.userAuthenticationRequired)
        }

        for account in candidates {
            let task = try self.makeUpstreamWebSocketTask(request: request, account: account)
            do {
                let selectedProtocol = try await self.awaitUpstreamWebSocketReady(
                    task,
                    requestedProtocol: request.headers["sec-websocket-protocol"]
                )
                return (task, account, selectedProtocol)
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                continue
            }
        }

        throw URLError(.cannotConnectToHost)
    }

    private func awaitUpstreamWebSocketReady(
        _ task: URLSessionWebSocketTask,
        requestedProtocol: String?
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                try await self.sendPing(on: task)
                let negotiatedProtocol = (task.response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
                if let requestedProtocol,
                   requestedProtocol.isEmpty == false,
                   let negotiatedProtocol,
                   negotiatedProtocol.isEmpty {
                    throw URLError(.cannotParseResponse)
                }
                return negotiatedProtocol
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.timedOut)
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

    private func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func stream(
        result: (response: HTTPURLResponse, bytes: URLSession.AsyncBytes),
        to connection: NWConnection
    ) async throws {
        let headers = self.renderResponseHeaders(from: result.response)
        try await self.send(Data(headers.utf8), on: connection)

        var buffer = Data()
        for try await byte in result.bytes {
            buffer.append(byte)
            if buffer.count >= 8192 {
                try await self.send(buffer, on: connection)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if buffer.isEmpty == false {
            try await self.send(buffer, on: connection)
        }

        connection.cancel()
    }

    private func renderResponseHeaders(from response: HTTPURLResponse) -> String {
        var lines = ["HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized)"]

        for (nameAny, valueAny) in response.allHeaderFields {
            guard let name = nameAny as? String,
                  let value = valueAny as? String else {
                continue
            }
            let lowercased = name.lowercased()
            if lowercased == "content-length" || lowercased == "transfer-encoding" || lowercased == "connection" {
                continue
            }
            lines.append("\(name): \(value)")
        }

        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private func makeWebSocketHandshakeResponse(
        for secWebSocketKey: String,
        selectedProtocol: String? = nil
    ) -> String {
        let accept = self.secWebSocketAcceptValue(for: secWebSocketKey)
        var lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
        ]
        if let selectedProtocol,
           selectedProtocol.isEmpty == false {
            lines.append("Sec-WebSocket-Protocol: \(selectedProtocol)")
        }
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private func secWebSocketAcceptValue(for key: String) -> String {
        let value = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
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
                        self.makeWebSocketFrame(
                            opcode: 0x8,
                            payload: self.makeWebSocketClosePayload(code: 1002)
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
                self.makeWebSocketFrame(opcode: 0x8, payload: payload),
                on: connection
            )
            upstreamTask.cancel(with: .normalClosure, reason: payload)
            self.clearBinding(stickyKey: stickyKey, accountID: accountID)
            connection.cancel()
        case 0x9:
            try? await self.send(
                self.makeWebSocketFrame(opcode: 0xA, payload: frame.payload),
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
                        frame = self.makeWebSocketFrame(opcode: 0x1, payload: Data(text.utf8))
                    case .data(let data):
                        frame = self.makeWebSocketFrame(opcode: 0x2, payload: data)
                    @unknown default:
                        frame = self.makeWebSocketFrame(
                            opcode: 0x8,
                            payload: self.makeWebSocketClosePayload(code: 1011)
                        )
                    }
                    try await self.send(frame, on: connection)
                }
            } catch {
                try? await self.send(
                    self.makeWebSocketFrame(
                        opcode: 0x8,
                        payload: self.makeWebSocketClosePayload(code: 1000)
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
        guard buffer.count >= 2 else { return nil }

        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let isFinal = (first & 0x80) != 0
        let reservedBits = first & 0x70
        let opcode = first & 0x0F
        let isMasked = (second & 0x80) != 0

        guard reservedBits == 0 else {
            throw URLError(.cannotParseResponse)
        }
        guard isMasked else {
            throw URLError(.cannotParseResponse)
        }

        var payloadLength = Int(second & 0x7F)
        var cursor = 2

        if payloadLength == 126 {
            guard buffer.count >= cursor + 2 else { return nil }
            payloadLength = Int(buffer[cursor]) << 8 | Int(buffer[cursor + 1])
            cursor += 2
        } else if payloadLength == 127 {
            guard buffer.count >= cursor + 8 else { return nil }
            let length = buffer[cursor..<(cursor + 8)].reduce(UInt64(0)) { partial, byte in
                (partial << 8) | UInt64(byte)
            }
            guard length <= UInt64(Int.max) else {
                throw URLError(.cannotDecodeRawData)
            }
            payloadLength = Int(length)
            cursor += 8
        }

        if opcode >= 0x8 {
            guard isFinal, payloadLength <= 125 else {
                throw URLError(.cannotParseResponse)
            }
        }

        let maskLength = isMasked ? 4 : 0
        guard buffer.count >= cursor + maskLength + payloadLength else { return nil }

        let mask: [UInt8]
        if isMasked {
            mask = Array(buffer[cursor..<(cursor + 4)])
            cursor += 4
        } else {
            mask = []
        }

        var payload = Data(buffer[cursor..<(cursor + payloadLength)])
        if isMasked {
            for index in payload.indices {
                let offset = payload.distance(from: payload.startIndex, to: index)
                payload[index] ^= mask[offset % 4]
            }
        }

        buffer.removeSubrange(0..<(cursor + payloadLength))
        return ParsedWebSocketFrame(opcode: opcode, payload: payload, isFinal: isFinal)
    }

    private func makeWebSocketFrame(
        opcode: UInt8,
        payload: Data = Data(),
        isFinal: Bool = true
    ) -> Data {
        var frame = Data()
        frame.append((isFinal ? 0x80 : 0x00) | opcode)

        switch payload.count {
        case 0...125:
            frame.append(UInt8(payload.count))
        case 126...65_535:
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        default:
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }

    private func makeWebSocketClosePayload(code: UInt16) -> Data {
        Data([
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ])
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
    func parseRequestForTesting(from data: Data) -> ParsedGatewayRequest? {
        self.parseRequest(from: data)
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
        return OpenAIAccountGatewayTestResponse(
            statusCode: 101,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": self.secWebSocketAcceptValue(for: secKey),
            ],
            body: Data()
        )
    }

    func postResponsesProbeForTesting(
        request: ParsedGatewayRequest
    ) async throws -> OpenAIAccountGatewayTestResponse {
        try await self.bufferedResponsesRequestForTesting(request)
    }

    private func bufferedResponsesRequestForTesting(
        _ request: ParsedGatewayRequest
    ) async throws -> OpenAIAccountGatewayTestResponse {
        let snapshot = self.snapshot()
        let stickyKey = self.stickySessionKey(for: request.headers)
        let candidates = self.candidates(for: snapshot, stickyKey: stickyKey)

        guard candidates.isEmpty == false else {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#.utf8)
            )
        }

        for (index, account) in candidates.enumerated() {
            do {
                let result = try await self.proxyPOSTResponses(request, account: account)
                if self.shouldRetry(statusCode: result.response.statusCode),
                   index < candidates.count - 1 {
                    self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                    continue
                }

                self.bind(stickyKey: stickyKey, accountID: account.accountId)
                return try await OpenAIAccountGatewayTestResponse(
                    statusCode: result.response.statusCode,
                    headers: self.responseHeadersForTesting(from: result.response),
                    body: self.readAllBytesForTesting(from: result.bytes)
                )
            } catch {
                if index == candidates.count - 1 {
                    return OpenAIAccountGatewayTestResponse(
                        statusCode: 502,
                        headers: ["Content-Type": "application/json"],
                        body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#.utf8)
                    )
                }
            }
        }

        return OpenAIAccountGatewayTestResponse(
            statusCode: 502,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#.utf8)
        )
    }

    private func responseHeadersForTesting(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (nameAny, valueAny) in response.allHeaderFields {
            guard let name = nameAny as? String,
                  let value = valueAny as? String else {
                continue
            }
            let lowercased = name.lowercased()
            if lowercased == "content-length" || lowercased == "transfer-encoding" || lowercased == "connection" {
                continue
            }
            headers[name] = value
        }
        headers["Connection"] = "close"
        return headers
    }

    private func readAllBytesForTesting(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }
}
#endif
