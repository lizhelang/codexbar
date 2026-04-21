import Foundation
import Network
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

    func testLoopbackProxySafePolicyOnlyAppliesToLoopbackProxySnapshots() {
        let loopbackConfiguration = self.makeTransportConfiguration(
            proxyResolutionMode: .loopbackProxySafe,
            snapshot: self.makeProxySnapshot(
                httpHost: "127.0.0.1",
                httpPort: 1082,
                httpsHost: "localhost",
                httpsPort: 1082
            )
        )
        let loopbackService = self.makeService(upstreamTransportConfiguration: loopbackConfiguration)
        let loopbackPolicy = loopbackService.upstreamTransportPolicyForTesting()

        XCTAssertTrue(loopbackPolicy.loopbackProxySafeApplied)
        XCTAssertEqual(loopbackPolicy.systemProxySnapshot?.http?.host, "127.0.0.1")
        XCTAssertNil(loopbackPolicy.effectiveProxySnapshot?.http)
        XCTAssertNil(loopbackPolicy.effectiveProxySnapshot?.https)

        let corpConfiguration = self.makeTransportConfiguration(
            proxyResolutionMode: .loopbackProxySafe,
            snapshot: self.makeProxySnapshot(
                httpHost: "corp-proxy.example.com",
                httpPort: 8080,
                httpsHost: "corp-proxy.example.com",
                httpsPort: 8080
            )
        )
        let corpService = self.makeService(upstreamTransportConfiguration: corpConfiguration)
        let corpPolicy = corpService.upstreamTransportPolicyForTesting()

        XCTAssertFalse(corpPolicy.loopbackProxySafeApplied)
        XCTAssertEqual(corpPolicy.effectiveProxySnapshot?.http?.host, "corp-proxy.example.com")
        XCTAssertEqual(corpPolicy.effectiveProxySnapshot?.https?.host, "corp-proxy.example.com")
    }

    func testPOSTFailureDiagnosticsExposeFailureClassOutput() throws {
        let service = self.makeService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: self.makeProxySnapshot(
                    httpsHost: "127.0.0.1",
                    httpsPort: 1082
                )
            )
        )

        let transportDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                failure: .transport(URLError(.timedOut))
            )
        )
        XCTAssertEqual(transportDiagnostic.route, "compact")
        XCTAssertEqual(transportDiagnostic.failureClass, .transport)
        XCTAssertEqual(transportDiagnostic.errorDomain, NSURLErrorDomain)
        XCTAssertEqual(transportDiagnostic.errorCode, URLError.timedOut.rawValue)
        XCTAssertTrue(transportDiagnostic.loopbackProxySafeApplied)

        let upstreamStatusDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                failure: .upstreamStatus(502)
            )
        )
        XCTAssertEqual(upstreamStatusDiagnostic.failureClass, .upstreamStatus)
        XCTAssertEqual(upstreamStatusDiagnostic.statusCode, 502)

        let protocolFailure = service.classifyPOSTFailureForTesting(URLError(.badServerResponse))
        XCTAssertEqual(protocolFailure.failureClass, .protocolViolation)
        let protocolDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                failure: protocolFailure
            )
        )
        XCTAssertEqual(protocolDiagnostic.failureClass, .protocolViolation)
        XCTAssertEqual(protocolDiagnostic.errorCode, URLError.badServerResponse.rawValue)

        let accountStatusDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                failure: .accountStatus(429)
            )
        )
        XCTAssertEqual(accountStatusDiagnostic.failureClass, .accountStatus)
        XCTAssertEqual(accountStatusDiagnostic.statusCode, 429)
    }

    func testResponsesCompactPOSTLoopbackProxySafePolicyAvoidsSynthetic502OnEquivalentRuntimePath() async throws {
        let upstreamServer = try LocalHTTPResponseServer(
            statusCode: 200,
            contentType: "application/json",
            responseBody: #"{"ok":true}"#
        )
        let rejectingProxy = try RejectingHTTPProxyServer()
        defer {
            upstreamServer.stop()
            rejectingProxy.stop()
        }

        let runtimeConfiguration = OpenAIAccountGatewayRuntimeConfiguration(
            host: "127.0.0.1",
            port: 1456,
            upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
            upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact")
        )
        let proxySnapshot = self.makeProxySnapshot(
            httpHost: "127.0.0.1",
            httpPort: Int(rejectingProxy.port)
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

        let legacyDiagnosticsQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.legacyDiagnostics")
        var legacyDiagnostics: [OpenAIAccountGatewayUpstreamFailureDiagnostic] = []
        let legacyService = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .systemDefault,
                snapshot: proxySnapshot
            ),
            runtimeConfiguration: runtimeConfiguration,
            routeJournalStore: OpenAIAggregateRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            ),
            diagnosticsReporter: { diagnostic in
                legacyDiagnosticsQueue.sync {
                    legacyDiagnostics.append(diagnostic)
                }
            }
        )
        legacyService.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let legacyResponse = try await self.postToGateway(
            service: legacyService,
            path: "/v1/responses/compact",
            stickyKey: "compact-loopback-legacy",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact hello"}]}],"service_tier":"priority","store":true,"max_output_tokens":128,"temperature":0.7,"top_p":0.9,"stream":false,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"parallel_tool_calls":true}
            """
        )

        XCTAssertEqual(legacyResponse.statusCode, 502)
        XCTAssertEqual(
            legacyResponse.body,
            #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
        )
        let proxyHitsAfterLegacy = rejectingProxy.connectionCount
        XCTAssertGreaterThanOrEqual(proxyHitsAfterLegacy, 1)
        XCTAssertTrue(upstreamServer.requests.isEmpty)
        XCTAssertEqual(legacyDiagnosticsQueue.sync { legacyDiagnostics.last?.route }, "compact")
        XCTAssertEqual(legacyDiagnosticsQueue.sync { legacyDiagnostics.last?.loopbackProxySafeApplied }, false)

        let fixedDiagnosticsQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.fixedDiagnostics")
        var fixedDiagnostics: [OpenAIAccountGatewayUpstreamFailureDiagnostic] = []
        let fixedService = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: proxySnapshot
            ),
            runtimeConfiguration: runtimeConfiguration,
            routeJournalStore: OpenAIAggregateRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            ),
            diagnosticsReporter: { diagnostic in
                fixedDiagnosticsQueue.sync {
                    fixedDiagnostics.append(diagnostic)
                }
            }
        )
        fixedService.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let fixedResponse = try await self.postToGateway(
            service: fixedService,
            path: "/v1/responses/compact",
            stickyKey: "compact-loopback-fixed",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact hello"}]}],"service_tier":"priority","store":true,"max_output_tokens":128,"temperature":0.7,"top_p":0.9,"stream":false,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"parallel_tool_calls":true}
            """
        )

        XCTAssertEqual(fixedResponse.statusCode, 200)
        XCTAssertEqual(fixedResponse.body, #"{"ok":true}"#)
        XCTAssertEqual(rejectingProxy.connectionCount, proxyHitsAfterLegacy)
        XCTAssertEqual(upstreamServer.requests.count, 1)
        XCTAssertEqual(upstreamServer.requests.first?.path, "/v1/responses/compact")
        let compactBody = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try XCTUnwrap(upstreamServer.requests.first?.body)
            ) as? [String: Any]
        )
        self.assertCompactBody(compactBody, expectedText: "compact hello", expectedServiceTier: "priority")
        XCTAssertTrue(fixedDiagnosticsQueue.sync { fixedDiagnostics.isEmpty })
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

    func testResponsesWebSocketProtocolFailureDoesNotFailoverWithoutStickyBinding() async throws {
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
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-protocol-no-sticky-binding"))
        )

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account, _, _ in
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
        XCTAssertNil(service.currentRoutedAccountIDForTesting())
    }

    func testResponsesWebSocketTransportFailureRecoversOnceInStickyContext() async throws {
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
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-transport-sticky-context"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")

        var attemptedAccountIDs: [String] = []
        let selection = try await service.establishResponsesWebSocketProbeForTesting(
            request: request,
            bindOnSuccess: true
        ) { account, _, _ in
            attemptedAccountIDs.append(account.accountId)
            if account.accountId == "acct-alpha" {
                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.networkConnectionLost))
            }
            return nil
        }

        XCTAssertEqual(selection.accountID, "acct-beta")
        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha", "acct-beta"])
    }

    func testResponsesWebSocketProtocolFailureRecoversOnceInStickyContext() async throws {
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
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-protocol-sticky-context"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().count, 1)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")

        var attemptedAccountIDs: [String] = []
        let selection = try await service.establishResponsesWebSocketProbeForTesting(
            request: request,
            bindOnSuccess: true
        ) { account, _, _ in
            attemptedAccountIDs.append(account.accountId)
            if account.accountId == "acct-alpha" {
                throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.cannotParseResponse))
            }
            return nil
        }

        XCTAssertEqual(selection.accountID, "acct-beta")
        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha", "acct-beta"])
    }

    func testResponsesWebSocketStickyContextRecoveryIsBoundedToOneAlternateCandidate() async throws {
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
            planType: "plus",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 80
        )
        let tertiary = self.makeGatewayAccount(
            email: "gamma@example.com",
            accountId: "acct-gamma",
            openAIAccountId: "openai-gamma",
            accessToken: "token-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma",
            planType: "free",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90
        )
        service.updateState(
            accounts: [primary, secondary, tertiary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-bounded-sticky-context"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account, _, _ in
                attemptedAccountIDs.append(account.accountId)
                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
            }
            XCTFail("expected bounded websocket transport failure")
        } catch let failure as OpenAIAccountGatewayUpstreamFailure {
            XCTAssertEqual(failure.failoverDisposition, .doNotFailover)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
    }

    func testResponsesWebSocketStickyContextRecoveryStopsAfterAlternateCandidateAccountStatusFailure() async throws {
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
            planType: "plus",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 80
        )
        let tertiary = self.makeGatewayAccount(
            email: "gamma@example.com",
            accountId: "acct-gamma",
            openAIAccountId: "openai-gamma",
            accessToken: "token-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma",
            planType: "free",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90
        )
        service.updateState(
            accounts: [primary, secondary, tertiary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-bounded-sticky-context-account-status"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account, _, _ in
                attemptedAccountIDs.append(account.accountId)
                if account.accountId == "acct-alpha" {
                    throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
                }
                throw OpenAIAccountGatewayUpstreamFailure.accountStatus(429)
            }
            XCTFail("expected bounded websocket sticky-context failure")
        } catch let failure as OpenAIAccountGatewayUpstreamFailure {
            if case .accountStatus(let statusCode) = failure {
                XCTAssertEqual(statusCode, 429)
            } else {
                XCTFail("expected account status failure, got \(failure)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
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

    func testResponsesPOST429WithoutRetryAfterDoesNotBlockSingleAccountForFutureCandidates() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "solo@example.com",
            accountId: "acct-solo",
            openAIAccountId: "openai-solo",
            accessToken: "token-solo",
            refreshToken: "refresh-solo",
            idToken: "id-solo",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.retryable429Observed")
        var forwardedAuthorizations: [String] = []
        var attempt = 0
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
                attempt += 1
            }

            let statusCode = observedQueue.sync { attempt == 1 ? 429 : 200 }
            let payload = statusCode == 429 ? "retry solo" : "data: ok\n\n"
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
            stickyKey: "single-429-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"first"}]}]}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            stickyKey: "single-429-2",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"second"}]}]}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 429)
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-solo", "Bearer token-solo"]
        )
    }

    func testResponsesPOST429WithRetryAfterStillBlocksSingleAccountForFutureCandidates() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "solo@example.com",
            accountId: "acct-solo",
            openAIAccountId: "openai-solo",
            accessToken: "token-solo",
            refreshToken: "refresh-solo",
            idToken: "id-solo",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.retryAfterObserved")
        var forwardedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/event-stream",
                    "Retry-After": "120",
                ]
            )!
            return (response, Data("retry later".utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            stickyKey: "single-retry-after-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"first"}]}]}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            stickyKey: "single-retry-after-2",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"second"}]}]}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 429)
        XCTAssertEqual(secondResponse.statusCode, 503)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-solo"]
        )
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
        runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration = .init(
            host: "127.0.0.1",
            port: 1456,
            upstreamResponsesURL: URL(string: "https://example.invalid/v1/responses")!,
            upstreamResponsesCompactURL: URL(string: "https://example.invalid/v1/responses/compact")!
        ),
        routeJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        ),
        diagnosticsReporter: @escaping (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void = { _ in }
    ) -> OpenAIAccountGatewayService {
        OpenAIAccountGatewayService(
            urlSession: self.makeMockSession(),
            upstreamTransportConfiguration: upstreamTransportConfiguration,
            runtimeConfiguration: runtimeConfiguration,
            routeJournalStore: routeJournalStore,
            diagnosticsReporter: diagnosticsReporter
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

    private func makeTransportConfiguration(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        webSocketReadyBudget: TimeInterval = 8,
        waitsForConnectivity: Bool = false,
        proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode = .loopbackProxySafe,
        snapshot: OpenAIAccountGatewaySystemProxySnapshot? = nil
    ) -> OpenAIAccountGatewayUpstreamTransportConfiguration {
        OpenAIAccountGatewayUpstreamTransportConfiguration(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            webSocketReadyBudget: webSocketReadyBudget,
            waitsForConnectivity: waitsForConnectivity,
            proxyResolutionMode: proxyResolutionMode,
            proxySnapshotProvider: { snapshot }
        )
    }

    private func makeProxySnapshot(
        httpHost: String? = nil,
        httpPort: Int? = nil,
        httpsHost: String? = nil,
        httpsPort: Int? = nil,
        socksHost: String? = nil,
        socksPort: Int? = nil
    ) -> OpenAIAccountGatewaySystemProxySnapshot? {
        let http = self.makeProxyEndpoint(kind: "http", host: httpHost, port: httpPort)
        let https = self.makeProxyEndpoint(kind: "https", host: httpsHost, port: httpsPort)
        let socks = self.makeProxyEndpoint(kind: "socks", host: socksHost, port: socksPort)
        if http == nil, https == nil, socks == nil {
            return nil
        }
        return OpenAIAccountGatewaySystemProxySnapshot(http: http, https: https, socks: socks)
    }

    private func makeProxyEndpoint(
        kind: String,
        host: String?,
        port: Int?
    ) -> OpenAIAccountGatewaySystemProxyEndpoint? {
        guard let host, host.isEmpty == false,
              let port, port > 0 else {
            return nil
        }
        return OpenAIAccountGatewaySystemProxyEndpoint(kind: kind, host: host, port: port)
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

private struct RecordedHTTPRequest: Equatable {
    let path: String
    let body: Data
}

private final class LocalHTTPResponseServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPResponseServer.queue")
    private let responseData: Data
    private let contentType: String

    private(set) var port: UInt16 = 0
    private var recordedRequests: [RecordedHTTPRequest] = []

    var requests: [RecordedHTTPRequest] {
        self.queue.sync { self.recordedRequests }
    }

    init(
        statusCode: Int,
        contentType: String,
        responseBody: String
    ) throws {
        self.responseData = Data(responseBody.utf8)
        self.contentType = contentType
        self.listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        self.listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection, statusCode: statusCode)
        }
        self.listener.start(queue: self.queue)
        ready.wait()
        if let startupError {
            throw startupError
        }
    }

    func stop() {
        self.listener.cancel()
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(self.port)\(path)")!
    }

    private func handle(connection: NWConnection, statusCode: Int) {
        connection.start(queue: self.queue)
        self.receive(on: connection, buffer: Data(), statusCode: statusCode)
    }

    private func receive(
        on connection: NWConnection,
        buffer: Data,
        statusCode: Int
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var combined = buffer
            if let data {
                combined.append(data)
            }

            if let request = self.parseRequest(from: combined) {
                self.recordedRequests.append(request)
                let header = [
                    "HTTP/1.1 \(statusCode) OK",
                    "Content-Type: \(self.contentType)",
                    "Content-Length: \(self.responseData.count)",
                    "Connection: close",
                    "",
                    "",
                ].joined(separator: "\r\n")
                connection.send(
                    content: Data(header.utf8) + self.responseData,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: combined, statusCode: statusCode)
        }
    }

    private func parseRequest(from data: Data) -> RecordedHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }

        let bodyOffset = headerRange.upperBound
        guard data.count >= bodyOffset + contentLength else {
            return nil
        }

        return RecordedHTTPRequest(
            path: String(requestParts[1]),
            body: data.subdata(in: bodyOffset..<(bodyOffset + contentLength))
        )
    }
}

private final class RejectingHTTPProxyServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RejectingHTTPProxyServer.queue")

    private(set) var port: UInt16 = 0
    private var acceptedConnections = 0

    var connectionCount: Int {
        self.queue.sync { self.acceptedConnections }
    }

    init() throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        self.listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.acceptedConnections += 1
                connection.start(queue: self?.queue ?? .main)
                connection.cancel()
            }
        }
        self.listener.start(queue: self.queue)
        ready.wait()
        if let startupError {
            throw startupError
        }
    }

    func stop() {
        self.listener.cancel()
    }
}
