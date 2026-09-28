import Foundation
import Network

protocol ChatCompletionsGatewayControlling: AnyObject {
    func startIfNeeded()
    func stop()
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool)
}

enum ChatCompletionsGatewayConfiguration {
    // 用 IPv4 环回地址而不是 "localhost"，理由见 OpenAIAccountGatewayConfiguration.host 的注释：
    // 避免系统代理客户端把例外列表写坏后，"localhost" 解析出的 "::1" 被误路由进代理。
    static let host = "127.0.0.1"
    static let port: UInt16 = 1458

    static var baseURLString: String {
        "http://\(self.host):\(self.port)/v1"
    }
}

struct ChatCompletionsGatewayRuntimeConfiguration {
    var host: String
    var port: UInt16

    static let live = ChatCompletionsGatewayRuntimeConfiguration(
        host: ChatCompletionsGatewayConfiguration.host,
        port: ChatCompletionsGatewayConfiguration.port
    )
}

struct ChatCompletionsGatewayTestResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct ChatCompletionsGatewayRequestError: LocalizedError {
    let statusCode: Int
    let message: String
    var errorDescription: String? { self.message }
}

private struct ChatCompletionsGatewayState {
    let apiKey: String
    let modelID: String
    let baseURL: String
    let quirks: CodexBarChatQuirks
}

/// Local responses->chat/completions translation gateway.
///
/// Mirrors `OpenRouterGatewayService`'s NWListener plumbing, but instead of forwarding
/// Responses requests unchanged it converts them into Chat Completions, talks to the
/// upstream injected via `updateState`, and translates the streamed reply back into
/// Responses SSE events that Codex understands.
final class ChatCompletionsGatewayService: ChatCompletionsGatewayControlling {
    nonisolated static let mockRequestBodyPropertyKey = "codexbar.mockChatCompletionsRequestBody"

    private let listenerQueue = DispatchQueue(label: "lzl.codexbar.chat-completions-gateway.listener")
    private let stateQueue = DispatchQueue(label: "lzl.codexbar.chat-completions-gateway.state")
    private let urlSession: URLSession
    private let runtimeConfiguration: ChatCompletionsGatewayRuntimeConfiguration

    private var listener: NWListener?
    private var provider: CodexBarProvider?

    init(
        urlSession: URLSession? = nil,
        runtimeConfiguration: ChatCompletionsGatewayRuntimeConfiguration = .live
    ) {
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
        self.runtimeConfiguration = runtimeConfiguration
    }

    func startIfNeeded() {
        self.listenerQueue.async {
            guard self.listener == nil else { return }
            do {
                let port = NWEndpoint.Port(rawValue: self.runtimeConfiguration.port)!
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
                let listener = try NWListener(using: parameters)
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
                NSLog("codexbar chat completions gateway failed to start: %@", error.localizedDescription)
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
            self.provider = (provider?.usesChatCompletionsGateway == true) ? provider : nil
        }
    }

    // MARK: - Testing hooks

    func parseRequestForTesting(from data: Data) -> ParsedGatewayRequest? {
        self.parseRequest(from: data)
    }

    func bufferedResponsesRequestForTesting(
        _ request: ParsedGatewayRequest
    ) async throws -> ChatCompletionsGatewayTestResponse {
        let state = try self.validate(request)
        let result = try await self.upstreamChatStream(body: request.body, state: state)
        var body = Data()
        let converter = ResponsesChatCompletionsTranslator.StreamConverter(
            model: state.modelID,
            responseID: ResponsesChatCompletionsTranslator.makeID("resp"),
            reasoningEffort: self.reasoningEffort(fromResponsesBody: request.body),
            supportsReasoning: state.quirks.supportsReasoning,
            customToolNames: self.customToolNames(from: request.body)
        )

        guard (200...299).contains(result.response.statusCode) else {
            let errorBody = try await self.readAllBytes(from: result.bytes)
            return ChatCompletionsGatewayTestResponse(
                statusCode: result.response.statusCode,
                headers: ["Content-Type": result.response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"],
                body: errorBody
            )
        }

        guard self.isEventStream(result.response) else {
            let responseBody = try await self.readAllBytes(from: result.bytes)
            return ChatCompletionsGatewayTestResponse(
                statusCode: 200,
                headers: ["Content-Type": self.isStreamingResponsesRequest(request.body) ? "text/event-stream" : "application/json"],
                body: try self.convertNonStreamingChatResponse(
                    responseBody,
                    state: state,
                    responsesBody: request.body
                )
            )
        }

        for event in converter.startEvents() {
            body.append(ResponsesChatCompletionsTranslator.sseData(for: event))
        }
        for try await chunk in self.upstreamSSEChunks(from: result.bytes) {
            for event in try converter.consume(chunk: chunk) {
                body.append(ResponsesChatCompletionsTranslator.sseData(for: event))
            }
        }
        for event in try converter.finishEvents() {
            body.append(ResponsesChatCompletionsTranslator.sseData(for: event))
        }
        body.append(ResponsesChatCompletionsTranslator.sseDoneData)

        return ChatCompletionsGatewayTestResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: body
        )
    }

    // MARK: - Connection handling

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("codexbar chat completions gateway receive failed: %@", error.localizedDescription)
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
        case ("POST", "/v1/responses"), ("POST", "/v1/responses/compact"):
            Task {
                await self.forwardResponsesRequest(request, on: connection)
            }
        case ("GET", "/v1/models"):
            Task {
                await self.forwardModelsRequest(request, on: connection)
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
            let state = try self.validate(request)
            let result = try await self.upstreamChatStream(body: request.body, state: state)

            guard (200...299).contains(result.response.statusCode) else {
                let errorBody = try await self.readAllBytes(from: result.bytes)
                let contentType = result.response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
                try await self.sendRawResponse(
                    statusCode: result.response.statusCode,
                    contentType: contentType,
                    body: errorBody,
                    on: connection
                )
                return
            }

            if self.isEventStream(result.response) {
                try await self.streamConvertedResponse(
                    upstream: result.bytes,
                    state: state,
                    responsesBody: request.body,
                    on: connection
                )
            } else {
                let responseBody = try await self.readAllBytes(from: result.bytes)
                let converted = try self.convertNonStreamingChatResponse(
                    responseBody,
                    state: state,
                    responsesBody: request.body
                )
                if self.isStreamingResponsesRequest(request.body) {
                    try await self.sendRawResponse(
                        statusCode: 200,
                        contentType: "text/event-stream",
                        body: converted,
                        on: connection
                    )
                } else {
                    try await self.sendRawResponse(
                        statusCode: 200,
                        contentType: "application/json",
                        body: converted,
                        on: connection
                    )
                }
            }
        } catch {
            self.sendGatewayError(error, on: connection)
        }
    }

    private func forwardModelsRequest(_ incomingRequest: ParsedGatewayRequest, on connection: NWConnection) async {
        do {
            let response = try await self.modelsResponse(for: incomingRequest)
            try await self.sendRawResponse(
                statusCode: response.statusCode,
                contentType: response.headers["Content-Type"] ?? "application/json",
                body: response.body,
                on: connection
            )
        } catch {
            self.sendGatewayError(error, on: connection)
        }
    }

    func modelsResponse(for incomingRequest: ParsedGatewayRequest) async throws -> ChatCompletionsGatewayTestResponse {
        let state = try self.validate(incomingRequest)
        guard let url = URL(string: self.normalizedBaseURL(state.baseURL) + "/models") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(state.apiKey)", forHTTPHeaderField: "authorization")
        let (bytes, response) = try await self.urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var body = try await self.readAllBytes(from: bytes)
        if (200...299).contains(httpResponse.statusCode) {
            guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let models = object["data"] as? [[String: Any]] else {
                throw ChatCompletionsGatewayRequestError(statusCode: 502, message: "The upstream model catalog is not a valid model list.")
            }
            guard let selected = models.first(where: { $0["id"] as? String == state.modelID }) else {
                throw ChatCompletionsGatewayRequestError(statusCode: 409, message: "The configured Chat Completions model is not in the upstream model catalog. Update the provider's selected model in Codexbar.")
            }
            // 此网关只服务当前选中的模型，不向客户端广告无法调用的其他模型。
            object["data"] = [selected]
            body = try JSONSerialization.data(withJSONObject: object)
        }
        return ChatCompletionsGatewayTestResponse(
            statusCode: httpResponse.statusCode,
            headers: ["Content-Type": "application/json"], body: body
        )
    }

    private func streamConvertedResponse(
        upstream: URLSession.AsyncBytes,
        state: ChatCompletionsGatewayState,
        responsesBody: Data,
        on connection: NWConnection
    ) async throws {
        let head = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        try await self.send(Data(head.utf8), on: connection)

        let converter = ResponsesChatCompletionsTranslator.StreamConverter(
            model: state.modelID,
            responseID: ResponsesChatCompletionsTranslator.makeID("resp"),
            reasoningEffort: self.reasoningEffort(fromResponsesBody: responsesBody),
            supportsReasoning: state.quirks.supportsReasoning,
            customToolNames: self.customToolNames(from: responsesBody)
        )

        do {
            for event in converter.startEvents() {
                try await self.send(ResponsesChatCompletionsTranslator.sseData(for: event), on: connection)
            }
            for try await chunk in self.upstreamSSEChunks(from: upstream) {
                for event in try converter.consume(chunk: chunk) {
                    try await self.send(ResponsesChatCompletionsTranslator.sseData(for: event), on: connection)
                }
            }
            for event in try converter.finishEvents() {
                try await self.send(ResponsesChatCompletionsTranslator.sseData(for: event), on: connection)
            }
            try await self.send(ResponsesChatCompletionsTranslator.sseDoneData, on: connection)
        } catch {
            let message = (error as? ResponsesChatCompletionsTranslator.TranslationError)?.localizedDescription
                ?? "The upstream Chat Completions stream could not be completed."
            try? await self.send(ResponsesChatCompletionsTranslator.sseData(for: converter.failureEvent(message: message)), on: connection)
        }
        connection.cancel()
    }

    private func upstreamChatStream(
        body: Data,
        state: ChatCompletionsGatewayState
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        let responsesObject = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let chatBody = try ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: responsesObject,
            model: state.modelID,
            quirks: state.quirks,
            forceStream: true
        )
        guard let chatData = try? JSONSerialization.data(withJSONObject: chatBody),
              let url = URL(string: self.normalizedBaseURL(state.baseURL) + state.quirks.chatCompletionsPathSuffix) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = chatData
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(chatData, forKey: Self.mockRequestBodyPropertyKey, in: mutableRequest)
        request = mutableRequest as URLRequest
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(state.apiKey)", forHTTPHeaderField: "authorization")

        let (bytes, response) = try await self.urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (httpResponse, bytes)
    }

    private enum SSEChunk {
        case ignored
        case done
        case payload([String: Any])
    }

    /// Parse SSE lines, accepting LF, CRLF and CR without joining separate events.
    private func upstreamSSEChunks(
        from bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            Task {
                var line = Data()
                var eventLines: [String] = []
                var previousWasCR = false
                func consumeLine() throws -> Bool {
                    guard let text = String(data: line, encoding: .utf8) else {
                        throw ResponsesChatCompletionsTranslator.TranslationError.invalidUpstream("invalid UTF-8 in SSE frame")
                    }
                    line.removeAll(keepingCapacity: true)
                    if !text.isEmpty {
                        eventLines.append(text)
                        return false
                    }
                    let event = try self.decodeSSEChunk(eventLines)
                    eventLines.removeAll(keepingCapacity: true)
                    switch event {
                    case .ignored: return false
                    case .done: return true
                    case let .payload(chunk):
                        continuation.yield(chunk)
                        return false
                    }
                }
                do {
                    for try await byte in bytes {
                        if byte == 10 && previousWasCR {
                            previousWasCR = false
                            continue
                        }
                        previousWasCR = byte == 13
                        if byte == 10 || byte == 13 {
                            if try consumeLine() {
                                continuation.finish()
                                return
                            }
                        } else {
                            line.append(byte)
                        }
                    }
                    // Dispatch the last frame even when the provider omits the trailing blank line.
                    if !line.isEmpty { _ = try consumeLine() }
                    switch try self.decodeSSEChunk(eventLines) {
                    case let .payload(chunk): continuation.yield(chunk)
                    case .ignored, .done: break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func decodeSSEChunk(_ lines: [String]) throws -> SSEChunk {
        if lines.contains(where: { $0.hasPrefix("event:") && $0.dropFirst("event:".count).trimmingCharacters(in: .whitespaces) == "error" }) {
            throw ResponsesChatCompletionsTranslator.TranslationError.invalidUpstream("provider returned an SSE error event")
        }
        let payload = lines.compactMap { line -> String? in
            guard line == "data" || line.hasPrefix("data:") else { return nil }
            if line == "data" { return "" }
            let value = line.dropFirst("data:".count)
            return String(value.first == " " ? value.dropFirst() : value)
        }.joined(separator: "\n")
        if payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ignored }
        if payload == "[DONE]" { return .done }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            throw ResponsesChatCompletionsTranslator.TranslationError.invalidUpstream("malformed JSON in SSE frame")
        }
        return .payload(object)
    }

    private func reasoningEffort(fromResponsesBody body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let reasoning = object["reasoning"] as? [String: Any],
              let effort = reasoning["effort"] as? String else {
            return nil
        }
        return effort
    }

    private func isStreamingResponsesRequest(_ body: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return true
        }
        return object["stream"] as? Bool ?? true
    }

    private func isEventStream(_ response: HTTPURLResponse) -> Bool {
        response
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/event-stream") == true
    }

    private func convertNonStreamingChatResponse(
        _ body: Data,
        state: ChatCompletionsGatewayState,
        responsesBody: Data
    ) throws -> Data {
        guard let chatObject = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw ResponsesChatCompletionsTranslator.TranslationError.invalidUpstream("malformed JSON completion")
        }
        let envelope = try ResponsesChatCompletionsTranslator.responsesEnvelope(
            fromChatCompletion: chatObject,
            model: state.modelID,
            responseID: ResponsesChatCompletionsTranslator.makeID("resp"),
            reasoningEffort: self.reasoningEffort(fromResponsesBody: responsesBody),
            customToolNames: self.customToolNames(from: responsesBody)
        )

        if self.isStreamingResponsesRequest(responsesBody) {
            var data = Data()
            data.append(ResponsesChatCompletionsTranslator.sseData(for: [
                "type": "response.completed",
                "response": envelope,
            ]))
            data.append(ResponsesChatCompletionsTranslator.sseDoneData)
            return data
        }

        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data("{}".utf8)
    }

    private func customToolNames(from body: Data) -> Set<String> {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return ResponsesChatCompletionsTranslator.customToolNames(fromResponses: object)
    }

    private func validate(_ request: ParsedGatewayRequest) throws -> ChatCompletionsGatewayState {
        guard let state = self.currentState(),
              request.headers["authorization"] == "Bearer " + state.apiKey else {
            throw ChatCompletionsGatewayRequestError(statusCode: 401, message: "A valid bearer token for the active Chat Completions provider is required.")
        }
        if request.method.uppercased() == "POST" {
            guard var object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
                throw ChatCompletionsGatewayRequestError(statusCode: 400, message: "The request body must be a JSON object.")
            }
            if object["type"] as? String == "response.create", let response = object["response"] as? [String: Any] {
                object = response
            }
            if let model = object["model"], (model as? String) != state.modelID {
                throw ChatCompletionsGatewayRequestError(statusCode: 400, message: "The requested model does not match the active Chat Completions provider. Select the provider's configured model and start a new Codex conversation.")
            }
        }
        return state
    }

    private func sendGatewayError(_ error: Error, on connection: NWConnection) {
        let requestError = error as? ChatCompletionsGatewayRequestError
        let translationError = error as? ResponsesChatCompletionsTranslator.TranslationError
        let message = requestError?.message ?? translationError?.localizedDescription
            ?? "Codexbar Chat Completions gateway failed to reach upstream."
        let object = ["error": ["message": message]]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        self.sendJSONResponse(
            on: connection, statusCode: requestError?.statusCode ?? (translationError == nil ? 502 : 400),
            body: String(decoding: data, as: UTF8.self)
        )
    }

    private func normalizedBaseURL(_ baseURL: String) -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    // MARK: - State

    private func currentState() -> ChatCompletionsGatewayState? {
        self.stateQueue.sync {
            guard let provider = self.provider,
                  let selection = provider.chatCompletionsServiceableSelection,
                  let apiKey = selection.account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  apiKey.isEmpty == false else {
                return nil
            }
            return ChatCompletionsGatewayState(
                apiKey: apiKey,
                modelID: selection.modelID,
                baseURL: selection.baseURL,
                quirks: CodexBarProviderPresetCatalog.quirks(forPresetID: provider.presetID)
            )
        }
    }

    // MARK: - HTTP writing

    private func sendRawResponse(
        statusCode: Int,
        contentType: String,
        body: Data,
        on connection: NWConnection
    ) async throws {
        let head = [
            "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        try await self.send(Data(head.utf8) + body, on: connection)
        connection.cancel()
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
