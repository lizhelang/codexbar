import Foundation

enum OpenAIQuotaAlignmentPolicy {
    nonisolated static let promptText = "ok"
    nonisolated static let maxConcurrentAccounts = 3

    static func isEligible(_ account: TokenAccount) -> Bool {
        account.isAvailableForNextUseRouting &&
            account.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func modelCandidates(defaultModel: String) -> [String] {
        let catalog = CodexBarGlobalSettings.reasoningEffortOptionsByModel.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .sorted { lhs, rhs in
                let leftRank = self.modelRank(lhs)
                let rightRank = self.modelRank(rhs)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

        var result: [String] = []
        var seen = Set<String>()
        for modelID in catalog where seen.insert(modelID.lowercased()).inserted {
            result.append(modelID)
        }

        let trimmedDefault = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDefault.isEmpty == false, seen.insert(trimmedDefault.lowercased()).inserted {
            result.append(trimmedDefault)
        }
        return result
    }

    static func reasoningEffort(for modelID: String) -> String {
        CodexBarGlobalSettings.reasoningEffortOptions(for: modelID).first ?? "low"
    }

    static func isRetryableModelFailure(statusCode: Int) -> Bool {
        statusCode == 400 || statusCode == 404
    }

    static func requestBody(model: String) -> [String: Any] {
        [
            "model": model,
            "instructions": "",
            "input": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": self.promptText,
                        ],
                    ],
                ],
            ],
            "store": false,
            "stream": true,
            "tools": [],
            "parallel_tool_calls": false,
            "include": [
                OpenAIAccountGatewayConfiguration.reasoningIncludeMarker,
            ],
            "reasoning": [
                "effort": self.reasoningEffort(for: model),
            ],
        ]
    }

    private static func modelRank(_ modelID: String) -> Int {
        let normalized = modelID.lowercased()
        if normalized.contains("luna") { return 0 }
        if normalized.contains("terra") { return 1 }
        if normalized.contains("sol") { return 2 }
        return 3
    }
}

struct OpenAIQuotaAlignmentReport: Equatable {
    var succeededAccountIDs: [String] = []
    var skippedAccountIDs: [String] = []
    var failedAccountIDs: [String] = []
    var lastFailureStatusCode: Int?
    var wasAlreadyRunning = false

    var succeededCount: Int { self.succeededAccountIDs.count }
    var skippedCount: Int { self.skippedAccountIDs.count }
    var failedCount: Int { self.failedAccountIDs.count }
    var eligibleCount: Int { self.succeededCount + self.failedCount }
}

enum OpenAIQuotaAlignmentFeedback: Equatable {
    case noEligible
    case succeeded
    case failed(statusCode: Int?)
    case partial(count: Int)

    static func from(_ report: OpenAIQuotaAlignmentReport) -> Self? {
        if report.wasAlreadyRunning {
            return nil
        }
        if report.eligibleCount == 0 {
            return .noEligible
        }
        if report.failedCount > 0, report.succeededCount == 0 {
            return .failed(statusCode: report.lastFailureStatusCode)
        }
        if report.failedCount > 0 {
            return .partial(count: report.failedCount)
        }
        return .succeeded
    }

    var message: String {
        switch self {
        case .noEligible:
            return L.alignQuotaNoEligibleAccounts
        case .succeeded:
            return L.alignQuotaSucceeded
        case .failed(let statusCode):
            if let statusCode {
                return L.alignQuotaFailedHTTP(statusCode)
            }
            return L.alignQuotaFailed
        case .partial(let count):
            return L.alignQuotaPartialFailure(count)
        }
    }

    var isError: Bool {
        switch self {
        case .noEligible, .succeeded:
            return false
        case .failed, .partial:
            return true
        }
    }

    var isSuccess: Bool {
        self == .succeeded
    }
}

struct OpenAIQuotaAlignmentService {
    nonisolated static let shared = OpenAIQuotaAlignmentService()

    private final class RunState {
        let lock = NSLock()
        var isRunning = false
    }

    private let responsesURL: URL
    private let urlSession: URLSession
    private let originator: String
    private let runState = RunState()

    init(
        responsesURL: URL = OpenAIAccountGatewayConfiguration.upstreamResponsesURL,
        urlSession: URLSession? = nil,
        originator: String = OpenAIAccountGatewayConfiguration.originator
    ) {
        self.responsesURL = responsesURL
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
        self.originator = originator
    }

    func align(
        accounts: [TokenAccount],
        defaultModel: String,
        maxConcurrentAccounts: Int = 3
    ) async -> OpenAIQuotaAlignmentReport {
        guard self.beginRun() else {
            return OpenAIQuotaAlignmentReport(wasAlreadyRunning: true)
        }
        defer { self.endRun() }

        let modelCandidates = OpenAIQuotaAlignmentPolicy.modelCandidates(defaultModel: defaultModel)
        var report = OpenAIQuotaAlignmentReport()
        var eligible: [TokenAccount] = []
        eligible.reserveCapacity(accounts.count)

        for account in accounts {
            if OpenAIQuotaAlignmentPolicy.isEligible(account) {
                eligible.append(account)
            } else {
                report.skippedAccountIDs.append(account.accountId)
            }
        }

        guard eligible.isEmpty == false, modelCandidates.isEmpty == false else {
            return report
        }

        let concurrencyLimit = min(max(1, maxConcurrentAccounts), eligible.count)
        let pingResults = await withTaskGroup(
            of: (accountID: String, succeeded: Bool, statusCode: Int?).self,
            returning: [(accountID: String, succeeded: Bool, statusCode: Int?)].self
        ) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < eligible.count else { return }
                let account = eligible[nextIndex]
                nextIndex += 1
                group.addTask {
                    let outcome = await self.ping(account: account, modelCandidates: modelCandidates)
                    return (account.accountId, outcome.succeeded, outcome.statusCode)
                }
            }

            for _ in 0..<concurrencyLimit {
                enqueueNext()
            }

            var results: [(accountID: String, succeeded: Bool, statusCode: Int?)] = []
            while let result = await group.next() {
                results.append(result)
                enqueueNext()
            }
            return results
        }

        for result in pingResults {
            if result.succeeded {
                report.succeededAccountIDs.append(result.accountID)
            } else {
                report.failedAccountIDs.append(result.accountID)
                if report.lastFailureStatusCode == nil {
                    report.lastFailureStatusCode = result.statusCode
                }
            }
        }
        return report
    }

    private func ping(
        account: TokenAccount,
        modelCandidates: [String]
    ) async -> (succeeded: Bool, statusCode: Int?) {
        var lastStatusCode: Int?
        for (index, model) in modelCandidates.enumerated() {
            do {
                let http = try await self.performPing(account: account, model: model)
                lastStatusCode = http.statusCode
                if (200...299).contains(http.statusCode) {
                    return (true, http.statusCode)
                }
                let canRetryModel = index + 1 < modelCandidates.count &&
                    OpenAIQuotaAlignmentPolicy.isRetryableModelFailure(statusCode: http.statusCode)
                if canRetryModel {
                    continue
                }
                return (false, http.statusCode)
            } catch {
                return (false, lastStatusCode)
            }
        }
        return (false, lastStatusCode)
    }

    private func performPing(account: TokenAccount, model: String) async throws -> HTTPURLResponse {
        let bodyObject = OpenAIQuotaAlignmentPolicy.requestBody(model: model)
        guard JSONSerialization.isValidJSONObject(bodyObject) else {
            throw URLError(.cannotParseResponse)
        }
        let body = try JSONSerialization.data(withJSONObject: bodyObject)

        var request = URLRequest(url: self.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue(self.originator, forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await self.urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        do {
            for try await _ in bytes {}
        } catch {
            if (200...299).contains(http.statusCode) == false {
                return http
            }
            throw error
        }
        return http
    }

    private func beginRun() -> Bool {
        self.runState.lock.lock()
        defer { self.runState.lock.unlock() }
        guard self.runState.isRunning == false else { return false }
        self.runState.isRunning = true
        return true
    }

    private func endRun() {
        self.runState.lock.lock()
        self.runState.isRunning = false
        self.runState.lock.unlock()
    }
}
