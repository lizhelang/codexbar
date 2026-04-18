import CryptoKit
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
    private nonisolated static let openRouterPrefixedToolTypeMap: [String: String] = [
        "datetime": "openrouter:datetime",
        "experimental__search_models": "openrouter:experimental__search_models",
    ]
    private nonisolated static let openRouterWrappedParameterToolTypes: Set<String> = [
        "openrouter:datetime",
        "openrouter:experimental__search_models",
        "openrouter:image_generation",
        "openrouter:web_search",
    ]
    private nonisolated static let openRouterPassthroughToolTypes: Set<String> = [
        "apply_patch",
        "code_interpreter",
        "computer_use_preview",
        "custom",
        "file_search",
        "function",
        "image_generation",
        "local_shell",
        "mcp",
        "shell",
        "web_search",
        "web_search_2025_08_26",
        "web_search_preview",
        "web_search_preview_2025_03_11",
        "openrouter:datetime",
        "openrouter:experimental__search_models",
        "openrouter:image_generation",
        "openrouter:web_search",
    ]
    private nonisolated static let toolConfigTopLevelKeysToWrap: Set<String> = [
        "allowed_domains",
        "engine",
        "excluded_domains",
        "filters",
        "max_results",
        "parameters",
        "search_context_size",
        "timezone",
        "user_location",
    ]

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

    func parseRequestForTesting(from data: Data) -> ParsedGatewayRequest? {
        self.parseRequest(from: data)
    }

    func webSocketUpgradeProbeForTesting(request: ParsedGatewayRequest) -> OpenRouterGatewayTestResponse {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              let secKey = request.headers["sec-websocket-key"],
              secKey.isEmpty == false else {
            return OpenRouterGatewayTestResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"websocket upgrade headers are missing"}}"#.utf8)
            )
        }

        guard self.currentAccountState() != nil else {
            return OpenRouterGatewayTestResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"OpenRouter gateway unavailable: missing active OpenRouter account or selected model"}}"#.utf8)
            )
        }

        return OpenRouterGatewayTestResponse(
            statusCode: 101,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": self.secWebSocketAcceptValue(for: secKey),
            ],
            body: Data()
        )
    }

    func postResponsesProbeForTesting(request: ParsedGatewayRequest) async throws -> OpenRouterGatewayTestResponse {
        try await self.bufferedResponsesRequestForTesting(request)
    }

    func bridgeWebSocketTextMessageForTesting(_ text: String) async throws -> OpenRouterGatewayWebSocketProbeResult {
        let accountState = try self.requireCurrentAccountState()
        return try await self.collectWebSocketBridgeProbe(text: text, accountState: accountState)
    }

    func completedWebSocketCloseCodeProbeForTesting(opcode: UInt8) -> UInt16? {
        self.immediateCloseCodeForCompletedWebSocketOpcode(opcode)
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
        case ("POST", "/v1/responses"), ("POST", "/v1/responses/compact"):
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

    private func forwardResponsesRequest(_ request: ParsedGatewayRequest, on connection: NWConnection) async {
        do {
            let accountState = try self.requireCurrentAccountState()
            let result = try await self.proxyResponsesRequest(
                body: request.body,
                route: request.path,
                inboundHeaders: request.headers,
                accountState: accountState
            )
            try await self.streamHTTPResponse(result, to: connection)
        } catch {
            self.sendJSONResponse(
                on: connection,
                statusCode: 502,
                body: #"{"error":{"message":"codexbar OpenRouter gateway failed to reach upstream"}}"#
            )
        }
    }

    private func bufferedResponsesRequestForTesting(
        _ request: ParsedGatewayRequest
    ) async throws -> OpenRouterGatewayTestResponse {
        let accountState = try self.requireCurrentAccountState()
        let result = try await self.proxyResponsesRequest(
            body: request.body,
            route: request.path,
            inboundHeaders: request.headers,
            accountState: accountState
        )
        let body = try await self.readAllBytes(from: result.bytes)
        return OpenRouterGatewayTestResponse(
            statusCode: result.response.statusCode,
            headers: self.responseHeaders(from: result.response),
            body: body
        )
    }

    private func streamHTTPResponse(
        _ result: (response: HTTPURLResponse, bytes: URLSession.AsyncBytes),
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

    private func proxyResponsesRequest(
        body: Data,
        route: String,
        inboundHeaders: [String: String],
        accountState: OpenRouterGatewayAccountState
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        let normalizedBody = self.normalizeRequestBody(
            body,
            route: route,
            selectedModelID: accountState.modelID
        )
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

    private func normalizeRequestBody(_ body: Data, route: String, selectedModelID: String) -> Data {
        let object = try? JSONSerialization.jsonObject(with: body)
        let normalizedObject: [String: Any]

        if let json = object as? [String: Any] {
            normalizedObject = self.normalizeRequestObject(
                json,
                route: route,
                selectedModelID: selectedModelID
            )
        } else if let inputArray = object as? [Any] {
            normalizedObject = self.normalizeRequestObject(
                ["input": inputArray],
                route: route,
                selectedModelID: selectedModelID
            )
        } else {
            return body
        }

        guard JSONSerialization.isValidJSONObject(normalizedObject),
              let data = try? JSONSerialization.data(withJSONObject: normalizedObject) else {
            return body
        }
        return data
    }

    private func normalizeRequestObject(
        _ original: [String: Any],
        route: String,
        selectedModelID: String
    ) -> [String: Any] {
        var json = self.unwrapResponseCreateEnvelopeIfNeeded(original)
        json["model"] = selectedModelID
        if let normalizedInput = self.normalizeOpenRouterInput(json["input"]) {
            json["input"] = normalizedInput
        }

        if route == "/v1/responses/compact" {
            json.removeValue(forKey: "store")
            json.removeValue(forKey: "stream")
            json.removeValue(forKey: "include")
            json.removeValue(forKey: "tools")
            json.removeValue(forKey: "tool_choice")
            json.removeValue(forKey: "parallel_tool_calls")
            json.removeValue(forKey: "max_output_tokens")
            json.removeValue(forKey: "temperature")
            json.removeValue(forKey: "top_p")
            if json["instructions"] == nil || json["instructions"] is NSNull {
                json["instructions"] = ""
            }
        } else {
            json["store"] = false
            json["stream"] = true
            json.removeValue(forKey: "max_output_tokens")
            json.removeValue(forKey: "temperature")
            json.removeValue(forKey: "top_p")
            if json["instructions"] == nil || json["instructions"] is NSNull {
                json["instructions"] = ""
            }
            let normalizedTools = self.normalizeOpenRouterTools(json["tools"])
            json["tools"] = normalizedTools
            json["tool_choice"] = self.normalizeOpenRouterToolChoice(
                json["tool_choice"],
                normalizedTools: normalizedTools
            )
            if json["parallel_tool_calls"] == nil || json["parallel_tool_calls"] is NSNull {
                json["parallel_tool_calls"] = false
            }
        }

        return json
    }

    private func unwrapResponseCreateEnvelopeIfNeeded(_ json: [String: Any]) -> [String: Any] {
        guard json["input"] == nil,
              let type = json["type"] as? String,
              type == "response.create",
              let response = json["response"] as? [String: Any] else {
            return json
        }
        return response
    }

    private func normalizeOpenRouterInput(_ input: Any?) -> Any? {
        guard let input else { return nil }
        guard let items = input as? [Any] else { return input }

        return items.enumerated().map { index, item in
            guard var message = item as? [String: Any] else { return item }

            if message["type"] == nil,
               let role = message["role"] as? String,
               role.isEmpty == false {
                message["type"] = "message"
            }

            if let role = (message["role"] as? String)?.lowercased(),
               role == "assistant" {
                if (message["status"] as? String)?.isEmpty != false {
                    message["status"] = "completed"
                }
                if (message["id"] as? String)?.isEmpty != false {
                    message["id"] = "msg_codexbar_\(index)"
                }
            }

            return message
        }
    }

    private func normalizeOpenRouterTools(_ tools: Any?) -> [[String: Any]] {
        guard let items = tools as? [Any] else { return [] }

        return items.compactMap { item in
            guard let tool = item as? [String: Any] else { return nil }
            return self.normalizeOpenRouterTool(tool)
        }
    }

    private func normalizeOpenRouterTool(_ original: [String: Any]) -> [String: Any]? {
        var tool = self.flattenNestedFunctionToolIfNeeded(original)
        guard var type = tool["type"] as? String,
              type.isEmpty == false else {
            return nil
        }

        if let mappedType = Self.openRouterPrefixedToolTypeMap[type] {
            type = mappedType
            tool["type"] = mappedType
        }

        guard Self.openRouterPassthroughToolTypes.contains(type) else {
            return nil
        }

        if Self.openRouterWrappedParameterToolTypes.contains(type) {
            tool = self.wrapOpenRouterToolParameters(tool)
        }

        return tool
    }

    private func flattenNestedFunctionToolIfNeeded(_ original: [String: Any]) -> [String: Any] {
        guard (original["type"] as? String) == "function",
              let nestedFunction = original["function"] as? [String: Any] else {
            return original
        }

        var tool = original
        tool.removeValue(forKey: "function")
        for key in ["name", "description", "parameters", "strict"] {
            if tool[key] == nil, let value = nestedFunction[key] {
                tool[key] = value
            }
        }
        return tool
    }

    private func wrapOpenRouterToolParameters(_ original: [String: Any]) -> [String: Any] {
        var tool = original
        var parameters = (tool["parameters"] as? [String: Any]) ?? [:]

        for key in Self.toolConfigTopLevelKeysToWrap {
            guard key != "parameters",
                  let value = tool[key] else { continue }

            if key == "filters", let filters = value as? [String: Any] {
                for (filterKey, filterValue) in filters where parameters[filterKey] == nil {
                    parameters[filterKey] = filterValue
                }
            } else if parameters[key] == nil {
                parameters[key] = value
            }

            tool.removeValue(forKey: key)
        }

        if parameters.isEmpty == false {
            tool["parameters"] = parameters
        }

        return tool
    }

    private func normalizeOpenRouterToolChoice(_ toolChoice: Any?, normalizedTools: [[String: Any]]) -> Any {
        guard normalizedTools.isEmpty == false else { return "none" }
        guard let toolChoice else { return "auto" }

        if let toolChoice = toolChoice as? String {
            switch toolChoice {
            case "auto", "none", "required":
                return toolChoice
            default:
                return "auto"
            }
        }

        guard var toolChoiceObject = toolChoice as? [String: Any] else {
            return "auto"
        }

        if (toolChoiceObject["type"] as? String) == "function",
           let nestedFunction = toolChoiceObject["function"] as? [String: Any],
           toolChoiceObject["name"] == nil,
           let name = nestedFunction["name"] {
            toolChoiceObject["name"] = name
        }
        toolChoiceObject.removeValue(forKey: "function")

        guard let type = toolChoiceObject["type"] as? String else {
            return "auto"
        }

        switch type {
        case "function":
            guard let name = toolChoiceObject["name"] as? String,
                  normalizedTools.contains(where: {
                      ($0["type"] as? String) == "function" && ($0["name"] as? String) == name
                  }) else {
                return "auto"
            }
            return ["type": "function", "name": name]
        case "none":
            return "none"
        case "auto", "required":
            return type
        default:
            return "auto"
        }
    }

    private func handleResponsesWebSocketUpgrade(request: ParsedGatewayRequest, on connection: NWConnection) async {
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

        guard let accountState = self.currentAccountState() else {
            self.sendJSONResponse(
                on: connection,
                statusCode: 503,
                body: #"{"error":{"message":"OpenRouter gateway unavailable: missing active OpenRouter account or selected model"}}"#
            )
            return
        }

        do {
            try await self.send(Data(self.makeWebSocketHandshakeResponse(for: secKey).utf8), on: connection)
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
                    while let frame = try self.parseNextWebSocketFrame(from: &buffer) {
                        let shouldContinue = try await self.handleClientWebSocketFrame(
                            frame,
                            fragments: &fragments,
                            connection: connection,
                            accountState: accountState
                        )
                        if shouldContinue == false {
                            return
                        }
                    }
                } catch {
                    try? await self.send(
                        self.makeWebSocketFrame(
                            opcode: 0x8,
                            payload: self.makeWebSocketClosePayload(code: 1002)
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

    private func handleClientWebSocketFrame(
        _ frame: ParsedOpenRouterWebSocketFrame,
        fragments: inout OpenRouterWebSocketFragmentState,
        connection: NWConnection,
        accountState: OpenRouterGatewayAccountState
    ) async throws -> Bool {
        switch frame.opcode {
        case 0x0:
            guard let fragmentedOpcode = fragments.opcode else {
                throw URLError(.cannotParseResponse)
            }
            fragments.payload.append(frame.payload)
            guard frame.isFinal else { return true }
            let payload = fragments.payload
            fragments = OpenRouterWebSocketFragmentState()
            return try await self.handleCompletedWebSocketPayload(
                opcode: fragmentedOpcode,
                payload: payload,
                connection: connection,
                accountState: accountState
            )
        case 0x1, 0x2:
            if frame.isFinal {
                return try await self.handleCompletedWebSocketPayload(
                    opcode: frame.opcode,
                    payload: frame.payload,
                    connection: connection,
                    accountState: accountState
                )
            }
            fragments.opcode = frame.opcode
            fragments.payload = frame.payload
            return true
        case 0x8:
            try? await self.send(
                self.makeWebSocketFrame(opcode: 0x8, payload: frame.payload),
                on: connection
            )
            connection.cancel()
            return false
        case 0x9:
            try? await self.send(
                self.makeWebSocketFrame(opcode: 0xA, payload: frame.payload),
                on: connection
            )
            return true
        case 0xA:
            return true
        default:
            throw URLError(.cannotParseResponse)
        }
    }

    private func handleCompletedWebSocketPayload(
        opcode: UInt8,
        payload: Data,
        connection: NWConnection,
        accountState: OpenRouterGatewayAccountState
    ) async throws -> Bool {
        if let closeCode = self.immediateCloseCodeForCompletedWebSocketOpcode(opcode) {
            try await self.send(
                self.makeWebSocketFrame(
                    opcode: 0x8,
                    payload: self.makeWebSocketClosePayload(code: closeCode)
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
            let closeCode = try await self.streamWebSocketBridge(
                text: text,
                connection: connection,
                accountState: accountState
            )
            try await self.send(
                self.makeWebSocketFrame(
                    opcode: 0x8,
                    payload: self.makeWebSocketClosePayload(code: closeCode)
                ),
                on: connection
            )
            connection.cancel()
            return false
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func immediateCloseCodeForCompletedWebSocketOpcode(_ opcode: UInt8) -> UInt16? {
        switch opcode {
        case 0x2:
            return 1003
        default:
            return nil
        }
    }

    private func streamWebSocketBridge(
        text: String,
        connection: NWConnection,
        accountState: OpenRouterGatewayAccountState
    ) async throws -> UInt16 {
        let body = Data(text.utf8)
        let result = try await self.proxyResponsesRequest(
            body: body,
            route: "/v1/responses",
            inboundHeaders: [:],
            accountState: accountState
        )

        guard (200...299).contains(result.response.statusCode) else {
            let errorBody = try await self.readAllBytes(from: result.bytes)
            let payload = String(data: errorBody, encoding: .utf8) ?? #"{"error":{"message":"OpenRouter upstream error"}}"#
            try await self.send(
                self.makeWebSocketFrame(opcode: 0x1, payload: Data(payload.utf8)),
                on: connection
            )
            return 1011
        }

        if result.response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            var buffer = Data()
            let delimiter = Data("\n\n".utf8)

            for try await byte in result.bytes {
                buffer.append(byte)

                while let range = buffer.range(of: delimiter) {
                    let eventData = buffer.subdata(in: 0..<range.lowerBound)
                    buffer.removeSubrange(0..<range.upperBound)

                    guard let eventText = String(data: eventData, encoding: .utf8) else {
                        continue
                    }
                    let payload = self.ssePayload(from: eventText)
                    guard payload.isEmpty == false else { continue }
                    if payload == "[DONE]" {
                        return 1000
                    }
                    try await self.send(
                        self.makeWebSocketFrame(opcode: 0x1, payload: Data(payload.utf8)),
                        on: connection
                    )
                }
            }

            if buffer.isEmpty == false, let eventText = String(data: buffer, encoding: .utf8) {
                let payload = self.ssePayload(from: eventText)
                if payload.isEmpty == false && payload != "[DONE]" {
                    try await self.send(
                        self.makeWebSocketFrame(opcode: 0x1, payload: Data(payload.utf8)),
                        on: connection
                    )
                }
            }
            return 1000
        }

        let responseBody = try await self.readAllBytes(from: result.bytes)
        try await self.send(
            self.makeWebSocketFrame(opcode: 0x1, payload: responseBody),
            on: connection
        )
        return 1000
    }

    private func collectWebSocketBridgeProbe(
        text: String,
        accountState: OpenRouterGatewayAccountState
    ) async throws -> OpenRouterGatewayWebSocketProbeResult {
        let body = Data(text.utf8)
        let result = try await self.proxyResponsesRequest(
            body: body,
            route: "/v1/responses",
            inboundHeaders: [:],
            accountState: accountState
        )

        guard (200...299).contains(result.response.statusCode) else {
            let errorBody = try await self.readAllBytes(from: result.bytes)
            let payload = String(data: errorBody, encoding: .utf8) ?? #"{"error":{"message":"OpenRouter upstream error"}}"#
            return OpenRouterGatewayWebSocketProbeResult(events: [payload], closeCode: 1011)
        }

        if result.response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            let events = try await self.collectSSEEvents(from: result.bytes)
            if let last = events.last, last == "[DONE]" {
                return OpenRouterGatewayWebSocketProbeResult(events: Array(events.dropLast()), closeCode: 1000)
            }
            return OpenRouterGatewayWebSocketProbeResult(events: events, closeCode: 1000)
        }

        let responseBody = try await self.readAllBytes(from: result.bytes)
        let payload = String(data: responseBody, encoding: .utf8) ?? "{}"
        return OpenRouterGatewayWebSocketProbeResult(events: [payload], closeCode: 1000)
    }

    private func collectSSEEvents(from bytes: URLSession.AsyncBytes) async throws -> [String] {
        var buffer = Data()
        var events: [String] = []
        let delimiter = Data("\n\n".utf8)

        for try await byte in bytes {
            buffer.append(byte)

            while let range = buffer.range(of: delimiter) {
                let eventData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)

                guard let eventText = String(data: eventData, encoding: .utf8) else {
                    continue
                }
                let payload = self.ssePayload(from: eventText)
                guard payload.isEmpty == false else { continue }
                events.append(payload)
            }
        }

        if buffer.isEmpty == false, let eventText = String(data: buffer, encoding: .utf8) {
            let payload = self.ssePayload(from: eventText)
            if payload.isEmpty == false {
                events.append(payload)
            }
        }

        return events
    }

    private func ssePayload(from event: String) -> String {
        let dataLines = event
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                if line.hasPrefix("data:") {
                    return line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                }
                return nil
            }

        if dataLines.isEmpty == false {
            return dataLines.joined(separator: "\n")
        }

        return event.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentAccountState() -> OpenRouterGatewayAccountState? {
        self.stateQueue.sync {
            // Keep serving requests as long as a persisted OpenRouter account/model exists.
            // Desktop can still hit the stable localhost gateway during request-boundary
            // transitions even after the menu selection has moved away from OpenRouter.
            guard let provider = self.provider,
                  let selection = provider.openRouterServiceableSelection else {
                return nil
            }
            return OpenRouterGatewayAccountState(
                account: selection.account,
                modelID: selection.modelID
            )
        }
    }

    private func requireCurrentAccountState() throws -> OpenRouterGatewayAccountState {
        if let state = self.currentAccountState() {
            return state
        }
        throw URLError(.userAuthenticationRequired)
    }

    private func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
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

    private func renderResponseHead(statusCode: Int, headers: [String: String], bodyLength: Int) -> String {
        var lines = ["HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)"]
        for (name, value) in headers {
            lines.append("\(name): \(value)")
        }
        if headers.keys.contains(where: { $0.lowercased() == "content-length" }) == false {
            lines.append("Content-Length: \(bodyLength)")
        }
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private func makeWebSocketHandshakeResponse(for secWebSocketKey: String) -> String {
        [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(self.secWebSocketAcceptValue(for: secWebSocketKey))",
            "",
            "",
        ].joined(separator: "\r\n")
    }

    private func secWebSocketAcceptValue(for key: String) -> String {
        let value = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
    }

    private func parseNextWebSocketFrame(from buffer: inout Data) throws -> ParsedOpenRouterWebSocketFrame? {
        guard buffer.count >= 2 else { return nil }

        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let isFinal = (first & 0x80) != 0
        let reservedBits = first & 0x70
        let opcode = first & 0x0F
        let isMasked = (second & 0x80) != 0

        guard reservedBits == 0, isMasked else {
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

        guard buffer.count >= cursor + 4 + payloadLength else { return nil }
        let mask = Array(buffer[cursor..<(cursor + 4)])
        cursor += 4

        var payload = Data(buffer[cursor..<(cursor + payloadLength)])
        for index in payload.indices {
            let offset = payload.distance(from: payload.startIndex, to: index)
            payload[index] ^= mask[offset % 4]
        }

        buffer.removeSubrange(0..<(cursor + payloadLength))
        return ParsedOpenRouterWebSocketFrame(opcode: opcode, payload: payload, isFinal: isFinal)
    }

    private func makeWebSocketFrame(opcode: UInt8, payload: Data = Data(), isFinal: Bool = true) -> Data {
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

    private func readAllBytes(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }
}
