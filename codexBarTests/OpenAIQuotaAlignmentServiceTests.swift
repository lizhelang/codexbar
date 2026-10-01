import Foundation
import XCTest

final class OpenAIQuotaAlignmentServiceTests: CodexBarTestCase {
    private let testNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let completion = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"

    func testModelUsesConfiguredDefaultWithoutStaticFallbacks() {
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.model(defaultModel: " gpt-future-model \n"), "gpt-future-model")
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.model(defaultModel: "gpt-6-astra"), "gpt-6-astra")
        XCTAssertNil(OpenAIQuotaAlignmentPolicy.model(defaultModel: " \n"))
    }

    func testEntryRequiresExplicitOptInAndAccounts() {
        XCTAssertFalse(OpenAIQuotaAlignmentPolicy.shouldShowEntry(isEnabled: false, hasAccounts: true))
        XCTAssertFalse(OpenAIQuotaAlignmentPolicy.shouldShowEntry(isEnabled: true, hasAccounts: false))
        XCTAssertTrue(OpenAIQuotaAlignmentPolicy.shouldShowEntry(isEnabled: true, hasAccounts: true))
    }

    func testRequestIsShortAndIndependentOfCurrentChat() throws {
        let body = OpenAIQuotaAlignmentPolicy.requestBody(model: "gpt-6-astra")
        XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "Reply only with OK.")
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual((body["tools"] as? [Any])?.count, 0)
        for key in ["session_id", "conversation_id", "prompt_cache_key", "previous_response_id"] {
            XCTAssertNil(body[key])
        }
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "ok")
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, OpenAIQuotaAlignmentPolicy.reasoningEffort(for: "gpt-6-astra"))
    }

    func testDisabledServiceDoesNotRefreshOrSendRequests() async throws {
        let account = try self.readyAccount("disabled")
        MockURLProtocol.handler = { _ in
            XCTFail("disabled service must not send a request")
            throw URLError(.badServerResponse)
        }
        let report = await self.makeService().align(accounts: [account], defaultModel: "gpt-6-astra") { _ in
            XCTFail("disabled service must not refresh accounts")
            return nil
        }
        XCTAssertTrue(report.wasDisabled)
        XCTAssertNil(OpenAIQuotaAlignmentFeedback.from(report))
    }

    func testDirectRequestUsesDefaultModelAndRefreshedCredentials() async throws {
        let original = try self.readyAccount("direct")
        var before = original
        before.accessToken = "refreshed-test-access"
        let script = UsageRefreshScript(states: [original.accountId: [before, self.startedAccount(before)]])
        var capturedRequest: URLRequest?
        self.stubResponse { request in capturedRequest = request }
        let report = await self.makeService().align(
            accounts: [original], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
        )
        XCTAssertEqual(report.completedAccountIDs, [original.accountId])
        XCTAssertFalse(report.hasVerifiedAlignment, "one account is not proof of cross-account alignment")
        XCTAssertEqual(script.calls[original.accountId], 2)
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, OpenAIAccountGatewayConfiguration.upstreamResponsesURL.absoluteString)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-test-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), original.remoteAccountId)
        XCTAssertNil(request.value(forHTTPHeaderField: "session_id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "conversation_id"))
        let body = try self.jsonObject(from: request)
        XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(report), .completed(count: 1, skipped: 0))
    }

    func testEligibilityUsesFreshWindowsAndCanStartAfterExpiredExhaustedWindow() throws {
        var account = try self.readyAccount("eligibility")
        account.primaryUsedPercent = 100
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.eligibility(account, now: self.testNow), .ready)
        account.primaryResetAt = self.testNow.addingTimeInterval(200)
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.eligibility(account, now: self.testNow), .active(resetAt: account.primaryResetAt!))
        account.primaryResetAt = nil
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.eligibility(account, now: self.testNow), .unknown)
        account.primaryUsedPercent = 0
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.eligibility(account, now: self.testNow), .ready)
        account.secondaryUsedPercent = 100
        account.secondaryResetAt = self.testNow.addingTimeInterval(500)
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.eligibility(account, now: self.testNow), .unavailable)
        account.secondaryResetAt = self.testNow.addingTimeInterval(-1)
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.eligibility(account, now: self.testNow), .ready)
        account.primaryLimitWindowSeconds = nil
        XCTAssertEqual(OpenAIQuotaAlignmentPolicy.eligibility(account, now: self.testNow), .unavailable)
    }

    func testRunningWindowIsSkippedEvenWhenCachedWindowWasExpired() async throws {
        let stale = try self.readyAccount("active")
        let active = self.startedAccount(stale)
        let script = UsageRefreshScript(states: [stale.accountId: [active]])
        MockURLProtocol.handler = { _ in
            XCTFail("an already running window must not receive a ping")
            throw URLError(.badServerResponse)
        }
        let report = await self.makeService().align(
            accounts: [stale], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
        )
        XCTAssertEqual(report.activeWindowAccountIDs, [stale.accountId])
        XCTAssertEqual(report.skippedAccountIDs, [stale.accountId])
        XCTAssertEqual(script.calls[stale.accountId], 1)
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(report), .noEligible)
    }

    func testPreflightFailureDoesNotSendRequest() async throws {
        let account = try self.readyAccount("preflight")
        MockURLProtocol.handler = { _ in
            XCTFail("unknown usage must not receive a ping")
            throw URLError(.badServerResponse)
        }
        let report = await self.makeService().align(
            accounts: [account], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: { _ in nil }
        )
        XCTAssertEqual(report.failedAccountIDs, [account.accountId])
        XCTAssertFalse(report.hasVerifiedAlignment)
    }

    func testUnknownUnsupportedAndExpiredAccountsAreSkipped() async throws {
        var unknown = try self.readyAccount("unknown")
        unknown.primaryResetAt = nil
        unknown.primaryUsedPercent = 30
        var unsupported = try self.readyAccount("unsupported")
        unsupported.primaryLimitWindowSeconds = 604_800
        var expired = try self.readyAccount("expired")
        expired.tokenExpired = true
        let script = UsageRefreshScript(states: [unknown.accountId: [unknown], unsupported.accountId: [unsupported]])
        MockURLProtocol.handler = { _ in
            XCTFail("ineligible accounts must not receive requests")
            throw URLError(.badServerResponse)
        }
        let report = await self.makeService().align(
            accounts: [unknown, unsupported, expired], defaultModel: "gpt-6-astra", isEnabled: true,
            refreshAccount: script.refresh
        )
        XCTAssertEqual(Set(report.skippedAccountIDs), Set([unknown.accountId, unsupported.accountId, expired.accountId]))
        XCTAssertEqual(report.unverifiedAccountIDs, [unknown.accountId])
        XCTAssertNil(script.calls[expired.accountId])
    }

    func testHTTPFailuresNeverTryAnotherModel() async throws {
        let account = try self.readyAccount("http")
        for status in [400, 401, 403, 404, 429] {
            let script = UsageRefreshScript(states: [account.accountId: [account, account]])
            var requestCount = 0
            self.stubResponse(status: status, body: #"{"error":{"code":"invalid_request"}}"#) { _ in requestCount += 1 }
            let report = await self.makeService().align(
                accounts: [account], defaultModel: "gpt-future-model", isEnabled: true, refreshAccount: script.refresh
            )
            XCTAssertEqual(requestCount, 1)
            XCTAssertEqual(report.failedAccountIDs, [account.accountId])
            XCTAssertEqual(report.lastFailureStatusCode, status)
            XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(report), .failed(statusCode: status))
        }
    }

    func testUnavailableDefaultModelIsReportedWithoutFallback() async throws {
        let account = try self.readyAccount("model")
        let script = UsageRefreshScript(states: [account.accountId: [account, account]])
        self.stubResponse(status: 404, body: #"{"error":{"code":"model_not_found"}}"#)
        let report = await self.makeService().align(
            accounts: [account], defaultModel: "gpt-missing", isEnabled: true, refreshAccount: script.refresh
        )
        XCTAssertEqual(report.modelUnavailableAccountIDs, [account.accountId])
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(report), .modelUnavailable)
    }

    func testHTTP200WithFailureIncompleteOrMissingTerminalIsNotCompleted() async throws {
        let account = try self.readyAccount("terminal")
        let bodies = [
            "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"server_error\"}}}\n\n",
            "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n",
            "data: {\"type\":\"error\",\"error\":{\"code\":\"server_error\"}}\n\n",
            "data: {\"type\":\"response.created\"}\n\ndata: [DONE]\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"failed\"}}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}",
            "{\"id\":\"resp_no_terminal\"}",
            "",
        ]
        for body in bodies {
            let script = UsageRefreshScript(states: [account.accountId: [account, self.startedAccount(account)]])
            self.stubResponse(body: body)
            let report = await self.makeService().align(
                accounts: [account], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
            )
            XCTAssertEqual(report.completedCount, 0, body)
            XCTAssertEqual(report.failedCount, 1, body)
            XCTAssertNil(report.lastFailureStatusCode, "HTTP 200 must not be displayed as the error reason")
            XCTAssertFalse(report.hasVerifiedAlignment)
        }
    }

    func testStreamingModelErrorIsReportedAsUnavailable() async throws {
        let account = try self.readyAccount("stream-model")
        let script = UsageRefreshScript(states: [account.accountId: [account, account]])
        self.stubResponse(body: "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"model_not_found\"}}}\n\n")
        let report = await self.makeService().align(
            accounts: [account], defaultModel: "gpt-missing", isEnabled: true, refreshAccount: script.refresh
        )
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(report), .modelUnavailable)
    }

    func testSSEParserSupportsCommentsEventNamesAndMultilineData() {
        var parser = OpenAIQuotaAlignmentStreamParser()
        for line in [": heartbeat", "event: response.completed", "data: {", "data: \"response\":{\"status\":\"completed\"}", "data: }"] {
            XCTAssertNil(parser.append(line: line))
        }
        XCTAssertEqual(parser.append(line: ""), .completed)
    }

    func testByteParserPreservesSSEBoundariesAndSplitUTF8() {
        for newline in ["\n", "\r\n", "\r"] {
            var parser = OpenAIQuotaAlignmentStreamParser()
            let event = ": 中文注释\(newline)data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\(newline)\(newline)"
            var result: OpenAIQuotaAlignmentRequestOutcome?
            for byte in event.utf8 {
                if let terminal = parser.append(byte: byte) { result = terminal }
            }
            XCTAssertEqual(result, .completed)
        }
    }

    func testCompletionWithCRLFIsRecognized() async throws {
        let account = try self.readyAccount("crlf")
        let script = UsageRefreshScript(states: [account.accountId: [account, self.startedAccount(account)]])
        self.stubResponse(body: self.completion.replacingOccurrences(of: "\n", with: "\r\n"))
        let report = await self.makeService().align(
            accounts: [account], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
        )
        XCTAssertEqual(report.completedCount, 1)
    }

    func testTransportFailureIsNotCompletedEvenIfWindowStarts() async throws {
        let account = try self.readyAccount("network")
        let script = UsageRefreshScript(states: [account.accountId: [account, self.startedAccount(account)]])
        MockURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        let report = await self.makeService().align(
            accounts: [account], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
        )
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.completedCount, 0)
        XCTAssertFalse(report.hasVerifiedAlignment)
        XCTAssertEqual(script.calls[account.accountId], 2)
    }

    func testCompletedRequestsRequireFreshResetTimesForAlignment() async throws {
        let first = try self.readyAccount("first")
        let second = try self.readyAccount("second")
        for offset in [60.0, 61.0] {
            let script = UsageRefreshScript(states: [
                first.accountId: [first, self.startedAccount(first)],
                second.accountId: [second, self.startedAccount(second, offset: offset)],
            ])
            self.stubResponse()
            let report = await self.makeService().align(
                accounts: [first, second], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
            )
            XCTAssertEqual(report.completedCount, 2)
            XCTAssertEqual(report.hasVerifiedAlignment, offset <= 60)
            XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(report)?.isSuccess, offset <= 60)
        }
    }

    func testFailedPostRefreshOrUnchangedExpiredTimeDoesNotClaimAlignment() async throws {
        let first = try self.readyAccount("post-first")
        let second = try self.readyAccount("post-second")
        for after in [nil, second] {
            let script = UsageRefreshScript(states: [
                first.accountId: [first, self.startedAccount(first)],
                second.accountId: [second, after],
            ])
            self.stubResponse()
            let report = await self.makeService().align(
                accounts: [first, second], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
            )
            XCTAssertEqual(report.completedCount, 2)
            XCTAssertEqual(report.unverifiedAccountIDs, [second.accountId])
            XCTAssertFalse(report.hasVerifiedAlignment)
            XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(report), .completed(count: 2, skipped: 0))
        }
    }

    func testAlreadyRunningAccountsAlsoParticipateInAlignmentVerification() async throws {
        let first = try self.readyAccount("new")
        let existing = self.startedAccount(try self.readyAccount("existing"), offset: 200)
        let script = UsageRefreshScript(states: [
            first.accountId: [first, self.startedAccount(first)],
            existing.accountId: [existing],
        ])
        self.stubResponse()
        let report = await self.makeService().align(
            accounts: [first, existing], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
        )
        XCTAssertEqual(report.completedCount, 1)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertFalse(report.hasVerifiedAlignment, "skipping an existing misaligned window is not proof of full alignment")
    }

    func testPartialFailureDoesNotClaimAlignment() async throws {
        let first = try self.readyAccount("partial-first")
        let second = try self.readyAccount("partial-second")
        let script = UsageRefreshScript(states: [
            first.accountId: [first, self.startedAccount(first)],
            second.accountId: [second, self.startedAccount(second)],
        ])
        let completion = self.completion
        MockURLProtocol.handler = { request in
            let ok = request.value(forHTTPHeaderField: "chatgpt-account-id") == first.remoteAccountId
            return (
                HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 500, httpVersion: nil,
                                headerFields: ["Content-Type": "text/event-stream"])!,
                Data((ok ? completion : "{}").utf8)
            )
        }
        let report = await self.makeService().align(
            accounts: [first, second], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
        )
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(report), .partial(completed: 1, failed: 1, skipped: 0))
        XCTAssertFalse(report.hasVerifiedAlignment)
    }

    func testSecondAlignWhileRunningIsIgnored() async throws {
        let account = try self.readyAccount("busy")
        let script = UsageRefreshScript(states: [account.accountId: [account, self.startedAccount(account)]])
        let started = expectation(description: "request started")
        let gate = DispatchSemaphore(value: 0)
        let completion = self.completion
        MockURLProtocol.handler = { request in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(completion.utf8))
        }
        let service = self.makeService()
        async let first = service.align(
            accounts: [account], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
        )
        await fulfillment(of: [started], timeout: 2)
        let second = await service.align(
            accounts: [account], defaultModel: "gpt-6-astra", isEnabled: true, refreshAccount: script.refresh
        )
        gate.signal()
        let firstReport = await first
        XCTAssertTrue(second.wasAlreadyRunning)
        XCTAssertNil(OpenAIQuotaAlignmentFeedback.from(second))
        XCTAssertEqual(firstReport.completedCount, 1)
    }

    private func readyAccount(_ id: String) throws -> TokenAccount {
        var account = try self.makeOAuthAccount(accountID: "acct-\(id)", email: "\(id)@example.com")
        account.primaryLimitWindowSeconds = 18_000
        account.primaryResetAt = self.testNow.addingTimeInterval(-10)
        account.primaryUsedPercent = 100
        account.lastChecked = self.testNow
        return account
    }

    private func startedAccount(_ account: TokenAccount, offset: TimeInterval = 0) -> TokenAccount {
        var account = account
        account.primaryUsedPercent = 1
        account.primaryResetAt = self.testNow.addingTimeInterval(18_000 + offset)
        return account
    }

    private func makeService() -> OpenAIQuotaAlignmentService {
        OpenAIQuotaAlignmentService(urlSession: self.makeMockSession(), now: { self.testNow })
    }

    private func stubResponse(
        status: Int = 200,
        body: String? = nil,
        observe: @escaping (URLRequest) -> Void = { _ in }
    ) {
        let data = Data((body ?? self.completion).utf8)
        MockURLProtocol.handler = { request in
            observe(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                headerFields: ["Content-Type": "text/event-stream"])!,
                data
            )
        }
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 1_024)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class UsageRefreshScript {
    var states: [String: [TokenAccount?]]
    private(set) var calls: [String: Int] = [:]

    init(states: [String: [TokenAccount?]]) {
        self.states = states
    }

    @MainActor
    func refresh(_ account: TokenAccount) async -> TokenAccount? {
        self.calls[account.accountId, default: 0] += 1
        guard var sequence = self.states[account.accountId], sequence.isEmpty == false else { return nil }
        let next = sequence.removeFirst()
        self.states[account.accountId] = sequence
        return next
    }
}
