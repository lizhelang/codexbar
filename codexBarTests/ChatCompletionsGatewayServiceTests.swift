import Foundation
import XCTest

final class ChatCompletionsGatewayServiceTests: CodexBarTestCase {
    func testBufferedRequestTranslatesResponsesToChatAndStreamsBack() async throws {
        let service = self.makeService()
        let provider = self.makeChatProvider(model: "deepseek-chat")
        service.updateState(provider: provider, isActiveProvider: true)

        let requestBody = #"{"model":"gpt-5","input":"hello","stream":true}"#

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

    // MARK: - Helpers

    private func makeService() -> ChatCompletionsGatewayService {
        ChatCompletionsGatewayService(
            urlSession: self.makeMockSession(),
            runtimeConfiguration: .init(host: "127.0.0.1", port: 1458)
        )
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
