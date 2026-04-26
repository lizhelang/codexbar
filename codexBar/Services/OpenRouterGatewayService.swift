import Foundation
import Network

protocol OpenRouterGatewayControlling: AnyObject {
    func startIfNeeded()
    func stop()
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool)
}

enum OpenRouterGatewayConfiguration {
    static let host = "localhost"
    static let port: UInt16 = 1457
    static let apiKey = "codexbar-openrouter-gateway"
    static let upstreamResponsesURL = URL(string: "https://openrouter.ai/api/v1/responses")!

    static var baseURLString: String {
        "http://\(self.host):\(self.port)/v1"
    }
}

struct OpenRouterGatewayRuntimeConfiguration {
    var host: String
    var port: UInt16
    var upstreamResponsesURL: URL

    static let live = OpenRouterGatewayRuntimeConfiguration(
        host: OpenRouterGatewayConfiguration.host,
        port: OpenRouterGatewayConfiguration.port,
        upstreamResponsesURL: OpenRouterGatewayConfiguration.upstreamResponsesURL
    )
}

struct OpenRouterGatewayTestResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct OpenRouterGatewayWebSocketProbeResult {
    let events: [String]
    let closeCode: UInt16
}

private struct ParsedOpenRouterWebSocketFrame {
    let opcode: UInt8
    let payload: Data
    let isFinal: Bool

    init(portableCore frame: PortableCoreGatewayParsedWebSocketFrame) {
        self.opcode = frame.opcode
        self.payload = Data(frame.payloadBytes)
        self.isFinal = frame.isFinal
    }
}

private struct OpenRouterWebSocketFragmentState {
    var opcode: UInt8?
    var payload = Data()
}

private struct OpenRouterGatewayAccountState {
    let account: CodexBarProviderAccount
    let modelID: String
}

final class OpenRouterGatewayService: OpenRouterGatewayControlling {
    nonisolated static let mockRequestBodyPropertyKey = "codexbar.mockOpenRouterRequestBody"
    private let listenerQueue = DispatchQueue(label: "lzl.codexbar.openrouter-gateway.listener")
    private let stateQueue = DispatchQueue(label: "lzl.codexbar.openrouter-gateway.state")
    private let urlSession: URLSession
    private let runtimeConfiguration: OpenRouterGatewayRuntimeConfiguration

    private var listener: NWListener?
    private var provider: CodexBarProvider?

    init(
        urlSession: URLSession? = nil,
        runtimeConfiguration: OpenRouterGatewayRuntimeConfiguration = .live
    ) {
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
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
                NSLog("codexbar OpenRouter gateway failed to start: %@", error.localizedDescription)
            }
        }
    }

    func stop() {
        self.listenerQueue.sync {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    func updateState(provider: CodexBarProvider?, isActiveProvider _: Bool) {
        self.stateQueue.async {
            self.provider = provider?.kind == .openRouter ? provider : nil
        }
    }

    func postResponsesProbeForTesting(request: ParsedGatewayRequest) async throws -> OpenRouterGatewayTestResponse {
        let accountState = self.stateQueue.sync { () -> OpenRouterGatewayAccountState? in
            let resolved =
                (try? RustPortableCoreAdapter.shared.resolveOpenRouterGatewayAccountState(
                    PortableCoreOpenRouterGatewayAccountStateRequest(
                        provider: self.provider.map(PortableCoreOpenRouterProviderInput.legacy(from:))
                    ),
                    buildIfNeeded: false
                )) ?? PortableCoreOpenRouterGatewayAccountStateResult.failClosed()
            guard let account = resolved.account?.providerAccount(),
                  let modelID = resolved.modelId else {
                return nil
            }
            return OpenRouterGatewayAccountState(account: account, modelID: modelID)
        }
        guard let accountState else {
            throw URLError(.userAuthenticationRequired)
        }
        let result = try await self.proxyResponsesRequest(
            body: request.body,
            route: request.path,
            inboundHeaders: request.headers,
            accountState: accountState
        )
        var body = Data()
        for try await byte in result.bytes {
            body.append(byte)
        }
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
        return OpenRouterGatewayTestResponse(
            statusCode: result.response.statusCode,
            headers: Dictionary(
                uniqueKeysWithValues: renderedHeaders.filteredHeaders.map { ($0.name, $0.value) }
            ),
            body: body
        )
    }

    func bridgeWebSocketTextMessageForTesting(_ text: String) async throws -> OpenRouterGatewayWebSocketProbeResult {
        let accountState = self.stateQueue.sync { () -> OpenRouterGatewayAccountState? in
            let resolved =
                (try? RustPortableCoreAdapter.shared.resolveOpenRouterGatewayAccountState(
                    PortableCoreOpenRouterGatewayAccountStateRequest(
                        provider: self.provider.map(PortableCoreOpenRouterProviderInput.legacy(from:))
                    ),
                    buildIfNeeded: false
                )) ?? PortableCoreOpenRouterGatewayAccountStateResult.failClosed()
            guard let account = resolved.account?.providerAccount(),
                  let modelID = resolved.modelId else {
                return nil
            }
            return OpenRouterGatewayAccountState(account: account, modelID: modelID)
        }
        guard let accountState else {
            throw URLError(.userAuthenticationRequired)
        }
        let result = try await self.proxyResponsesRequest(
            body: Data(text.utf8),
            route: "/v1/responses",
            inboundHeaders: [:],
            accountState: accountState
        )

        guard (200...299).contains(result.response.statusCode) else {
            var errorBody = Data()
            for try await byte in result.bytes {
                errorBody.append(byte)
            }
            let payload = String(data: errorBody, encoding: .utf8) ?? #"{"error":{"message":"OpenRouter upstream error"}}"#
            return OpenRouterGatewayWebSocketProbeResult(events: [payload], closeCode: 1011)
        }

        if result.response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            var buffer = Data()
            var events: [String] = []
            let delimiter = Data("\n\n".utf8)

            for try await byte in result.bytes {
                buffer.append(byte)

                while let range = buffer.range(of: delimiter) {
                    let eventData = buffer.subdata(in: 0..<range.lowerBound)
                    buffer.removeSubrange(0..<range.upperBound)

                    guard let eventText = String(data: eventData, encoding: .utf8) else {
                        continue
                    }
                    let dataLines = eventText
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .components(separatedBy: "\n")
                        .compactMap { line -> String? in
                            if line.hasPrefix("data:") {
                                return line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                            }
                            return nil
                        }
                    let payload =
                        dataLines.isEmpty == false
                        ? dataLines.joined(separator: "\n")
                        : eventText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard payload.isEmpty == false else { continue }
                    events.append(payload)
                }
            }

            if buffer.isEmpty == false, let eventText = String(data: buffer, encoding: .utf8) {
                let dataLines = eventText
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .components(separatedBy: "\n")
                    .compactMap { line -> String? in
                        if line.hasPrefix("data:") {
                            return line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        }
                        return nil
                    }
                let payload =
                    dataLines.isEmpty == false
                    ? dataLines.joined(separator: "\n")
                    : eventText.trimmingCharacters(in: .whitespacesAndNewlines)
                if payload.isEmpty == false {
                    events.append(payload)
                }
            }
            if let last = events.last, last == "[DONE]" {
                return OpenRouterGatewayWebSocketProbeResult(events: Array(events.dropLast()), closeCode: 1000)
            }
            return OpenRouterGatewayWebSocketProbeResult(events: events, closeCode: 1000)
        }

        var responseBody = Data()
        for try await byte in result.bytes {
            responseBody.append(byte)
        }
        let payload = String(data: responseBody, encoding: .utf8) ?? "{}"
        return OpenRouterGatewayWebSocketProbeResult(events: [payload], closeCode: 1000)
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NSLog("codexbar OpenRouter gateway receive failed: %@", error.localizedDescription)
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

                            let accountState = self.stateQueue.sync { () -> OpenRouterGatewayAccountState? in
                                let resolved =
                                    (try? RustPortableCoreAdapter.shared.resolveOpenRouterGatewayAccountState(
                                        PortableCoreOpenRouterGatewayAccountStateRequest(
                                            provider: self.provider.map(PortableCoreOpenRouterProviderInput.legacy(from:))
                                        ),
                                        buildIfNeeded: false
                                    )) ?? PortableCoreOpenRouterGatewayAccountStateResult.failClosed()
                                guard let account = resolved.account?.providerAccount(),
                                      let modelID = resolved.modelId else {
                                    return nil
                                }
                                return OpenRouterGatewayAccountState(account: account, modelID: modelID)
                            }
                            guard let accountState else {
                                self.sendJSONResponse(
                                    on: connection,
                                    statusCode: 503,
                                    body: #"{"error":{"message":"OpenRouter gateway unavailable: missing active OpenRouter account or selected model"}}"#
                                )
                                return
                            }

                            do {
                                let handshakeRequest = PortableCoreGatewayWebSocketHandshakeRequest(
                                    secWebSocketKey: secKey,
                                    selectedProtocol: nil
                                )
                                let handshake =
                                    (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketHandshake(
                                        handshakeRequest,
                                        buildIfNeeded: false
                                    )) ?? PortableCoreGatewayWebSocketHandshakeResult.failClosed(
                                        request: handshakeRequest
                                    )
                                try await self.send(Data(handshake.responseText.utf8), on: connection)
                                self.receiveClientWebSocketMessages(
                                    on: connection,
                                    buffer: Data(),
                                    fragments: OpenRouterWebSocketFragmentState(),
                                    accountState: accountState
                                )
                            } catch {
                                connection.cancel()
                            }
                        }
                    case ("POST", "/v1/responses"), ("POST", "/v1/responses/compact"):
                        Task {
                            do {
                                let accountState = self.stateQueue.sync { () -> OpenRouterGatewayAccountState? in
                                    let resolved =
                                        (try? RustPortableCoreAdapter.shared.resolveOpenRouterGatewayAccountState(
                                            PortableCoreOpenRouterGatewayAccountStateRequest(
                                                provider: self.provider.map(PortableCoreOpenRouterProviderInput.legacy(from:))
                                            ),
                                            buildIfNeeded: false
                                        )) ?? PortableCoreOpenRouterGatewayAccountStateResult.failClosed()
                                    guard let account = resolved.account?.providerAccount(),
                                          let modelID = resolved.modelId else {
                                        return nil
                                    }
                                    return OpenRouterGatewayAccountState(account: account, modelID: modelID)
                                }
                                guard let accountState else {
                                    throw URLError(.userAuthenticationRequired)
                                }
                                let result = try await self.proxyResponsesRequest(
                                    body: request.body,
                                    route: request.path,
                                    inboundHeaders: request.headers,
                                    accountState: accountState
                                )
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
                                try await self.send(Data(renderedHeaders.headerText.utf8), on: connection)

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
                            } catch {
                                self.sendJSONResponse(
                                    on: connection,
                                    statusCode: 502,
                                    body: #"{"error":{"message":"codexbar OpenRouter gateway failed to reach upstream"}}"#
                                )
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

    private func proxyResponsesRequest(
        body: Data,
        route: String,
        inboundHeaders: [String: String],
        accountState: OpenRouterGatewayAccountState
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        let normalizedBody: Data
        if let object = try? JSONSerialization.jsonObject(with: body) {
            let bodyJson = JSONValue(any: object)
            let result =
                (try? RustPortableCoreAdapter.shared.normalizeOpenRouterRequest(
                    PortableCoreOpenRouterRequestNormalizationRequest(
                        route: route,
                        selectedModelId: accountState.modelID,
                        bodyJson: bodyJson
                    )
                )) ?? PortableCoreOpenRouterRequestNormalizationResult.failClosed(bodyJson: bodyJson)
            if let normalized = result.normalizedJson.anyValue as? [String: Any],
               JSONSerialization.isValidJSONObject(normalized),
               let data = try? JSONSerialization.data(withJSONObject: normalized) {
                normalizedBody = data
            } else {
                normalizedBody = body
            }
        } else {
            normalizedBody = body
        }
        var upstreamRequest = URLRequest(url: self.runtimeConfiguration.upstreamResponsesURL)
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = normalizedBody
        let mutableRequest = (upstreamRequest as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(
            normalizedBody,
            forKey: Self.mockRequestBodyPropertyKey,
            in: mutableRequest
        )
        upstreamRequest = mutableRequest as URLRequest

        for (name, value) in inboundHeaders {
            switch name {
            case "host", "content-length", "authorization", "connection":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        upstreamRequest.setValue("Bearer \(accountState.account.apiKey ?? "")", forHTTPHeaderField: "authorization")
        let (bytes, response) = try await self.urlSession.bytes(for: upstreamRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (httpResponse, bytes)
    }

    private func receiveClientWebSocketMessages(
        on connection: NWConnection,
        buffer: Data,
        fragments: OpenRouterWebSocketFragmentState,
        accountState: OpenRouterGatewayAccountState
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task { @MainActor in
                if error != nil {
                    connection.cancel()
                    return
                }

                var buffer = buffer
                if let data {
                    buffer.append(data)
                }

                var fragments = fragments
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
                        let frame: ParsedOpenRouterWebSocketFrame
                        switch frameParseResult.outcome {
                        case "needMoreData":
                            break frameParseLoop
                        case "parsed":
                            guard let parsedFrame = frameParseResult.parsedFrame else {
                                throw URLError(.cannotParseResponse)
                            }
                            buffer.removeSubrange(0..<parsedFrame.consumedByteCount)
                            frame = ParsedOpenRouterWebSocketFrame(portableCore: parsedFrame)
                        case "decodeError":
                            throw URLError(.cannotDecodeRawData)
                        default:
                            throw URLError(.cannotParseResponse)
                        }
                        let shouldContinue: Bool
                        switch frame.opcode {
                        case 0x0:
                            guard let fragmentedOpcode = fragments.opcode else {
                                throw URLError(.cannotParseResponse)
                            }
                            fragments.payload.append(frame.payload)
                            if frame.isFinal == false {
                                shouldContinue = true
                                break
                            }
                            let payload = fragments.payload
                            fragments = OpenRouterWebSocketFragmentState()
                            shouldContinue = try await self.handleCompletedWebSocketPayload(
                                opcode: fragmentedOpcode,
                                payload: payload,
                                connection: connection,
                                accountState: accountState
                            )
                        case 0x1, 0x2:
                            if frame.isFinal {
                                shouldContinue = try await self.handleCompletedWebSocketPayload(
                                    opcode: frame.opcode,
                                    payload: frame.payload,
                                    connection: connection,
                                    accountState: accountState
                                )
                            } else {
                                fragments.opcode = frame.opcode
                                fragments.payload = frame.payload
                                shouldContinue = true
                            }
                        case 0x8:
                            try? await self.send(
                                self.webSocketFrameData(opcode: 0x8, payload: frame.payload),
                                on: connection
                            )
                            connection.cancel()
                            shouldContinue = false
                        case 0x9:
                            try? await self.send(
                                self.webSocketFrameData(opcode: 0xA, payload: frame.payload),
                                on: connection
                            )
                            shouldContinue = true
                        case 0xA:
                            shouldContinue = true
                        default:
                            throw URLError(.cannotParseResponse)
                        }
                        if shouldContinue == false {
                            return
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
                        self.webSocketFrameData(
                            opcode: 0x8,
                            payload: Data(closePayloadResult.payloadBytes)
                        ),
                        on: connection
                    )
                    connection.cancel()
                    return
                }

                if isComplete {
                    connection.cancel()
                    return
                }

                self.receiveClientWebSocketMessages(
                    on: connection,
                    buffer: buffer,
                    fragments: fragments,
                    accountState: accountState
                )
            }
        }
    }

    private func handleCompletedWebSocketPayload(
        opcode: UInt8,
        payload: Data,
        connection: NWConnection,
        accountState: OpenRouterGatewayAccountState
    ) async throws -> Bool {
        if opcode == 0x2 {
            let closePayloadRequest = PortableCoreGatewayWebSocketClosePayloadRequest(code: 1003)
            let closePayloadResult =
                (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketClosePayload(
                    closePayloadRequest,
                    buildIfNeeded: false
                )) ?? PortableCoreGatewayWebSocketClosePayloadResult.failClosed(
                    request: closePayloadRequest
                )
            try await self.send(
                self.webSocketFrameData(
                    opcode: 0x8,
                    payload: Data(closePayloadResult.payloadBytes)
                ),
                on: connection
            )
            connection.cancel()
            return false
        }

        switch opcode {
        case 0x1:
            guard let text = String(data: payload, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            let result = try await self.proxyResponsesRequest(
                body: Data(text.utf8),
                route: "/v1/responses",
                inboundHeaders: [:],
                accountState: accountState
            )

            let closeCode: UInt16
            if (200...299).contains(result.response.statusCode) == false {
                var errorBody = Data()
                for try await byte in result.bytes {
                    errorBody.append(byte)
                }
                let responsePayload = String(data: errorBody, encoding: .utf8)
                    ?? #"{"error":{"message":"OpenRouter upstream error"}}"#
                try await self.send(
                    self.webSocketFrameData(opcode: 0x1, payload: Data(responsePayload.utf8)),
                    on: connection
                )
                closeCode = 1011
            } else if result.response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased()
                .contains("text/event-stream") == true {
                    var buffer = Data()
                    let delimiter = Data("\n\n".utf8)
                    var completedNormally = false

                    for try await byte in result.bytes {
                        buffer.append(byte)

                        while let range = buffer.range(of: delimiter) {
                            let eventData = buffer.subdata(in: 0..<range.lowerBound)
                            buffer.removeSubrange(0..<range.upperBound)

                            guard let eventText = String(data: eventData, encoding: .utf8) else {
                                continue
                            }
                            let dataLines = eventText
                                .replacingOccurrences(of: "\r\n", with: "\n")
                                .components(separatedBy: "\n")
                                .compactMap { line -> String? in
                                    if line.hasPrefix("data:") {
                                        return line.dropFirst("data:".count)
                                            .trimmingCharacters(in: .whitespaces)
                                    }
                                    return nil
                                }
                            let responsePayload =
                                dataLines.isEmpty == false
                                ? dataLines.joined(separator: "\n")
                                : eventText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard responsePayload.isEmpty == false else { continue }
                            if responsePayload == "[DONE]" {
                                completedNormally = true
                                break
                            }
                            try await self.send(
                                self.webSocketFrameData(opcode: 0x1, payload: Data(responsePayload.utf8)),
                                on: connection
                            )
                        }

                        if completedNormally {
                            break
                        }
                    }

                    if completedNormally == false,
                       buffer.isEmpty == false,
                       let eventText = String(data: buffer, encoding: .utf8) {
                        let dataLines = eventText
                            .replacingOccurrences(of: "\r\n", with: "\n")
                            .components(separatedBy: "\n")
                            .compactMap { line -> String? in
                                if line.hasPrefix("data:") {
                                    return line.dropFirst("data:".count)
                                        .trimmingCharacters(in: .whitespaces)
                                }
                                return nil
                            }
                        let responsePayload =
                            dataLines.isEmpty == false
                            ? dataLines.joined(separator: "\n")
                            : eventText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if responsePayload.isEmpty == false && responsePayload != "[DONE]" {
                            try await self.send(
                                self.webSocketFrameData(opcode: 0x1, payload: Data(responsePayload.utf8)),
                                on: connection
                            )
                        }
                    }
                    closeCode = 1000
                } else {
                    var responseBody = Data()
                    for try await byte in result.bytes {
                        responseBody.append(byte)
                    }
                    try await self.send(
                        self.webSocketFrameData(opcode: 0x1, payload: responseBody),
                        on: connection
                    )
                    closeCode = 1000
                }
            let closePayloadRequest = PortableCoreGatewayWebSocketClosePayloadRequest(code: closeCode)
            let closePayloadResult =
                (try? RustPortableCoreAdapter.shared.renderGatewayWebSocketClosePayload(
                    closePayloadRequest,
                    buildIfNeeded: false
                )) ?? PortableCoreGatewayWebSocketClosePayloadResult.failClosed(
                    request: closePayloadRequest
                )
            try await self.send(
                self.webSocketFrameData(
                    opcode: 0x8,
                    payload: Data(closePayloadResult.payloadBytes)
                ),
                on: connection
            )
            connection.cancel()
            return false
        default:
            throw URLError(.unsupportedURL)
        }
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
