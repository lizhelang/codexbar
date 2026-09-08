import Foundation
import XCTest

final class OpenAIQuotaAlignmentServiceTests: CodexBarTestCase {
    func testModelCandidatesPreferLunaThenCatalogThenDefault() {
        let candidates = OpenAIQuotaAlignmentPolicy.modelCandidates(defaultModel: "gpt-5.6-sol")
        XCTAssertEqual(candidates.first, "gpt-5.6-luna")
        XCTAssertTrue(candidates.contains("gpt-5.6-terra"))
        XCTAssertTrue(candidates.contains("gpt-5.6-sol"))
        XCTAssertEqual(candidates.filter { $0 == "gpt-5.6-sol" }.count, 1)

        let withCustom = OpenAIQuotaAlignmentPolicy.modelCandidates(defaultModel: "gpt-custom-ping")
        XCTAssertEqual(withCustom.first, "gpt-5.6-luna")
        XCTAssertEqual(withCustom.last, "gpt-custom-ping")
    }

    func testRequestBodyIsEphemeralAndHasNoSessionIdentity() throws {
        let body = OpenAIQuotaAlignmentPolicy.requestBody(model: "gpt-5.6-luna")
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "")
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual((body["tools"] as? [Any])?.isEmpty, true)
        XCTAssertEqual(
            body["include"] as? [String],
            [OpenAIAccountGatewayConfiguration.reasoningIncludeMarker]
        )
        XCTAssertNil(body["session_id"])
        XCTAssertNil(body["conversation_id"])
        XCTAssertNil(body["prompt_cache_key"])
        XCTAssertNil(body["previous_response_id"])

        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "low")

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "ok")
    }

    func testIsRetryableModelFailureDetectsModelErrorsOnly() {
        XCTAssertTrue(OpenAIQuotaAlignmentPolicy.isRetryableModelFailure(statusCode: 400))
        XCTAssertTrue(OpenAIQuotaAlignmentPolicy.isRetryableModelFailure(statusCode: 404))
        XCTAssertFalse(OpenAIQuotaAlignmentPolicy.isRetryableModelFailure(statusCode: 401))
        XCTAssertFalse(OpenAIQuotaAlignmentPolicy.isRetryableModelFailure(statusCode: 429))
    }

    func testAlignPingsEligibleAccountsDirectlyAndSkipsUnavailableOnes() async throws {
        let eligible = try self.makeOAuthAccount(
            accountID: "acct_align_ok",
            email: "ok@example.com",
            remoteAccountID: "remote-ok"
        )
        var banned = try self.makeOAuthAccount(
            accountID: "acct_align_banned",
            email: "banned@example.com"
        )
        banned.isSuspended = true
        var expired = try self.makeOAuthAccount(
            accountID: "acct_align_expired",
            email: "expired@example.com"
        )
        expired.tokenExpired = true
        var exhausted = try self.makeOAuthAccount(
            accountID: "acct_align_exhausted",
            email: "exhausted@example.com"
        )
        exhausted.primaryUsedPercent = 100

        let lock = NSLock()
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            lock.lock()
            requests.append(request)
            lock.unlock()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"id":"resp_ok"}"#.utf8)
            )
        }

        let service = OpenAIQuotaAlignmentService(urlSession: self.makeMockSession())
        let report = await service.align(
            accounts: [banned, eligible, expired, exhausted],
            defaultModel: "gpt-5.6-sol"
        )

        XCTAssertEqual(report.succeededAccountIDs, ["acct_align_ok"])
        XCTAssertEqual(
            Set(report.skippedAccountIDs),
            ["acct_align_banned", "acct_align_expired", "acct_align_exhausted"]
        )
        XCTAssertEqual(report.failedAccountIDs, [])
        XCTAssertEqual(requests.count, 1)

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://chatgpt.com/backend-api/codex/responses"
        )
        XCTAssertFalse(request.url?.host?.contains("127.0.0.1") ?? false)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(eligible.accessToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "remote-ok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codexbar")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNil(request.value(forHTTPHeaderField: "version"))
        XCTAssertNil(request.value(forHTTPHeaderField: "session_id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "conversation_id"))

        let body = try self.jsonObject(from: request)
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(self.jsonBool(body["store"]), false)
        XCTAssertEqual(self.jsonBool(body["stream"]), true)
        XCTAssertEqual(
            body["include"] as? [String],
            [OpenAIAccountGatewayConfiguration.reasoningIncludeMarker]
        )
        XCTAssertNil(body["session_id"])
        XCTAssertNil(body["conversation_id"])
        XCTAssertNil(body["prompt_cache_key"])
    }

    func testAlignRetriesNextModelWhenPreferredModelIsUnsupported() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "acct_align_retry",
            email: "retry@example.com"
        )

        let lock = NSLock()
        var models: [String] = []
        MockURLProtocol.handler = { request in
            let body = (try? JSONSerialization.jsonObject(with: self.bodyData(from: request) ?? Data())) as? [String: Any] ?? [:]
            let model = body["model"] as? String ?? ""
            lock.lock()
            models.append(model)
            lock.unlock()

            if model == "gpt-5.6-luna" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":{"message":"model_not_found"}}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"id":"resp_fallback"}"#.utf8)
            )
        }

        let service = OpenAIQuotaAlignmentService(urlSession: self.makeMockSession())
        let report = await service.align(accounts: [account], defaultModel: "gpt-5.6-sol")

        XCTAssertEqual(report.succeededAccountIDs, ["acct_align_retry"])
        XCTAssertEqual(report.failedAccountIDs, [])
        XCTAssertEqual(models.first, "gpt-5.6-luna")
        XCTAssertEqual(models.count, 2)
        XCTAssertNotEqual(models.last, "gpt-5.6-luna")
    }

    func testAlignDoesNotRetryModelOnUnauthorized() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "acct_align_unauth",
            email: "unauth@example.com"
        )

        let lock = NSLock()
        var requestCount = 0
        MockURLProtocol.handler = { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":{"message":"model not found"}}"#.utf8)
            )
        }

        let service = OpenAIQuotaAlignmentService(urlSession: self.makeMockSession())
        let report = await service.align(accounts: [account], defaultModel: "gpt-5.6-sol")

        XCTAssertEqual(report.succeededAccountIDs, [])
        XCTAssertEqual(report.failedAccountIDs, ["acct_align_unauth"])
        XCTAssertEqual(report.lastFailureStatusCode, 401)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            OpenAIQuotaAlignmentFeedback.from(report),
            .failed(statusCode: 401)
        )
        XCTAssertEqual(
            OpenAIQuotaAlignmentFeedback.from(report)?.message,
            L.alignQuotaFailedHTTP(401)
        )
    }

    func testSecondAlignWhileRunningIsIgnored() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "acct_align_busy",
            email: "busy@example.com"
        )
        let started = expectation(description: "first ping started")
        let gate = DispatchSemaphore(value: 0)

        MockURLProtocol.handler = { request in
            started.fulfill()
            gate.wait()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"id":"resp_busy"}"#.utf8)
            )
        }

        let service = OpenAIQuotaAlignmentService(urlSession: self.makeMockSession())
        async let first = service.align(accounts: [account], defaultModel: "gpt-5.6-sol")
        await fulfillment(of: [started], timeout: 2)
        let second = await service.align(accounts: [account], defaultModel: "gpt-5.6-sol")
        gate.signal()
        let firstReport = await first

        XCTAssertTrue(second.wasAlreadyRunning)
        XCTAssertEqual(firstReport.succeededAccountIDs, ["acct_align_busy"])
    }

    func testFeedbackUsesHTTPStatusAndAnnouncesSuccess() {
        var failed = OpenAIQuotaAlignmentReport()
        failed.failedAccountIDs = ["acct_a"]
        failed.lastFailureStatusCode = 400
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(failed), .failed(statusCode: 400))
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(failed)?.message, L.alignQuotaFailedHTTP(400))

        var skippedOnly = OpenAIQuotaAlignmentReport()
        skippedOnly.skippedAccountIDs = ["acct_b"]
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(skippedOnly), .noEligible)

        var succeeded = OpenAIQuotaAlignmentReport()
        succeeded.succeededAccountIDs = ["acct_c"]
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(succeeded), .succeeded)
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(succeeded)?.message, L.alignQuotaSucceeded)
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(succeeded)?.isSuccess, true)
        XCTAssertEqual(OpenAIQuotaAlignmentFeedback.from(succeeded)?.isError, false)
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(self.bodyData(from: request))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func jsonBool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool {
            return flag
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody, body.isEmpty == false {
            return body
        }
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
