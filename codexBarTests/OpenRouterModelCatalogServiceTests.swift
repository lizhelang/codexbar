import Foundation
import XCTest

@MainActor
final class OpenRouterModelCatalogServiceTests: CodexBarTestCase {
    func testFetchCatalogParsesAndSortsModelsViaRust() async throws {
        var capturedAuthorization: String?
        var capturedAccept: String?

        MockURLProtocol.handler = { request in
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            capturedAccept = request.value(forHTTPHeaderField: "Accept")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(
                """
                {
                  "data": [
                    {"id":" openai/gpt-4.1 ","name":" GPT-4.1 "},
                    {"id":"", "name":"skip"},
                    {"id":"anthropic/claude-3.7-sonnet","name":"Claude 3.7 Sonnet"},
                    {"id":"google/gemini-2.5-pro","name":"Gemini 2.5 Pro"},
                    {"id":"   ", "name":"skip-whitespace"}
                  ]
                }
                """.utf8
            )
            return (response, body)
        }

        let fetchedAt = Date(timeIntervalSince1970: 1_777_182_500)
        let service = OpenRouterModelCatalogService(
            urlSession: self.makeMockSession(),
            now: { fetchedAt }
        )

        let snapshot = try await service.fetchCatalog(apiKey: "  sk-or-v1-primary  ")

        XCTAssertEqual(capturedAuthorization, "Bearer sk-or-v1-primary")
        XCTAssertEqual(capturedAccept, "application/json")
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
        XCTAssertEqual(
            snapshot.models.map(\.id),
            [
                "anthropic/claude-3.7-sonnet",
                "google/gemini-2.5-pro",
                "openai/gpt-4.1",
            ]
        )
        XCTAssertEqual(
            snapshot.models.map(\.name),
            [
                "Claude 3.7 Sonnet",
                "Gemini 2.5 Pro",
                "GPT-4.1",
            ]
        )
    }

    func testFetchCatalogThrowsOnInvalidJSON() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{".utf8))
        }

        let service = OpenRouterModelCatalogService(urlSession: self.makeMockSession())

        await XCTAssertThrowsErrorAsync(try await service.fetchCatalog(apiKey: "sk-or-v1-primary")) { error in
            XCTAssertEqual(error as? URLError, URLError(.cannotDecodeRawData))
        }
    }

    func testFetchCatalogRejectsEmptyAPIKey() async {
        let service = OpenRouterModelCatalogService(urlSession: self.makeMockSession())

        await XCTAssertThrowsErrorAsync(try await service.fetchCatalog(apiKey: "   ")) { error in
            XCTAssertEqual(error as? TokenStoreError, .invalidInput)
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown")
    } catch {
        verify(error)
    }
}
