import Foundation
import XCTest

final class OpenRouterGatewayServiceTests: CodexBarTestCase {
    func testPostResponsesProbeUsesOpenRouterAccountAndSelectedModel() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "anthropic/claude-3.7-sonnet")
        service.updateState(provider: provider, isActiveProvider: true)
        let requestBody = #"{"model":"gpt-5.4","input":"hello","store":true}"#

        var capturedAuthorization: String?
        var capturedURL: URL?
        var capturedBody = Data()

        MockURLProtocol.handler = { request in
            capturedAuthorization = request.value(forHTTPHeaderField: "authorization")
            capturedURL = request.url
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = body
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"resp_openrouter"}"#.utf8))
        }

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1457",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenRouterGatewayConfiguration.apiKey)",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: requestBody
                )
            )
        )

        let response = try await service.postResponsesProbeForTesting(request: request)
        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedBody) as? [String: Any]
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(capturedAuthorization, "Bearer sk-or-v1-primary")
        XCTAssertEqual(capturedURL?.absoluteString, "https://example.invalid/v1/responses")
        XCTAssertEqual(normalized["model"] as? String, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(normalized["stream"] as? Bool, true)
        XCTAssertEqual(normalized["store"] as? Bool, false)
    }

    func testWebSocketUpgradeProbeSucceedsWithPersistedOpenRouterStateEvenWhenProviderIsInactive() throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "openrouter/elephant-alpha")
        service.updateState(provider: provider, isActiveProvider: false)
        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "GET /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1457",
                        "Upgrade: websocket",
                        "Connection: Upgrade",
                        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                        "Sec-WebSocket-Version: 13",
                    ]
                )
            )
        )

        let response = service.webSocketUpgradeProbeForTesting(request: request)

        XCTAssertEqual(response.statusCode, 101)
        XCTAssertEqual(response.headers["Upgrade"], "websocket")
        XCTAssertEqual(response.headers["Connection"], "Upgrade")
        XCTAssertEqual(response.headers["Sec-WebSocket-Accept"], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testCompactProbeStillTargetsResponsesEndpoint() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "openai/gpt-4.1")
        service.updateState(provider: provider, isActiveProvider: true)
        let requestBody = #"{"model":"gpt-5.4","stream":true,"include":["x"],"input":"compact me"}"#

        var capturedURL: URL?
        var capturedBody = Data()

        MockURLProtocol.handler = { request in
            capturedURL = request.url
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = body
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"type":"response.compaction"}"#.utf8))
        }

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses/compact HTTP/1.1",
                        "Host: 127.0.0.1:1457",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenRouterGatewayConfiguration.apiKey)",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: requestBody
                )
            )
        )

        _ = try await service.postResponsesProbeForTesting(request: request)
        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedBody) as? [String: Any]
        )

        XCTAssertEqual(capturedURL?.absoluteString, "https://example.invalid/v1/responses")
        XCTAssertEqual(normalized["model"] as? String, "openai/gpt-4.1")
        XCTAssertNil(normalized["include"])
        XCTAssertNil(normalized["stream"])
    }

    func testWebSocketBridgeProbeEmitsSSEPayloadsAndClosesNormally() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "openai/gpt-4.1")
        service.updateState(provider: provider, isActiveProvider: true)
        var capturedContentType: String?
        var capturedBody = Data()

        MockURLProtocol.handler = { request in
            capturedContentType = request.value(forHTTPHeaderField: "content-type")
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = body
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = Data(
                """
                data: {"type":"response.created"}

                data: {"type":"response.completed"}

                data: [DONE]

                """.utf8
            )
            return (response, body)
        }

        let result = try await service.bridgeWebSocketTextMessageForTesting(
            #"{"input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}]}"#
        )

        XCTAssertEqual(
            result.events,
            [
                #"{"type":"response.created"}"#,
                #"{"type":"response.completed"}"#,
            ]
        )
        XCTAssertEqual(result.closeCode, 1000)

        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedBody) as? [String: Any]
        )
        let input = try XCTUnwrap(normalized["input"] as? [[String: Any]])
        XCTAssertEqual(capturedContentType, "application/json")
        XCTAssertEqual(normalized["model"] as? String, "openai/gpt-4.1")
        XCTAssertEqual((input.first?["type"] as? String), "message")
    }

    func testWebSocketBridgeProbeUnwrapsResponseCreateEnvelopeAndSynthesizesAssistantMetadata() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "openai/gpt-4.1")
        service.updateState(provider: provider, isActiveProvider: true)
        var capturedBody = Data()

        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = body
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"resp_openrouter"}"#.utf8))
        }

        _ = try await service.bridgeWebSocketTextMessageForTesting(
            #"{"type":"response.create","response":{"input":[{"role":"assistant","content":[{"type":"output_text","text":"Earlier reply","annotations":[]}]}]}}"#
        )

        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedBody) as? [String: Any]
        )
        let input = try XCTUnwrap(normalized["input"] as? [[String: Any]])
        let assistant = try XCTUnwrap(input.first)

        XCTAssertEqual(normalized["model"] as? String, "openai/gpt-4.1")
        XCTAssertEqual(assistant["type"] as? String, "message")
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertEqual(assistant["status"] as? String, "completed")
        XCTAssertEqual(assistant["id"] as? String, "msg_codexbar_0")
    }

    func testBinaryWebSocketFramesFailClosedWithUnsupportedDataCloseCode() {
        let service = self.makeService()

        XCTAssertEqual(service.completedWebSocketCloseCodeProbeForTesting(opcode: 0x2), 1003)
        XCTAssertNil(service.completedWebSocketCloseCodeProbeForTesting(opcode: 0x1))
    }

    func testWebSocketBridgeProbeReturnsErrorPayloadAnd1011WhenUpstreamFails() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "openai/gpt-4.1")
        service.updateState(provider: provider, isActiveProvider: true)

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":{"message":"upstream unavailable"}}"#.utf8))
        }

        let result = try await service.bridgeWebSocketTextMessageForTesting(#"{"input":"hi"}"#)

        XCTAssertEqual(result.events, [#"{"error":{"message":"upstream unavailable"}}"#])
        XCTAssertEqual(result.closeCode, 1011)
    }

    func testModelSwitchAppliesAtNextRequestBoundary() async throws {
        let service = self.makeService()
        var capturedModels: [String] = []
        let firstRequestBody = #"{"input":"first"}"#

        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data,
               let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
               let model = json["model"] as? String {
                capturedModels.append(model)
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"resp_openrouter"}"#.utf8))
        }

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1457",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenRouterGatewayConfiguration.apiKey)",
                        "Content-Length: \(Data(firstRequestBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: firstRequestBody
                )
            )
        )

        service.updateState(
            provider: self.makeOpenRouterProvider(selectedModelID: "anthropic/claude-3.7-sonnet"),
            isActiveProvider: true
        )
        _ = try await service.postResponsesProbeForTesting(request: request)

        service.updateState(
            provider: self.makeOpenRouterProvider(selectedModelID: "google/gemini-2.5-pro"),
            isActiveProvider: true
        )
        _ = try await service.postResponsesProbeForTesting(request: request)

        XCTAssertEqual(
            capturedModels,
            ["anthropic/claude-3.7-sonnet", "google/gemini-2.5-pro"]
        )
    }

    func testInFlightRequestKeepsOriginalModelAfterProviderStateChanges() async throws {
        let service = self.makeService()
        let requestBody = #"{"input":"streaming"}"#
        let requestStarted = DispatchSemaphore(value: 0)
        let allowResponse = DispatchSemaphore(value: 0)
        var capturedModels: [String] = []

        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data,
               let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
               let model = json["model"] as? String {
                capturedModels.append(model)
            }
            requestStarted.signal()
            _ = allowResponse.wait(timeout: .now() + 1)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"resp_openrouter"}"#.utf8))
        }

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1457",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenRouterGatewayConfiguration.apiKey)",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: requestBody
                )
            )
        )

        service.updateState(
            provider: self.makeOpenRouterProvider(selectedModelID: "anthropic/claude-3.7-sonnet"),
            isActiveProvider: true
        )
        let responseTask = Task {
            try await service.postResponsesProbeForTesting(request: request)
        }

        XCTAssertEqual(requestStarted.wait(timeout: .now() + 1), .success)
        service.updateState(
            provider: self.makeOpenRouterProvider(selectedModelID: "google/gemini-2.5-pro"),
            isActiveProvider: true
        )
        allowResponse.signal()

        let response = try await responseTask.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(capturedModels, ["anthropic/claude-3.7-sonnet"])
    }

    func testPostResponsesProbeStillUsesPersistedOpenRouterStateAfterProviderStopsBeingActive() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "openrouter/elephant-alpha")
        let requestBody = #"{"input":"hello"}"#

        var capturedAuthorization: String?
        var capturedBody = Data()

        MockURLProtocol.handler = { request in
            capturedAuthorization = request.value(forHTTPHeaderField: "authorization")
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = body
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"resp_openrouter"}"#.utf8))
        }

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1457",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenRouterGatewayConfiguration.apiKey)",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: requestBody
                )
            )
        )

        service.updateState(provider: provider, isActiveProvider: false)
        let response = try await service.postResponsesProbeForTesting(request: request)
        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedBody) as? [String: Any]
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(capturedAuthorization, "Bearer sk-or-v1-primary")
        XCTAssertEqual(normalized["model"] as? String, "openrouter/elephant-alpha")
    }

    func testPostResponsesProbeNormalizesNestedFunctionToolsAndRawOpenRouterAliases() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "openrouter/elephant-alpha")
        service.updateState(provider: provider, isActiveProvider: true)
        let requestBody = #"""
        {
          "input":"hello",
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"demo_tool",
                "description":"Demo tool",
                "parameters":{
                  "type":"object",
                  "properties":{"query":{"type":"string"}},
                  "required":["query"]
                }
              }
            },
            {"type":"datetime","timezone":"UTC"},
            {"type":"experimental__search_models","max_results":3},
            {"type":"web_search_preview","search_context_size":"high","filters":{"allowed_domains":["example.com"]}},
            {"type":"image_generation","size":"1024x1024","quality":"high"}
          ],
          "tool_choice":{"type":"function","function":{"name":"demo_tool"}}
        }
        """#

        var capturedBody = Data()

        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = body
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"resp_openrouter"}"#.utf8))
        }

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1457",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenRouterGatewayConfiguration.apiKey)",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: requestBody
                )
            )
        )

        _ = try await service.postResponsesProbeForTesting(request: request)

        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedBody) as? [String: Any]
        )
        let tools = try XCTUnwrap(normalized["tools"] as? [[String: Any]])
        let functionTool = try XCTUnwrap(tools.first)
        let datetimeTool = try XCTUnwrap(tools[safe: 1])
        let searchModelsTool = try XCTUnwrap(tools[safe: 2])
        let webSearchTool = try XCTUnwrap(tools[safe: 3])
        let imageGenerationTool = try XCTUnwrap(tools[safe: 4])
        let toolChoice = try XCTUnwrap(normalized["tool_choice"] as? [String: Any])

        XCTAssertEqual(functionTool["type"] as? String, "function")
        XCTAssertEqual(functionTool["name"] as? String, "demo_tool")
        XCTAssertEqual(functionTool["description"] as? String, "Demo tool")
        XCTAssertNil(functionTool["function"])

        XCTAssertEqual(datetimeTool["type"] as? String, "openrouter:datetime")
        XCTAssertEqual((datetimeTool["parameters"] as? [String: Any])?["timezone"] as? String, "UTC")

        XCTAssertEqual(searchModelsTool["type"] as? String, "openrouter:experimental__search_models")
        XCTAssertEqual((searchModelsTool["parameters"] as? [String: Any])?["max_results"] as? Int, 3)

        XCTAssertEqual(webSearchTool["type"] as? String, "web_search_preview")
        XCTAssertEqual(webSearchTool["search_context_size"] as? String, "high")

        XCTAssertEqual(imageGenerationTool["type"] as? String, "image_generation")
        XCTAssertEqual(imageGenerationTool["size"] as? String, "1024x1024")

        XCTAssertEqual(toolChoice["type"] as? String, "function")
        XCTAssertEqual(toolChoice["name"] as? String, "demo_tool")
        XCTAssertNil(toolChoice["function"])
    }

    func testPostResponsesProbeDropsUnknownToolsAndDowngradesUnsupportedToolChoice() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(selectedModelID: "openrouter/elephant-alpha")
        service.updateState(provider: provider, isActiveProvider: true)
        let requestBody = #"""
        {
          "input":"hello",
          "tools":[
            {"type":"mystery_tool","label":"drop-me"},
            {
              "type":"function",
              "function":{
                "name":"demo_tool",
                "description":"Demo tool",
                "parameters":{"type":"object","properties":{},"required":[]}
              }
            }
          ],
          "tool_choice":{"type":"tool","name":"mystery_tool"}
        }
        """#

        var capturedBody = Data()

        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenRouterGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = body
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"resp_openrouter"}"#.utf8))
        }

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1457",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenRouterGatewayConfiguration.apiKey)",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: requestBody
                )
            )
        )

        _ = try await service.postResponsesProbeForTesting(request: request)

        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedBody) as? [String: Any]
        )
        let tools = try XCTUnwrap(normalized["tools"] as? [[String: Any]])

        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "demo_tool")
        XCTAssertEqual(normalized["tool_choice"] as? String, "auto")
    }

    private func makeService() -> OpenRouterGatewayService {
        OpenRouterGatewayService(
            urlSession: self.makeMockSession(),
            runtimeConfiguration: .init(
                host: "127.0.0.1",
                port: 1457,
                upstreamResponsesURL: URL(string: "https://example.invalid/v1/responses")!
            )
        )
    }

    private func makeOpenRouterProvider(selectedModelID: String) -> CodexBarProvider {
        let account = CodexBarProviderAccount(
            id: "acct-openrouter",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary"
        )
        return CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: selectedModelID,
            activeAccountId: account.id,
            accounts: [account]
        )
    }

    private func rawRequest(lines: [String], body: String = "") -> Data {
        var text = lines.joined(separator: "\r\n")
        text += "\r\n\r\n"
        text += body
        return Data(text.utf8)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
