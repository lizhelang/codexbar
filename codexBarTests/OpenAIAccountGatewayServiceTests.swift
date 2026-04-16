import Foundation
import XCTest

final class OpenAIAccountGatewayServiceTests: CodexBarTestCase {
    func testDefaultServiceUsesDedicatedUpstreamSessionConfiguration() {
        let service = OpenAIAccountGatewayService()

        XCTAssertTrue(service.usesDedicatedUpstreamSessionForTesting())

        let configuration = service.upstreamTransportConfigurationForTesting()
        XCTAssertEqual(configuration.requestTimeout, 30)
        XCTAssertEqual(configuration.resourceTimeout, 120)
        XCTAssertEqual(configuration.webSocketReadyBudget, 8)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

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

    func testStickyBindingsSnapshotAndClearOnlyAffectInMemoryBinding() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
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
            stickyKey: "thread-sticky-clear",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(service.stickyBindingsSnapshot().map(\.threadID), ["thread-sticky-clear"])
        XCTAssertTrue(service.clearStickyBinding(threadID: "thread-sticky-clear"))
        XCTAssertTrue(service.stickyBindingsSnapshot().isEmpty)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.threadID), ["thread-sticky-clear"])
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

    func testWebSocketReadyBudgetIsInjectableAndObservable() async throws {
        let service = self.makeService(
            upstreamTransportConfiguration: .init(
                requestTimeout: 11,
                resourceTimeout: 13,
                webSocketReadyBudget: 7,
                waitsForConnectivity: false
            )
        )
        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
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

        var observedBudgets: [TimeInterval] = []
        let selection = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
            account,
            requestedProtocol,
            readyBudget in
            observedBudgets.append(readyBudget)
            XCTAssertEqual(account.accountId, "acct-alpha")
            XCTAssertNil(requestedProtocol)
            return nil
        }

        XCTAssertEqual(selection.accountID, "acct-alpha")
        XCTAssertEqual(observedBudgets, [7])
    }

    func testResponsesWebSocketTransportFailureDoesNotFailoverAcrossAccounts() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-transport-failure"))
        )

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account,
                _,
                _ in
                attemptedAccountIDs.append(account.accountId)
                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
            }
            XCTFail("expected websocket transport failure")
        } catch let failure as OpenAIAccountGatewayUpstreamFailure {
            XCTAssertEqual(failure.failoverDisposition, .doNotFailover)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha"])
        XCTAssertNil(service.currentRoutedAccountIDForTesting())
    }

    func testResponsesWebSocketProtocolFailureDoesNotRebindStickySession() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-protocol-failure"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().count, 1)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account,
                _,
                _ in
                attemptedAccountIDs.append(account.accountId)
                throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.cannotParseResponse))
            }
            XCTFail("expected websocket protocol failure")
        } catch let failure as OpenAIAccountGatewayUpstreamFailure {
            XCTAssertEqual(failure.failoverDisposition, .doNotFailover)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().count, 1)
    }

    func testResponsesWebSocketAccountStatusesStillFailOver() async throws {
        for statusCode in [401, 403, 429] {
            let service = self.makeService()
            let primary = self.makeGatewayAccount(
                email: "alpha@example.com",
                accountId: "acct-alpha",
                openAIAccountId: "openai-alpha",
                accessToken: "token-alpha",
                refreshToken: "refresh-alpha",
                idToken: "id-alpha",
                planType: "plus"
            )
            let secondary = self.makeGatewayAccount(
                email: "beta@example.com",
                accountId: "acct-beta",
                openAIAccountId: "openai-beta",
                accessToken: "token-beta",
                refreshToken: "refresh-beta",
                idToken: "id-beta",
                planType: "free"
            )
            service.updateState(
                accounts: [primary, secondary],
                quotaSortSettings: .init(),
                accountUsageMode: .aggregateGateway
            )

            let request = try XCTUnwrap(
                service.parseRequestForTesting(
                    from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-account-\(statusCode)")
                )
            )

            var attemptedAccountIDs: [String] = []
            let selection = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account,
                _,
                _ in
                attemptedAccountIDs.append(account.accountId)
                if account.accountId == "acct-alpha" {
                    throw OpenAIAccountGatewayUpstreamFailure.accountStatus(statusCode)
                }
                return nil
            }

            XCTAssertEqual(selection.accountID, "acct-beta", "status \(statusCode) should fail over")
            XCTAssertEqual(
                attemptedAccountIDs,
                ["acct-alpha", "acct-beta"],
                "status \(statusCode) should try the next account"
            )
        }
    }

    func testResponsesWebSocketRetainsExisting5xxFailoverSemantics() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-5xx"))
        )

        var attemptedAccountIDs: [String] = []
        let selection = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
            account,
            _,
            _ in
            attemptedAccountIDs.append(account.accountId)
            if account.accountId == "acct-alpha" {
                throw OpenAIAccountGatewayUpstreamFailure.upstreamStatus(502)
            }
            return nil
        }

        XCTAssertEqual(selection.accountID, "acct-beta")
        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
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

    func testResponsesPOSTUsesProWeightInsteadOfFreeFallback() async throws {
        let service = self.makeService()

        let free = self.makeGatewayAccount(
            email: "free@example.com",
            accountId: "acct-free",
            openAIAccountId: "openai-free",
            accessToken: "token-free",
            refreshToken: "refresh-free",
            idToken: "id-free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let pro = self.makeGatewayAccount(
            email: "pro@example.com",
            accountId: "acct-pro",
            openAIAccountId: "openai-pro",
            accessToken: "token-pro",
            refreshToken: "refresh-pro",
            idToken: "id-pro",
            planType: "pro",
            primaryUsedPercent: 92,
            secondaryUsedPercent: 92
        )

        service.updateState(
            accounts: [free, pro],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.proObserved")
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
            stickyKey: "session-pro-default",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-pro"]
        )
        XCTAssertEqual(
            observedQueue.sync { forwardedAccountIDs },
            ["openai-pro"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-pro")
    }

    func testResponsesPOSTClampsCustomProRatioToMinimumWhenRankingCandidates() async throws {
        let service = self.makeService()

        let free = self.makeGatewayAccount(
            email: "free@example.com",
            accountId: "acct-free",
            openAIAccountId: "openai-free",
            accessToken: "token-free",
            refreshToken: "refresh-free",
            idToken: "id-free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let pro = self.makeGatewayAccount(
            email: "pro@example.com",
            accountId: "acct-pro",
            openAIAccountId: "openai-pro",
            accessToken: "token-pro",
            refreshToken: "refresh-pro",
            idToken: "id-pro",
            planType: "pro",
            primaryUsedPercent: 79,
            secondaryUsedPercent: 79
        )

        service.updateState(
            accounts: [free, pro],
            quotaSortSettings: .init(
                plusRelativeWeight: 1,
                proRelativeToPlusMultiplier: 1.0,
                teamRelativeToPlusMultiplier: 2
            ),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.proCustomObserved")
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
            stickyKey: "session-pro-custom",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-pro"]
        )
        XCTAssertEqual(
            observedQueue.sync { forwardedAccountIDs },
            ["openai-pro"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-pro")
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

    func testResponsesPOSTTransportFailureDoesNotFailoverAcrossAccounts() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.transportObserved")
        var forwardedAuthorizations: [String] = []

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
            }

            switch authorization {
            case "Bearer token-alpha":
                throw URLError(.timedOut)
            case "Bearer token-beta":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                return (response, Data("data: unexpected beta\n\n".utf8))
            default:
                throw URLError(.badServerResponse)
            }
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-transport-failure",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-alpha"]
        )
        XCTAssertNil(service.currentRoutedAccountIDForTesting())
    }

    func testResponsesPOSTTransportFailurePreservesExistingStickyBinding() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
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

        let seeded = try await self.postToGateway(
            service: service,
            stickyKey: "post-transport-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"seed"}]}]}
            """
        )
        XCTAssertEqual(seeded.statusCode, 200)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().count, 1)

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.transportStickyObserved")
        var secondAttemptAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                secondAttemptAuthorizations.append(authorization)
            }

            switch authorization {
            case "Bearer token-alpha":
                throw URLError(.networkConnectionLost)
            case "Bearer token-beta":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                return (response, Data("data: unexpected beta\n\n".utf8))
            default:
                throw URLError(.badServerResponse)
            }
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-transport-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"retry"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertEqual(
            observedQueue.sync { secondAttemptAuthorizations },
            ["Bearer token-alpha"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().count, 1)
    }

    func testResponsesPOSTAccountStatusesStillFailOver() async throws {
        for statusCode in [401, 403, 429] {
            let service = self.makeService()
            let primary = self.makeGatewayAccount(
                email: "alpha@example.com",
                accountId: "acct-alpha",
                openAIAccountId: "openai-alpha",
                accessToken: "token-alpha",
                refreshToken: "refresh-alpha",
                idToken: "id-alpha",
                planType: "plus"
            )
            let secondary = self.makeGatewayAccount(
                email: "beta@example.com",
                accountId: "acct-beta",
                openAIAccountId: "openai-beta",
                accessToken: "token-beta",
                refreshToken: "refresh-beta",
                idToken: "id-beta",
                planType: "free"
            )
            service.updateState(
                accounts: [primary, secondary],
                quotaSortSettings: .init(),
                accountUsageMode: .aggregateGateway
            )

            let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.accountStatus\(statusCode)")
            var forwardedAuthorizations: [String] = []
            MockURLProtocol.handler = { request in
                let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
                observedQueue.sync {
                    forwardedAuthorizations.append(authorization)
                }

                let status: Int
                let payload: String
                switch authorization {
                case "Bearer token-alpha":
                    status = statusCode
                    payload = "retry alpha"
                case "Bearer token-beta":
                    status = 200
                    payload = "data: ok\n\n"
                default:
                    status = 500
                    payload = "unexpected"
                }

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                return (response, Data(payload.utf8))
            }

            let response = try await self.postToGateway(
                service: service,
                stickyKey: "post-account-\(statusCode)",
                body: """
                {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
                """
            )

            XCTAssertEqual(response.statusCode, 200, "status \(statusCode) should fail over")
            XCTAssertEqual(
                observedQueue.sync { forwardedAuthorizations },
                ["Bearer token-alpha", "Bearer token-beta"],
                "status \(statusCode) should try the next account"
            )
            XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        }
    }

    func testResponsesPOSTRetainsExisting5xxFailoverSemantics() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.5xxObserved")
        var forwardedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
            }

            let statusCode: Int
            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                statusCode = 502
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

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-5xx",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
    }

    func testResponsesPOSTInBandUsageLimitErrorFailsOverAndBlocksExhaustedAccount() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 5 * 60 * 60)
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.inBandUsageLimitObserved")
        var forwardedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
            }

            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                payload = """
                data: {\"type\":\"response.created\"}

                data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"usage_limit_exceeded\",\"message\":\"You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at Apr 22nd, 2026 3:50 PM.\"}}}

                """
            case "Bearer token-beta":
                payload = "data: ok\\n\\n"
            default:
                payload = "data: unexpected\\n\\n"
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(payload.utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            stickyKey: "post-inband-usage-limit-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            stickyKey: "post-inband-usage-limit-2",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"again"}]}]}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertTrue(firstResponse.body.contains("data: ok"))
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertTrue(secondResponse.body.contains("data: ok"))
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
    }

    func testWebSocketInBandUsageLimitSignalBlocksAccountForFutureCandidates() throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "free",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 5 * 60 * 60)
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "plus"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let noted = service.noteInBandAccountSignalForTesting(
            #"{"type":"error","code":"usage_limit_exceeded","message":"You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at Apr 22nd, 2026 3:50 PM."}"#,
            accountID: "acct-alpha",
            stickyKey: "ws-usage-limit"
        )
        XCTAssertTrue(noted)

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-usage-limit-next")
            )
        )
        let response = service.webSocketUpgradeProbeForTesting(request: request)

        XCTAssertEqual(response.statusCode, 101)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
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
        upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration = .live,
        routeJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
    ) -> OpenAIAccountGatewayService {
        OpenAIAccountGatewayService(
            urlSession: self.makeMockSession(),
            upstreamTransportConfiguration: upstreamTransportConfiguration,
            runtimeConfiguration: .init(
                host: "127.0.0.1",
                port: 1456,
                upstreamResponsesURL: URL(string: "https://example.invalid/v1/responses")!,
                upstreamResponsesCompactURL: URL(string: "https://example.invalid/v1/responses/compact")!
            ),
            routeJournalStore: routeJournalStore
        )
    }

    private func makeWebSocketUpgradeRequest(stickyKey: String) -> Data {
        self.rawRequest(
            lines: [
                "GET /v1/responses HTTP/1.1",
                "Host: 127.0.0.1:1456",
                "Connection: Upgrade",
                "Upgrade: websocket",
                "Sec-WebSocket-Version: 13",
                "Sec-WebSocket-Key: dGVzdC1jb2RleGJhcg==",
                "session_id: \(stickyKey)",
            ]
        )
    }

    private func makeGatewayAccount(
        email: String,
        accountId: String,
        openAIAccountId: String,
        accessToken: String,
        refreshToken: String,
        idToken: String,
        planType: String,
        primaryUsedPercent: Double = 10,
        secondaryUsedPercent: Double = 10,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil
    ) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            openAIAccountId: openAIAccountId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt
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
