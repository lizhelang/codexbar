import Foundation
import XCTest

final class OpenAIAccountGatewayServiceTests: CodexBarTestCase {
    func testResponsesPOSTRecordsRouteForStickySession() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)

        let account = TokenAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: ok\n\n".utf8))
        }

        _ = try await self.postToGateway(
            service: service,
            stickyKey: "thread-aggregate-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        let routeHistory = routeJournalStore.routeHistory()
        XCTAssertEqual(routeHistory.count, 1)
        XCTAssertEqual(routeHistory.first?.threadID, "thread-aggregate-1")
        XCTAssertEqual(routeHistory.first?.accountID, "acct-alpha")
    }

    func testResponsesProbeGETBuildsWebSocketHandshakeWhenHeadersAndAccountExist() async throws {
        let service = self.makeService()

        let account = TokenAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "GET /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Connection: Upgrade",
                        "Upgrade: websocket",
                        "Sec-WebSocket-Version: 13",
                        "Sec-WebSocket-Key: dGVzdC1jb2RleGJhcg==",
                    ]
                )
            )
        )

        let response = service.webSocketUpgradeProbeForTesting(request: request)

        XCTAssertEqual(response.statusCode, 101)
        XCTAssertEqual(
            response.headers["Sec-WebSocket-Accept"],
            "jbsNjU5oGfarrt3XvjT/Dv7jeRU="
        )
        XCTAssertEqual(response.headers["Upgrade"], "websocket")
        XCTAssertEqual(response.headers["Connection"], "Upgrade")
        XCTAssertTrue(response.body.isEmpty)
    }

    func testResponsesPOSTPrefersEarlierResetWhenWeightedQuotaTies() async throws {
        let service = self.makeService()

        let laterResetPlus = TokenAccount(
            email: "plus@example.com",
            accountId: "acct-plus",
            openAIAccountId: "openai-plus",
            accessToken: "token-plus",
            refreshToken: "refresh-plus",
            idToken: "id-plus",
            planType: "plus",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90,
            primaryResetAt: Date(timeIntervalSinceNow: 2 * 60 * 60),
            secondaryResetAt: Date(timeIntervalSinceNow: 7 * 24 * 60 * 60)
        )
        let earlierResetFree = TokenAccount(
            email: "free@example.com",
            accountId: "acct-free",
            openAIAccountId: "openai-free",
            accessToken: "token-free",
            refreshToken: "refresh-free",
            idToken: "id-free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 60 * 60),
            secondaryResetAt: Date(timeIntervalSinceNow: 6 * 24 * 60 * 60)
        )

        service.updateState(
            accounts: [laterResetPlus, earlierResetFree],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.tieBreakObserved")
        var forwardedAuthorizations: [String] = []
        var forwardedAccountIDs: [String] = []

        MockURLProtocol.handler = { request in
            observedQueue.sync {
                forwardedAuthorizations.append(request.value(forHTTPHeaderField: "authorization") ?? "")
                forwardedAccountIDs.append(request.value(forHTTPHeaderField: "chatgpt-account-id") ?? "")
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: ok\n\n".utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "session-reset-tie",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: ok\n\n")
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-free"]
        )
        XCTAssertEqual(
            observedQueue.sync { forwardedAccountIDs },
            ["openai-free"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-free")
    }

    func testResponsesPOSTFailoverRebindsStickySessionAndRewritesHeaders() async throws {
        let service = self.makeService()

        let primary = TokenAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        let secondary = TokenAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )

        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.observed")
        var forwardedURLs: [String] = []
        var forwardedAuthorizations: [String] = []
        var forwardedAccountIDs: [String] = []
        var forwardedOriginators: [String] = []
        var forwardedBodies: [[String: Any]] = []

        MockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            let accountID = request.value(forHTTPHeaderField: "chatgpt-account-id") ?? ""
            let originator = request.value(forHTTPHeaderField: "originator") ?? ""
            let bodyData =
                request.httpBody ??
                (URLProtocol.property(
                    forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                    in: request
                ) as? Data) ??
                Data()
            let body =
                (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ??
                [:]

            observedQueue.sync {
                forwardedURLs.append(url)
                forwardedAuthorizations.append(authorization)
                forwardedAccountIDs.append(accountID)
                forwardedOriginators.append(originator)
                forwardedBodies.append(body)
            }

            let statusCode: Int
            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                statusCode = 429
                payload = "retry alpha"
            case "Bearer token-beta":
                statusCode = 200
                payload = "data: ok\n\n"
            default:
                statusCode = 500
                payload = "unexpected"
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(payload.utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            stickyKey: "session-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}],"service_tier":"priority","max_output_tokens":128,"temperature":0.7,"top_p":0.9,"stream":false}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            stickyKey: "session-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"again"}]}],"service_tier":"priority","max_output_tokens":64,"temperature":0.2,"top_p":0.5}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(firstResponse.body, "data: ok\n\n")
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(secondResponse.body, "data: ok\n\n")

        let observed = observedQueue.sync {
            (
                forwardedURLs,
                forwardedAuthorizations,
                forwardedAccountIDs,
                forwardedOriginators,
                forwardedBodies
            )
        }

        XCTAssertEqual(
            observed.0,
            [
                "https://example.invalid/v1/responses",
                "https://example.invalid/v1/responses",
                "https://example.invalid/v1/responses",
            ]
        )
        XCTAssertEqual(
            observed.1,
            ["Bearer token-alpha", "Bearer token-beta", "Bearer token-beta"]
        )
        XCTAssertEqual(
            observed.2,
            ["openai-alpha", "openai-beta", "openai-beta"]
        )
        XCTAssertEqual(
            observed.3,
            ["codexbar", "codexbar", "codexbar"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")

        self.assertNormalizedBody(observed.4[0], expectedText: "hello", expectedServiceTier: "priority")
        self.assertNormalizedBody(observed.4[1], expectedText: "hello", expectedServiceTier: "priority")
        self.assertNormalizedBody(observed.4[2], expectedText: "again", expectedServiceTier: "priority")
    }

    func testResponsesCompactPOSTUsesCompactUpstreamAndRetainsFailoverSemantics() async throws {
        let service = self.makeService()

        let primary = TokenAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        let secondary = TokenAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )

        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.compactObserved")
        var forwardedURLs: [String] = []
        var forwardedAuthorizations: [String] = []
        var forwardedAccountIDs: [String] = []
        var forwardedOriginators: [String] = []
        var forwardedBodies: [[String: Any]] = []

        MockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            let accountID = request.value(forHTTPHeaderField: "chatgpt-account-id") ?? ""
            let originator = request.value(forHTTPHeaderField: "originator") ?? ""
            let bodyData =
                request.httpBody ??
                (URLProtocol.property(
                    forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                    in: request
                ) as? Data) ??
                Data()
            let body =
                (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ??
                [:]

            observedQueue.sync {
                forwardedURLs.append(url)
                forwardedAuthorizations.append(authorization)
                forwardedAccountIDs.append(accountID)
                forwardedOriginators.append(originator)
                forwardedBodies.append(body)
            }

            let statusCode: Int
            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                statusCode = 429
                payload = "retry alpha compact"
            case "Bearer token-beta":
                statusCode = 200
                payload = #"{"ok":true}"#
            default:
                statusCode = 500
                payload = "unexpected"
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(payload.utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "compact-session-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact hello"}]}],"service_tier":"priority","store":true,"max_output_tokens":128,"temperature":0.7,"top_p":0.9,"stream":false,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"parallel_tool_calls":true}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "compact-session-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact again"}]}],"service_tier":"priority","store":true,"max_output_tokens":64,"temperature":0.2,"top_p":0.5,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"parallel_tool_calls":true}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(firstResponse.body, #"{"ok":true}"#)
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(secondResponse.body, #"{"ok":true}"#)

        let observed = observedQueue.sync {
            (
                forwardedURLs,
                forwardedAuthorizations,
                forwardedAccountIDs,
                forwardedOriginators,
                forwardedBodies
            )
        }

        XCTAssertEqual(
            observed.0,
            [
                "https://example.invalid/v1/responses/compact",
                "https://example.invalid/v1/responses/compact",
                "https://example.invalid/v1/responses/compact",
            ]
        )
        XCTAssertEqual(
            observed.1,
            ["Bearer token-alpha", "Bearer token-beta", "Bearer token-beta"]
        )
        XCTAssertEqual(
            observed.2,
            ["openai-alpha", "openai-beta", "openai-beta"]
        )
        XCTAssertEqual(
            observed.3,
            ["codexbar", "codexbar", "codexbar"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")

        self.assertCompactBody(observed.4[0], expectedText: "compact hello", expectedServiceTier: "priority")
        self.assertCompactBody(observed.4[1], expectedText: "compact hello", expectedServiceTier: "priority")
        self.assertCompactBody(observed.4[2], expectedText: "compact again", expectedServiceTier: "priority")
    }

    private func postToGateway(
        service: OpenAIAccountGatewayService,
        path: String = "/v1/responses",
        stickyKey: String,
        body: String
    ) async throws -> (statusCode: Int, body: String) {
        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST \(path) HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenAIAccountGatewayConfiguration.apiKey)",
                        "chatgpt-account-id: local-placeholder",
                        "session_id: \(stickyKey)",
                        "Content-Length: \(Data(body.utf8).count)",
                        "Connection: close",
                    ],
                    body: body
                )
            )
        )

        let response = try await service.postResponsesProbeForTesting(request: request)
        return (response.statusCode, String(data: response.body, encoding: .utf8) ?? "")
    }

    private func rawRequest(lines: [String], body: String = "") -> Data {
        var text = lines.joined(separator: "\r\n")
        text += "\r\n\r\n"
        text += body
        return Data(text.utf8)
    }

    private func makeService(
        routeJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
    ) -> OpenAIAccountGatewayService {
        OpenAIAccountGatewayService(
            urlSession: self.makeMockSession(),
            runtimeConfiguration: .init(
                host: "127.0.0.1",
                port: 1456,
                upstreamResponsesURL: URL(string: "https://example.invalid/v1/responses")!,
                upstreamResponsesCompactURL: URL(string: "https://example.invalid/v1/responses/compact")!
            ),
            routeJournalStore: routeJournalStore
        )
    }

    private func assertNormalizedBody(
        _ body: [String: Any],
        expectedText: String,
        expectedServiceTier: String
    ) {
        XCTAssertEqual(body["model"] as? String, "gpt-5.4")
        XCTAssertEqual(body["service_tier"] as? String, expectedServiceTier)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "")
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])

        let tools = body["tools"] as? [Any]
        XCTAssertEqual(tools?.count, 0)

        let includes = body["include"] as? [String]
        XCTAssertEqual(includes, ["reasoning.encrypted_content"])

        let text = (((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, expectedText)
    }

    private func assertCompactBody(
        _ body: [String: Any],
        expectedText: String,
        expectedServiceTier: String
    ) {
        XCTAssertEqual(body["model"] as? String, "gpt-5.4")
        XCTAssertEqual(body["service_tier"] as? String, expectedServiceTier)
        XCTAssertEqual(body["instructions"] as? String, "")
        XCTAssertNil(body["store"])
        XCTAssertNil(body["stream"])
        XCTAssertNil(body["include"])
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["parallel_tool_calls"])
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])

        let text = (((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, expectedText)
    }
}
