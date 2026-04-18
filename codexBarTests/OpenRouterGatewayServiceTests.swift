import Foundation
import XCTest

final class OpenRouterGatewayServiceTests: CodexBarTestCase {
    func testPostResponsesProbeUsesOpenRouterAccountAndDefaultModel() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(defaultModel: "anthropic/claude-3.7-sonnet")
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

    func testCompactProbeStillTargetsResponsesEndpoint() async throws {
        let service = self.makeService()
        let provider = self.makeOpenRouterProvider(defaultModel: "openai/gpt-4.1")
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
        let provider = self.makeOpenRouterProvider(defaultModel: "openai/gpt-4.1")
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
        let provider = self.makeOpenRouterProvider(defaultModel: "openai/gpt-4.1")
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

    private func makeOpenRouterProvider(defaultModel: String) -> CodexBarProvider {
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
            defaultModel: defaultModel,
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
