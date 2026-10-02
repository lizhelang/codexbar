import Foundation
import XCTest

final class ChatCompletionsGatewayServiceTests: CodexBarTestCase {
    func testBufferedRequestTranslatesResponsesToChatAndStreamsBack() async throws {
        let service = self.makeService()
        let provider = self.makeChatProvider(model: "deepseek-chat")
        service.updateState(provider: provider, isActiveProvider: true)

        let requestBody = #"{"model":"deepseek-chat","input":"hello","stream":true}"#

        var capturedURL: URL?
        var capturedAuthorization: String?
        var capturedBody = Data()

        MockURLProtocol.handler = { request in
            capturedURL = request.url
            capturedAuthorization = request.value(forHTTPHeaderField: "authorization")
            if let body = URLProtocol.property(
                forKey: ChatCompletionsGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = body
            }

            let sse = """
            data: {"choices":[{"delta":{"content":"Hello "}}]}

            data: {"choices":[{"delta":{"content":"world"}}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}

            data: [DONE]

            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(sse.utf8))
        }

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1458",
                        "Authorization: Bearer sk-chat-primary",
                        "Content-Type: application/json",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: requestBody
                )
            )
        )

        let response = try await service.bufferedResponsesRequestForTesting(request)
        let bodyText = try XCTUnwrap(String(data: response.body, encoding: .utf8))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(capturedURL?.absoluteString, "https://api.example.invalid/v1/chat/completions")
        XCTAssertEqual(capturedAuthorization, "Bearer sk-chat-primary")

        let chatRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: capturedBody) as? [String: Any])
        XCTAssertEqual(chatRequest["model"] as? String, "deepseek-chat")
        XCTAssertEqual(chatRequest["stream"] as? Bool, true)

        XCTAssertTrue(bodyText.contains(#""type":"response.created""#))
        XCTAssertTrue(bodyText.contains(#""type":"response.output_text.delta""#))
        XCTAssertTrue(bodyText.contains(#""type":"response.completed""#))
        XCTAssertTrue(bodyText.contains("data: [DONE]"))
    }

    func testBufferedRequestPropagatesUpstreamError() async throws {
        let service = self.makeService()
        let provider = self.makeChatProvider(model: "deepseek-chat")
        service.updateState(provider: provider, isActiveProvider: true)

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }

        let requestBody = #"{"input":"hello"}"#
        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1458",
                        "Authorization: Bearer sk-chat-primary",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                    ],
                    body: requestBody
                )
            )
        )

        let response = try await service.bufferedResponsesRequestForTesting(request)
        XCTAssertEqual(response.statusCode, 401)
        let bodyText = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(bodyText.contains("bad key"))
    }

    func testBufferedRequestWrapsNonStreamingChatCompletion() async throws {
        let service = self.makeService()
        let provider = self.makeChatProvider(model: "deepseek-chat")
        service.updateState(provider: provider, isActiveProvider: true)

        MockURLProtocol.handler = { request in
            let body = """
            {
              "id": "chatcmpl-test",
              "object": "chat.completion",
              "choices": [
                {
                  "message": {
                    "role": "assistant",
                    "content": "plain json answer"
                  },
                  "finish_reason": "stop"
                }
              ],
              "usage": {
                "prompt_tokens": 4,
                "completion_tokens": 3,
                "total_tokens": 7
              }
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        let requestBody = #"{"input":"hello","stream":true}"#
        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1458",
                        "Authorization: Bearer sk-chat-primary",
                        "Content-Length: \(Data(requestBody.utf8).count)",
                    ],
                    body: requestBody
                )
            )
        )

        let response = try await service.bufferedResponsesRequestForTesting(request)
        let bodyText = try XCTUnwrap(String(data: response.body, encoding: .utf8))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/event-stream")
        XCTAssertTrue(bodyText.contains(#""type":"response.completed""#))
        XCTAssertTrue(bodyText.contains("plain json answer"))
        XCTAssertTrue(bodyText.contains("data: [DONE]"))
    }

    func testRejectsMissingWrongAndStaleCredentialsBeforeContactingUpstream() async throws {
        let service = self.makeService()
        service.updateState(provider: self.makeChatProvider(model: "deepseek-chat"), isActiveProvider: true)
        MockURLProtocol.handler = { _ in
            XCTFail("Rejected requests must not contact the upstream")
            throw URLError(.badServerResponse)
        }
        for authorization in [nil, "Bearer wrong-key"] {
            let request = ParsedGatewayRequest(
                method: "POST", path: "/v1/responses",
                headers: authorization.map { ["authorization": $0] } ?? [:], body: Data(#"{"input":"hello"}"#.utf8)
            )
            do {
                _ = try await service.bufferedResponsesRequestForTesting(request)
                XCTFail("Missing or invalid credentials should fail")
            } catch let error as ChatCompletionsGatewayRequestError {
                XCTAssertEqual(error.statusCode, 401)
            }
        }
        service.updateState(provider: nil, isActiveProvider: false)
        do {
            _ = try await service.bufferedResponsesRequestForTesting(ParsedGatewayRequest(
                method: "POST", path: "/v1/responses", headers: ["authorization": "Bearer sk-chat-primary"],
                body: Data(#"{"input":"hello"}"#.utf8)
            ))
            XCTFail("A previously selected provider's token must stop working")
        } catch let error as ChatCompletionsGatewayRequestError {
            XCTAssertEqual(error.statusCode, 401)
        }
    }

    func testRejectsModelMismatchInsteadOfSubstitutingConfiguredModel() async throws {
        let service = self.makeService()
        service.updateState(provider: self.makeChatProvider(model: "deepseek-chat"), isActiveProvider: true)
        MockURLProtocol.handler = { _ in
            XCTFail("A model mismatch must fail before contacting the upstream")
            throw URLError(.badServerResponse)
        }
        for body in [#"{"model":"gpt-5","input":"hello"}"#,
                     #"{"type":"response.create","response":{"model":"gpt-5","input":"hello"}}"#] {
            do {
                _ = try await service.bufferedResponsesRequestForTesting(ParsedGatewayRequest(
                    method: "POST", path: "/v1/responses", headers: ["authorization": "Bearer sk-chat-primary"],
                    body: Data(body.utf8)
                ))
                XCTFail("A mismatched model should fail")
            } catch let error as ChatCompletionsGatewayRequestError {
                XCTAssertEqual(error.statusCode, 400)
            }
        }
    }

    func testGatewayRetainsCustomToolTypeAcrossBothUpstreamResponseModes() async throws {
        let service = self.makeService()
        service.updateState(provider: self.makeChatProvider(model: "deepseek-chat"), isActiveProvider: true)
        for streaming in [false, true] {
            MockURLProtocol.handler = { request in
                let bodyData = try XCTUnwrap(URLProtocol.property(
                    forKey: ChatCompletionsGatewayService.mockRequestBodyPropertyKey, in: request
                ) as? Data)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
                XCTAssertEqual(tools.first?["type"] as? String, "function")
                let function: [String: Any] = ["name": "exec", "arguments": #"{"input":"sw_vers"}"#]
                let upstream: [String: Any] = streaming
                    ? ["choices": [["delta": ["tool_calls": [["index": 0, "id": "c1", "function": function]]], "finish_reason": "tool_calls"]]]
                    : ["choices": [["message": ["tool_calls": [["id": "c1", "function": function]]], "finish_reason": "tool_calls"]]]
                let json = try JSONSerialization.data(withJSONObject: upstream)
                let data = streaming ? Data("data: \(String(decoding: json, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8) : json
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!, data)
            }
            let response = try await service.bufferedResponsesRequestForTesting(ParsedGatewayRequest(
                method: "POST", path: "/v1/responses", headers: ["authorization": "Bearer sk-chat-primary"],
                body: Data(#"{"model":"deepseek-chat","input":"run it","stream":true,"tools":[{"type":"custom","name":"exec"}]}"#.utf8)
            ))
            let text = String(decoding: response.body, as: UTF8.self)
            XCTAssertTrue(text.contains("custom_tool_call"))
            XCTAssertTrue(text.contains(#""input":"sw_vers""#))
            XCTAssertFalse(text.contains(#""type":"function_call""#))
        }
    }

    func testGatewayParsesMultipleCRLFFramesAndDone() async throws {
        let service = self.makeService()
        service.updateState(provider: self.makeChatProvider(model: "deepseek-chat"), isActiveProvider: true)
        for newline in ["\r\n", "\n", "\r"] {
            MockURLProtocol.handler = { request in
                let frames = [
                    #"data: {"choices":[{"delta":{"content":"Hello "}}]}"#,
                    #"data: {"choices":[{"delta":{"content":"world"},"finish_reason":"stop"}]}"#,
                    #"data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":2}}"#,
                    "data: [DONE]",
                ]
                let body = frames.joined(separator: newline + newline) + newline + newline
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "text/event-stream"])!, Data(body.utf8))
            }
            let response = try await service.bufferedResponsesRequestForTesting(ParsedGatewayRequest(
                method: "POST", path: "/v1/responses", headers: ["authorization": "Bearer sk-chat-primary"],
                body: Data(#"{"model":"deepseek-chat","input":"hello","stream":true}"#.utf8)
            ))
            let text = String(decoding: response.body, as: UTF8.self)
            XCTAssertTrue(text.contains("Hello world"))
            XCTAssertTrue(text.contains(#""type":"response.completed""#))
        }
    }

    func testGatewayRejectsMalformedSSEErrorFramesAndPrematureEOF() async throws {
        let service = self.makeService()
        service.updateState(provider: self.makeChatProvider(model: "deepseek-chat"), isActiveProvider: true)
        let normalToolFrame = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"run","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        let bodies = [
            normalToolFrame + "\n\nevent: error\ndata: {}\n\n",
            normalToolFrame + "\r\n\r\ndata: {broken-json}\r\n\r\ndata: [DONE]\r\n\r\n",
            normalToolFrame + "\n\ndata: {\"error\":{\"message\":\"failed\"}}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\ndata: [DONE]\n\n",
        ]
        for body in bodies {
            MockURLProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                 headerFields: ["Content-Type": "text/event-stream"])!, Data(body.utf8))
            }
            do {
                _ = try await service.bufferedResponsesRequestForTesting(ParsedGatewayRequest(
                    method: "POST", path: "/v1/responses", headers: ["authorization": "Bearer sk-chat-primary"],
                    body: Data(#"{"input":"hello","stream":true}"#.utf8)
                ))
                XCTFail("An invalid or incomplete upstream stream must fail")
            } catch is ResponsesChatCompletionsTranslator.TranslationError {
                // Expected: no successful response containing executable tools is returned.
            }
        }
    }

    // MARK: - Helpers

    private func makeService() -> ChatCompletionsGatewayService {
        ChatCompletionsGatewayService(
            urlSession: self.makeMockSession(),
            runtimeConfiguration: .init(host: "127.0.0.1", port: 1458)
        )
    }

    func testModelCatalogAdvertisesOnlyTheConfiguredCallableModel() async throws {
        let service = self.makeService()
        service.updateState(provider: self.makeChatProvider(model: "selected"), isActiveProvider: true)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"object":"list","data":[{"id":"other"},{"id":"selected","object":"model"}]}"#.utf8))
        }
        let request = ParsedGatewayRequest(method: "GET", path: "/v1/models",
                                           headers: ["authorization": "Bearer sk-chat-primary"], body: Data())
        let response = try await service.modelsResponse(for: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["selected"])
    }

    func testModelCatalogRejectsAConfiguredModelThatIsNoLongerAvailable() async throws {
        let service = self.makeService()
        service.updateState(provider: self.makeChatProvider(model: "old-model"), isActiveProvider: true)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"object":"list","data":[{"id":"new-model"}]}"#.utf8))
        }
        let request = ParsedGatewayRequest(method: "GET", path: "/v1/models",
                                           headers: ["authorization": "Bearer sk-chat-primary"], body: Data())
        do {
            _ = try await service.modelsResponse(for: request)
            XCTFail("Unavailable configured model must not appear as a valid catalog")
        } catch let error as ChatCompletionsGatewayRequestError {
            XCTAssertEqual(error.statusCode, 409)
        }
    }

    private func makeChatProvider(model: String) -> CodexBarProvider {
        let account = CodexBarProviderAccount(
            id: "acct-chat",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-chat-primary"
        )
        return CodexBarProvider(
            id: "deepseek",
            kind: .openAICompatible,
            label: "DeepSeek",
            enabled: true,
            baseURL: "https://api.example.invalid/v1",
            wireAPI: .chat,
            presetID: nil,
            defaultModel: model,
            selectedModelID: model,
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
