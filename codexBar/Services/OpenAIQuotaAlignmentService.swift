import Foundation

/// 捕获用户为账号网关选择的代理；无效的显式选择不能降级为直连。
struct OpenAIQuotaAlignmentProxyRouting {
    enum Route: Equatable {
        case system
        case configured(OpenAIAccountGatewayConfiguredProxy)
        case unavailable
    }

    private let defaultRoute: Route
    private let routesByAccountID: [String: Route]

    init(config: CodexBarConfig) {
        if let address = config.openAI.aggregateGatewayProxyURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !address.isEmpty {
            self.defaultRoute = Self.supportedRoute(OpenAIAccountGatewayConfiguredProxy(address: address))
        } else {
            self.defaultRoute = .system
        }
        let profiles = OpenAIAccountGatewayConfiguredProxy.profilesByKey(fromInteropProxiesJSON: config.openAI.interopProxiesJSON)
        var routes: [String: Route] = [:]
        for account in config.oauthProvider()?.accounts ?? [] {
            guard let key = account.interopProxyKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { continue }
            routes[account.id] = Self.supportedRoute(profiles[key])
        }
        self.routesByAccountID = routes
    }

    func route(for accountID: String) -> Route {
        self.routesByAccountID[accountID] ?? self.defaultRoute
    }

    private static func supportedRoute(_ proxy: OpenAIAccountGatewayConfiguredProxy?) -> Route {
        // 共享网关配置没有代理认证处理；不能丢弃凭据后声称已继承用户的代理。
        guard let proxy, proxy.username == nil, proxy.password == nil else { return .unavailable }
        return .configured(proxy)
    }
}

enum OpenAIQuotaWindowStartEligibility: Equatable {
    case ready
    case active(resetAt: Date)
    case unavailable
    case unknown
}

enum OpenAIQuotaAlignmentPolicy {
    nonisolated static let promptText = "ok"
    nonisolated static let maxConcurrentAccounts = 3
    nonisolated static let fiveHourWindowSeconds = 18_000
    /// 并发短请求的启动时间可能略有差异；超过一分钟不宣称窗口对齐。
    nonisolated static let alignmentTolerance: TimeInterval = 60

    static func shouldShowEntry(isEnabled: Bool, hasAccounts: Bool) -> Bool {
        isEnabled && hasAccounts
    }

    static func isEligible(_ account: TokenAccount) -> Bool {
        account.isBanned == false && account.tokenExpired == false &&
            account.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func eligibility(_ account: TokenAccount, now: Date) -> OpenAIQuotaWindowStartEligibility {
        guard self.isEligible(account),
              account.primaryLimitWindowSeconds == self.fiveHourWindowSeconds else {
            return .unavailable
        }
        if account.secondaryExhausted,
           (account.secondaryResetAt ?? .distantFuture) > now {
            return .unavailable
        }
        if let resetAt = account.primaryResetAt {
            return resetAt > now ? .active(resetAt: resetAt) : .ready
        }
        // 新鲜额度快照确认尚未使用且没有重置时间时，尝试启动首个窗口。
        return account.primaryUsedPercent == 0 ? .ready : .unknown
    }

    static func model(defaultModel: String) -> String? {
        CodexBarGlobalSettings.normalizedModelID(defaultModel)
    }

    static func reasoningEffort(for modelID: String) -> String {
        CodexBarGlobalSettings.reasoningEffortOptions(for: modelID).first ?? "low"
    }

    static func requestBody(model: String) -> [String: Any] {
        [
            "model": model,
            "instructions": "Reply only with OK.",
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": self.promptText],
                    ],
                ],
            ],
            "store": false,
            "stream": true,
            "tools": [],
            "parallel_tool_calls": false,
            "include": [OpenAIAccountGatewayConfiguration.reasoningIncludeMarker],
            "reasoning": ["effort": self.reasoningEffort(for: model)],
        ]
    }
}

struct OpenAIQuotaAlignmentReport: Equatable {
    var completedAccountIDs: [String] = []
    var skippedAccountIDs: [String] = []
    var activeWindowAccountIDs: [String] = []
    var failedAccountIDs: [String] = []
    var modelUnavailableAccountIDs: [String] = []
    var proxyUnavailableAccountIDs: [String] = []
    var unverifiedAccountIDs: [String] = []
    var observedResetAtByAccountID: [String: Date] = [:]
    var lastFailureStatusCode: Int?
    var wasAlreadyRunning = false
    var wasDisabled = false

    var completedCount: Int { self.completedAccountIDs.count }
    var skippedCount: Int { self.skippedAccountIDs.count }
    var failedCount: Int { self.failedAccountIDs.count }

    var hasVerifiedAlignment: Bool {
        guard !self.wasDisabled, !self.wasAlreadyRunning,
              self.completedCount > 0, self.failedCount == 0, self.unverifiedAccountIDs.isEmpty,
              self.completedAccountIDs.allSatisfy({ self.observedResetAtByAccountID[$0] != nil }),
              self.observedResetAtByAccountID.count >= 2,
              let earliest = self.observedResetAtByAccountID.values.min(),
              let latest = self.observedResetAtByAccountID.values.max() else {
            return false
        }
        return latest.timeIntervalSince(earliest) <= OpenAIQuotaAlignmentPolicy.alignmentTolerance
    }
}

enum OpenAIQuotaAlignmentFeedback: Equatable {
    case noEligible
    case verified
    case completed(count: Int, skipped: Int)
    case modelUnavailable
    case proxyUnavailable
    case failed(statusCode: Int?)
    case partial(completed: Int, failed: Int, skipped: Int)

    static func from(_ report: OpenAIQuotaAlignmentReport) -> Self? {
        guard report.wasAlreadyRunning == false, report.wasDisabled == false else { return nil }
        if report.completedCount == 0, report.failedCount == 0 {
            return .noEligible
        }
        if report.failedCount > 0, report.completedCount == 0 {
            if report.proxyUnavailableAccountIDs.count == report.failedCount {
                return .proxyUnavailable
            }
            if report.modelUnavailableAccountIDs.count == report.failedCount {
                return .modelUnavailable
            }
            return .failed(statusCode: report.lastFailureStatusCode)
        }
        if report.failedCount > 0 {
            return .partial(completed: report.completedCount, failed: report.failedCount, skipped: report.skippedCount)
        }
        if report.hasVerifiedAlignment {
            return .verified
        }
        return .completed(count: report.completedCount, skipped: report.skippedCount)
    }

    var message: String {
        switch self {
        case .noEligible:
            return L.alignQuotaNoEligibleAccounts
        case .verified:
            return L.alignQuotaVerified
        case .completed(let count, let skipped):
            return L.alignQuotaCompleted(count, skipped: skipped)
        case .modelUnavailable:
            return L.alignQuotaModelUnavailable
        case .proxyUnavailable:
            return L.alignQuotaProxyUnavailable
        case .failed(let statusCode):
            if let statusCode { return L.alignQuotaFailedHTTP(statusCode) }
            return L.alignQuotaFailed
        case .partial(let completed, let failed, let skipped):
            return L.alignQuotaPartialFailure(completed: completed, failed: failed, skipped: skipped)
        }
    }

    var isError: Bool {
        switch self {
        case .failed, .partial, .modelUnavailable, .proxyUnavailable:
            return true
        case .noEligible, .verified, .completed:
            return false
        }
    }

    var isSuccess: Bool { self == .verified }
}

enum OpenAIQuotaAlignmentRequestOutcome: Equatable {
    case completed
    case failed(statusCode: Int?, modelUnavailable: Bool)

    static func isModelUnavailable(_ json: [String: Any]) -> Bool {
        let response = json["response"] as? [String: Any]
        let error = (json["error"] as? [String: Any]) ?? (response?["error"] as? [String: Any])
        guard let code = error?["code"] as? String else { return false }
        return ["model_not_found", "model_not_available", "model_not_supported", "unsupported_model", "model_access_denied"]
            .contains(code.lowercased())
    }
}

/// 只接受完整 SSE 事件里的正常完成状态；HTTP 200、[DONE] 或流结束本身都不代表成功。
struct OpenAIQuotaAlignmentStreamParser {
    private var dataLines: [String] = []
    private var eventType: String?
    private var lineBytes: [UInt8] = []
    private var ignoresNextLineFeed = false

    mutating func append(byte: UInt8) -> OpenAIQuotaAlignmentRequestOutcome? {
        if byte == 10, self.ignoresNextLineFeed {
            self.ignoresNextLineFeed = false
            return nil
        }
        if byte == 10 || byte == 13 {
            self.ignoresNextLineFeed = byte == 13
            guard let line = String(bytes: self.lineBytes, encoding: .utf8) else {
                return .failed(statusCode: nil, modelUnavailable: false)
            }
            self.lineBytes.removeAll(keepingCapacity: true)
            return self.append(line: line)
        }
        self.ignoresNextLineFeed = false
        guard self.lineBytes.count < 65_536 else {
            return .failed(statusCode: nil, modelUnavailable: false)
        }
        self.lineBytes.append(byte)
        return nil
    }

    mutating func append(line: String) -> OpenAIQuotaAlignmentRequestOutcome? {
        if line.isEmpty {
            defer {
                self.dataLines.removeAll(keepingCapacity: true)
                self.eventType = nil
            }
            guard self.dataLines.isEmpty == false,
                  let data = self.dataLines.joined(separator: "\n").data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            switch (json["type"] as? String) ?? self.eventType {
            case "response.completed":
                guard let response = json["response"] as? [String: Any],
                      response["status"] as? String == "completed",
                      response["error"] as? [String: Any] == nil else {
                    return .failed(statusCode: nil, modelUnavailable: false)
                }
                return .completed
            case "response.failed", "response.incomplete", "error":
                return .failed(statusCode: nil, modelUnavailable: OpenAIQuotaAlignmentRequestOutcome.isModelUnavailable(json))
            default:
                return nil
            }
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            self.dataLines.append(value)
        } else if line.hasPrefix("event:") {
            self.eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

struct OpenAIQuotaAlignmentService {
    nonisolated static let shared = OpenAIQuotaAlignmentService()

    private final class RunState {
        let lock = NSLock()
        var isRunning = false
    }

    private struct AccountOutcome {
        let accountID: String
        var completed = false
        var skipped = false
        var activeWindow = false
        var failed = false
        var modelUnavailable = false
        var proxyUnavailable = false
        var permissionRevoked = false
        var unverified = false
        var resetAt: Date?
        var statusCode: Int?
    }

    private let responsesURL: URL
    private let urlSession: URLSession
    private let proxySessionFactory: (URLSessionConfiguration) -> URLSession
    private let originator: String
    private let now: () -> Date
    private let runState = RunState()

    init(
        responsesURL: URL = OpenAIAccountGatewayConfiguration.upstreamResponsesURL,
        urlSession: URLSession? = nil,
        originator: String = OpenAIAccountGatewayConfiguration.originator,
        proxySessionFactory: @escaping (URLSessionConfiguration) -> URLSession = { URLSession(configuration: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.responsesURL = responsesURL
        let configuration = Self.transportConfiguration.makeURLSessionConfiguration()
        self.urlSession = urlSession ?? URLSession(configuration: configuration)
        self.proxySessionFactory = proxySessionFactory
        self.originator = originator
        self.now = now
    }

    func align(
        accounts: [TokenAccount],
        defaultModel: String,
        isEnabled: Bool = false,
        proxyRouting: OpenAIQuotaAlignmentProxyRouting,
        maxConcurrentAccounts: Int = OpenAIQuotaAlignmentPolicy.maxConcurrentAccounts,
        shouldContinue: @escaping @MainActor () -> Bool = { true },
        refreshAccount: @escaping @MainActor (TokenAccount) async -> TokenAccount?
    ) async -> OpenAIQuotaAlignmentReport {
        guard isEnabled else { return OpenAIQuotaAlignmentReport(wasDisabled: true) }
        guard self.beginRun() else { return OpenAIQuotaAlignmentReport(wasAlreadyRunning: true) }
        defer { self.endRun() }
        guard !Task.isCancelled, await shouldContinue() else { return OpenAIQuotaAlignmentReport(wasDisabled: true) }

        let model = OpenAIQuotaAlignmentPolicy.model(defaultModel: defaultModel)
        let concurrencyLimit = min(max(1, maxConcurrentAccounts), max(1, accounts.count))
        let results = await withTaskGroup(of: AccountOutcome.self, returning: [AccountOutcome].self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < accounts.count else { return }
                let account = accounts[nextIndex]
                nextIndex += 1
                group.addTask {
                    await self.startWindow(account: account, model: model, proxyRoute: proxyRouting.route(for: account.accountId),
                                           shouldContinue: shouldContinue, refreshAccount: refreshAccount)
                }
            }
            for _ in 0..<concurrencyLimit { enqueueNext() }
            var results: [AccountOutcome] = []
            while let result = await group.next() {
                results.append(result)
                enqueueNext()
            }
            return results
        }

        var report = OpenAIQuotaAlignmentReport()
        for result in results {
            if result.completed { report.completedAccountIDs.append(result.accountID) }
            if result.skipped { report.skippedAccountIDs.append(result.accountID) }
            if result.activeWindow { report.activeWindowAccountIDs.append(result.accountID) }
            if result.failed { report.failedAccountIDs.append(result.accountID) }
            if result.modelUnavailable { report.modelUnavailableAccountIDs.append(result.accountID) }
            if result.proxyUnavailable { report.proxyUnavailableAccountIDs.append(result.accountID) }
            if result.permissionRevoked { report.wasDisabled = true }
            if result.unverified { report.unverifiedAccountIDs.append(result.accountID) }
            if let resetAt = result.resetAt { report.observedResetAtByAccountID[result.accountID] = resetAt }
            if report.lastFailureStatusCode == nil { report.lastFailureStatusCode = result.statusCode }
        }
        return report
    }

    private func startWindow(
        account: TokenAccount,
        model: String?,
        proxyRoute: OpenAIQuotaAlignmentProxyRouting.Route,
        shouldContinue: @escaping @MainActor () -> Bool,
        refreshAccount: @escaping @MainActor (TokenAccount) async -> TokenAccount?
    ) async -> AccountOutcome {
        var result = AccountOutcome(accountID: account.accountId)
        guard !Task.isCancelled, await shouldContinue() else {
            result.skipped = true
            result.permissionRevoked = true
            return result
        }
        guard OpenAIQuotaAlignmentPolicy.isEligible(account) else {
            result.skipped = true
            return result
        }
        guard proxyRoute != .unavailable else {
            result.failed = true
            result.proxyUnavailable = true
            return result
        }
        let refreshed = await refreshAccount(account)
        guard !Task.isCancelled, await shouldContinue() else {
            result.skipped = true
            result.permissionRevoked = true
            return result
        }
        guard let refreshed, refreshed.accountId == account.accountId else {
            result.failed = true
            return result
        }
        switch OpenAIQuotaAlignmentPolicy.eligibility(refreshed, now: self.now()) {
        case .active(let resetAt):
            result.skipped = true
            result.activeWindow = true
            result.resetAt = resetAt
            return result
        case .unavailable:
            result.skipped = true
            return result
        case .unknown:
            result.skipped = true
            result.unverified = true
            return result
        case .ready:
            break
        }
        guard let model else {
            result.failed = true
            result.modelUnavailable = true
            return result
        }

        let outcome: OpenAIQuotaAlignmentRequestOutcome
        do {
            outcome = try await self.performPing(account: refreshed, model: model, proxyRoute: proxyRoute, shouldContinue: shouldContinue)
        } catch StartPermissionError.revoked {
            result.skipped = true
            result.permissionRevoked = true
            return result
        } catch {
            outcome = .failed(statusCode: nil, modelUnavailable: false)
        }
        // 失败/中断的请求也可能已消耗额度；都刷新界面，但不能因此把请求记为完成。
        let after = await refreshAccount(refreshed)
        switch outcome {
        case .failed(let statusCode, let modelUnavailable):
            result.failed = true
            result.statusCode = statusCode
            result.modelUnavailable = modelUnavailable
        case .completed:
            result.completed = true
            if let after, after.accountId == account.accountId,
               case .active(let resetAt) = OpenAIQuotaAlignmentPolicy.eligibility(after, now: self.now()) {
                result.resetAt = resetAt
            } else {
                result.unverified = true
            }
        }
        return result
    }

    private enum StartPermissionError: Error { case revoked }

    private static var transportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration {
        OpenAIAccountGatewayUpstreamTransportConfiguration(
            requestTimeout: 20, resourceTimeout: 60, webSocketReadyBudget: 8, waitsForConnectivity: false
        )
    }

    private func performPing(
        account: TokenAccount,
        model: String,
        proxyRoute: OpenAIQuotaAlignmentProxyRouting.Route,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws -> OpenAIQuotaAlignmentRequestOutcome {
        var request = URLRequest(url: self.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: OpenAIQuotaAlignmentPolicy.requestBody(model: model))
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue(self.originator, forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let session: URLSession
        let ownsSession: Bool
        switch proxyRoute {
        case .system:
            session = self.urlSession
            ownsSession = false
        case .configured(let proxy):
            session = self.proxySessionFactory(Self.transportConfiguration.makeURLSessionConfiguration(explicitProxy: proxy))
            ownsSession = true
        case .unavailable:
            throw URLError(.cannotFindHost)
        }
        defer { if ownsSession { session.finishTasksAndInvalidate() } }
        guard !Task.isCancelled, await shouldContinue() else { throw StartPermissionError.revoked }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if (200...299).contains(http.statusCode) == false {
            var body = Data()
            do {
                for try await byte in bytes {
                    guard body.count < 65_536 else { break }
                    body.append(byte)
                }
            } catch {
                // 保留已获取到的 HTTP 错误，不把错误页读取中断误报成成功。
            }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            return .failed(statusCode: http.statusCode, modelUnavailable: OpenAIQuotaAlignmentRequestOutcome.isModelUnavailable(json))
        }

        var parser = OpenAIQuotaAlignmentStreamParser()
        for try await byte in bytes {
            if let terminal = parser.append(byte: byte) { return terminal }
        }
        return .failed(statusCode: nil, modelUnavailable: false)
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
