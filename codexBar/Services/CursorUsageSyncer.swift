import Foundation
import SQLite3
import CoreFoundation

enum CursorUsageSyncError: Error, Equatable {
    case noDesktopSession
    case unreadableDesktopSession
    case invalidDesktopSession
    case sessionExpired
    case networkFailure
    case invalidResponse
    case incompleteHistory
    case responseTooLarge

    var statusDetail: String {
        switch self {
        case .noDesktopSession: "未找到已登录的 Cursor，可导入 CSV"
        case .unreadableDesktopSession: "Cursor 登录状态不可读，可导入 CSV"
        case .invalidDesktopSession: "Cursor 登录状态无效，可导入 CSV"
        case .sessionExpired: "Cursor 登录已过期，请在 Cursor 中重新登录"
        case .networkFailure: "Cursor 用量接口暂时不可用"
        case .invalidResponse: "Cursor 用量接口返回格式已变化"
        case .incompleteHistory: "Cursor 用量分页未完整读取"
        case .responseTooLarge: "Cursor 用量响应超过大小限制"
        }
    }
}

nonisolated protocol CursorUsageSyncing: Sendable {
    func sync(now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot
}

nonisolated protocol CursorUsageHTTPTransport: Sendable {
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse)
}

/// A separate, ephemeral session keeps Cursor's cookie out of the app's shared
/// cookie jar. Refusing redirects also prevents it from reaching another host.
nonisolated final class CursorUsageURLSessionTransport: CursorUsageHTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: configuration, delegate: CursorNoRedirectDelegate(), delegateQueue: nil)
    }

    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await self.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CursorUsageSyncError.invalidResponse }
        if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > limit {
            throw CursorUsageSyncError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(limit, 512 * 1024))
        for try await byte in bytes {
            guard data.count < limit else { throw CursorUsageSyncError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}

private nonisolated final class CursorNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Reads exactly one Cursor auth value from the desktop's read-only state DB.
/// Neither the value nor a derived credential is written to Codexbar storage.
nonisolated struct CursorDesktopSessionReader: Sendable {
    let databaseURL: URL

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func sessionCookie() throws -> String {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            throw CursorUsageSyncError.noDesktopSession
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            self.databaseURL.path, &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CursorUsageSyncError.unreadableDesktopSession
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1",
            -1, &statement, nil
        ) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw CursorUsageSyncError.unreadableDesktopSession
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw result == SQLITE_DONE ? CursorUsageSyncError.noDesktopSession : .unreadableDesktopSession
        }
        guard let pointer = sqlite3_column_text(statement, 0) else {
            throw CursorUsageSyncError.invalidDesktopSession
        }
        return try Self.normalizedCookie(String(cString: pointer))
    }

    static func normalizedCookie(_ rawValue: String) throws -> String {
        var token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 16 * 1024 else {
            throw CursorUsageSyncError.invalidDesktopSession
        }
        if token.lowercased().hasPrefix("cookie:") {
            token = String(token.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = token.range(of: "WorkosCursorSessionToken=", options: .caseInsensitive) {
            token = String(token[range.upperBound...].prefix(while: { $0 != ";" && !$0.isWhitespace }))
        }
        guard !token.isEmpty, token.utf8.count <= 16 * 1024,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw CursorUsageSyncError.invalidDesktopSession
        }
        let separator = token.range(of: "%3A%3A", options: .caseInsensitive)
            ?? token.range(of: "::")
        let userID: String
        let jwt: String
        if let separator {
            userID = String(token[..<separator.lowerBound])
            jwt = String(token[separator.upperBound...])
        } else {
            guard let parsedUserID = Self.userID(fromJWT: token) else {
                throw CursorUsageSyncError.invalidDesktopSession
            }
            userID = parsedUserID
            jwt = token
        }
        let jwtSegments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard userID.range(of: #"^user_[A-Za-z0-9_]+$"#, options: .regularExpression) != nil,
              jwtSegments.count == 3,
              jwtSegments.allSatisfy({ !$0.isEmpty && $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }) else {
            throw CursorUsageSyncError.invalidDesktopSession
        }
        return "\(userID)%3A%3A\(jwt)"
    }

    private static func userID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              let range = subject.range(of: #"user_[A-Za-z0-9_]+"#, options: .regularExpression) else {
            return nil
        }
        return String(subject[range])
    }
}

/// Cursor's dashboard endpoint is private and can change independently of this
/// app. A page must be complete before its data replaces an earlier snapshot.
nonisolated struct CursorUsageSyncer: CursorUsageSyncing {
    private static let endpoint = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    private static let pageSize = 500
    private static let maxPages = 500
    private static let maxBytes = 64 * 1024 * 1024

    private let sessionReader: CursorDesktopSessionReader
    private let transport: any CursorUsageHTTPTransport

    init(
        sessionReader: CursorDesktopSessionReader = CursorDesktopSessionReader(),
        transport: any CursorUsageHTTPTransport = CursorUsageURLSessionTransport()
    ) {
        self.sessionReader = sessionReader
        self.transport = transport
    }

    func sync(now: Date = Date(), calendar: Calendar = .current) async throws -> ToolUsageSnapshot {
        let cookie = try self.sessionReader.sessionCookie()
        let startedAt = Date()
        var bytesRead = 0
        var events: [[String: Any]] = []
        var expectedCount: Int?
        var seenEvents = Set<Data>()
        var completed = false

        for page in 1...Self.maxPages {
            let remaining = 30 - Date().timeIntervalSince(startedAt)
            guard remaining > 0 else { throw CursorUsageSyncError.incompleteHistory }
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = min(15, remaining)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.cursor.com/settings", forHTTPHeaderField: "Referer")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "teamId": 0, "page": page, "pageSize": Self.pageSize,
            ])

            let responseData: Data
            let response: HTTPURLResponse
            do {
                (responseData, response) = try await self.transport.data(
                    for: request, limit: Self.maxBytes - bytesRead
                )
            } catch let error as CursorUsageSyncError {
                throw error
            } catch {
                throw CursorUsageSyncError.networkFailure
            }
            guard response.url?.host == Self.endpoint.host,
                  response.url?.scheme == "https" else { throw CursorUsageSyncError.invalidResponse }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw CursorUsageSyncError.sessionExpired
            }
            guard (200...299).contains(response.statusCode) else {
                throw CursorUsageSyncError.networkFailure
            }
            bytesRead += responseData.count
            guard bytesRead <= Self.maxBytes else { throw CursorUsageSyncError.responseTooLarge }
            guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let pageEvents = object["usageEventsDisplay"] as? [[String: Any]] else {
                throw CursorUsageSyncError.invalidResponse
            }
            guard let number = object["totalUsageEventsCount"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue >= 0,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue <= Double(Self.maxPages * Self.pageSize) else {
                throw CursorUsageSyncError.invalidResponse
            }
            let reportedCount = number.intValue
            if let expectedCount, expectedCount != reportedCount {
                throw CursorUsageSyncError.incompleteHistory
            }
            expectedCount = reportedCount
            guard pageEvents.count <= Self.pageSize else { throw CursorUsageSyncError.invalidResponse }
            guard events.count + pageEvents.count <= reportedCount else {
                throw CursorUsageSyncError.incompleteHistory
            }
            for event in pageEvents {
                guard let fingerprint = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
                      seenEvents.insert(fingerprint).inserted else {
                    throw CursorUsageSyncError.incompleteHistory
                }
            }
            events.append(contentsOf: pageEvents)
            if events.count == reportedCount {
                completed = true
                break
            }
            guard !pageEvents.isEmpty else { throw CursorUsageSyncError.incompleteHistory }
        }
        guard completed, events.count == expectedCount else { throw CursorUsageSyncError.incompleteHistory }
        return try Self.snapshot(from: events, now: now, calendar: calendar)
    }

    static func snapshot(from events: [[String: Any]], now: Date, calendar: Calendar) throws -> ToolUsageSnapshot {
        struct Bucket {
            var input = 0
            var output = 0
            var cacheRead = 0
            var cacheWrite = 0
            var total = 0
            var knownCost = 0.0
            var unknownCost = false
        }
        var byDay: [Date: Bucket] = [:]
        var latestUsageAt: Date?
        var usageRecords: [ToolUsageRecord] = []
        for (index, event) in events.enumerated() {
            guard let timestamp = Self.timestamp(event["timestamp"]) else {
                throw CursorUsageSyncError.invalidResponse
            }
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
            guard date <= now else { continue }
            let day = calendar.startOfDay(for: date)
            let usage = event["tokenUsage"] as? [String: Any]
            let hasTokenFields = usage.map { value in
                ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]
                    .contains(where: { value[$0] != nil })
            } ?? false
            if event["tokenUsage"] != nil, !(event["tokenUsage"] is NSNull), usage == nil {
                throw CursorUsageSyncError.invalidResponse
            }
            if !hasTokenFields && Self.boolean(event["isTokenBasedCall"]) != false {
                throw CursorUsageSyncError.invalidResponse
            }
            let input = try Self.tokenCount(usage?["inputTokens"])
            let output = try Self.tokenCount(usage?["outputTokens"])
            let cacheRead = try Self.tokenCount(usage?["cacheReadTokens"])
            let cacheWrite = try Self.tokenCount(usage?["cacheWriteTokens"])
            let total = try Self.sum([input, output, cacheRead, cacheWrite])
            var bucket = byDay[day] ?? Bucket()
            bucket.input = try Self.sum([bucket.input, input])
            bucket.output = try Self.sum([bucket.output, output])
            bucket.cacheRead = try Self.sum([bucket.cacheRead, cacheRead])
            bucket.cacheWrite = try Self.sum([bucket.cacheWrite, cacheWrite])
            bucket.total = try Self.sum([bucket.total, total])

            // API-equivalent usage value remains nonzero for requests included in a subscription.
            // chargedCents describes additional billing and must not overwrite tokenUsage.totalCents.
            let billedCost: Double?
            if Self.boolean(event["isChargeable"]) == false {
                billedCost = 0
            } else if Self.boolean(event["isChargeable"]) == true,
                      let cents = Self.nonnegativeFiniteDouble(event["chargedCents"]) {
                billedCost = cents / 100
            } else { billedCost = nil }
            let usageCents = Self.nonnegativeFiniteDouble(usage?["totalCents"])
                ?? Self.nonnegativeFiniteDouble(event["totalCents"])
            let eventCost = usageCents.map { $0 / 100 } ?? billedCost.flatMap { $0 > 0 ? $0 : nil }
            if let eventCost {
                bucket.knownCost += eventCost
                guard bucket.knownCost.isFinite else { throw CursorUsageSyncError.invalidResponse }
            } else { bucket.unknownCost = true }
            byDay[day] = bucket
            usageRecords.append(ToolUsageRecord(
                id: (event["id"] as? String) ?? "cursor:\(timestamp):\(index)", timestamp: date,
                modelID: event["model"] as? String,
                sessionID: event["conversationId"] as? String,
                inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite, totalTokens: total, costUSD: eventCost,
                costEvidence: eventCost == nil ? nil : .reported, billedCostUSD: billedCost
            ))
            if latestUsageAt.map({ date > $0 }) ?? true { latestUsageAt = date }
        }
        let dailyEntries = byDay.keys.sorted().compactMap { day -> ToolUsageDailyEntry? in
            guard let bucket = byDay[day] else { return nil }
            return ToolUsageDailyEntry(
                date: day, inputTokens: bucket.input, outputTokens: bucket.output,
                cacheReadTokens: bucket.cacheRead, cacheWriteTokens: bucket.cacheWrite,
                totalTokens: bucket.total,
                costUSD: bucket.unknownCost ? nil : bucket.knownCost
            )
        }
        return ToolCostEstimator.reprice(ToolUsageSnapshot(
            client: .cursor,
            availability: dailyEntries.isEmpty ? .noRecords : .ready,
            evidence: .server,
            dailyEntries: dailyEntries,
            usageRecords: usageRecords,
            latestUsageAt: latestUsageAt,
            refreshedAt: now,
            statusDetail: dailyEntries.isEmpty
                ? "Cursor 账号暂无用量记录"
                : "已自动同步 Cursor 的 \(events.count) 条用量记录"
        ), calendar: calendar)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func tokenCount(_ value: Any?) throws -> Int {
        guard let value else { return 0 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue < Double(Int.max) else {
            throw CursorUsageSyncError.invalidResponse
        }
        return number.intValue
    }

    private static func nonnegativeFiniteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private static func timestamp(_ value: Any?) -> Int64? {
        if let string = value as? String, let milliseconds = Int64(string), milliseconds > 0 {
            return milliseconds
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite,
           number.doubleValue > 0,
           number.doubleValue.rounded() == number.doubleValue,
           number.doubleValue < Double(Int64.max) {
            return number.int64Value
        }
        return nil
    }

    private static func sum(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values {
            let (next, overflow) = result.addingReportingOverflow(value)
            guard !overflow else { throw CursorUsageSyncError.invalidResponse }
            result = next
        }
        return result
    }
}
