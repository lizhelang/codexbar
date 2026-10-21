import Foundation

/// The unified Grok dashboard exports Cursor, Grok Bot and Grok Chat in one ledger.
/// The old filtered-usage endpoint does not contain the new subscription's events.
nonisolated struct CursorBillingUsageSyncer {
    static let exportPath = "/api/dashboard/v2/export-billing-items-csv"
    private static let identityPath = "/aiserver.v1.DashboardService/GetMe"
    private static let windowSeconds: TimeInterval = 31 * 24 * 60 * 60
    private static let byteLimit = 64 * 1024 * 1024
    private let transport: any CursorUsageHTTPTransport
    private let monotonicNow: @Sendable () -> TimeInterval

    init(transport: any CursorUsageHTTPTransport = CursorUsageURLSessionTransport(),
         monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.monotonicNow = monotonicNow
    }

    func sync(sessionCookie: String, legacy: ToolUsageSnapshot, previous: ToolUsageSnapshot?,
              now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        let now = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        let cookie = try CursorAccountService.normalize(sessionCookie)
        guard let token = CursorAccountService.sessionAccessToken(sessionCookie: cookie) else {
            throw CursorAccountError.invalidCredential
        }
        let started = self.monotonicNow()
        var identity = URLRequest(url: URL(string: "https://api2.cursor.sh" + Self.identityPath)!)
        identity.httpMethod = "POST"
        identity.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        identity.setValue("application/json", forHTTPHeaderField: "Content-Type")
        identity.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        identity.httpBody = Data("{}".utf8)
        let (identityData, _) = try await self.fetch(identity, started: started, limit: 1024 * 1024)
        guard let object = try? JSONSerialization.jsonObject(with: identityData) as? [String: Any],
              CursorAccountService.canonicalUserID(object["authId"] as? String)
                == (try CursorAccountService.userID(sessionCookie: cookie)) else {
            throw CursorAccountError.identityMismatch
        }
        guard let created = (object["createdAt"] as? String).flatMap(Self.date), created <= now else {
            throw CursorAccountError.invalidResponse
        }
        // Account creation provides the authenticated export lower bound. Retain any older
        // legacy records separately; never fabricate a date for a migrated account.
        let coverageStart = min(created, legacy.usageRecords.map(\.timestamp).min() ?? created)
        let priorCoverage = previous?.billingHistoryInterval
        let reusable = priorCoverage.map {
            $0.start <= coverageStart && $0.end <= now && $0.start <= $0.end
        } == true
        let requestedStart = reusable ? max(coverageStart, min(priorCoverage!.end, now.addingTimeInterval(-Self.windowSeconds))) : coverageStart
        // Query bounds have millisecond precision. Use exactly that same bound when
        // replacing cached rows, so a sub-millisecond boundary cannot retain a row twice.
        let start = Date(timeIntervalSince1970: (requestedStart.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        var records: [String: ToolUsageRecord] = [:]
        for row in previous?.usageRecords.filter({
            $0.id.hasPrefix("cursor-billing:")
        }) ?? [] {
            if let other = records[row.id], other != row { throw CursorAccountError.incompleteHistory }
            records[row.id] = row
        }
        var fetched: [String: ToolUsageRecord] = [:]
        var bytes = identityData.count
        var cursor = now
        var windows = 0
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        while cursor > start {
            windows += 1
            guard windows <= 240 else { throw CursorAccountError.incompleteHistory }
            let beginning = max(start, cursor.addingTimeInterval(-Self.windowSeconds))
            var url = URLComponents(string: "https://cursor.com" + Self.exportPath)!
            url.queryItems = [URLQueryItem(name: "scope", value: "user"),
                             URLQueryItem(name: "startTime", value: formatter.string(from: beginning)),
                             URLQueryItem(name: "endTime", value: formatter.string(from: cursor))]
            var request = URLRequest(url: url.url!)
            request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
            request.setValue("text/csv", forHTTPHeaderField: "Accept")
            request.setValue("https://cursor.com/dashboard/usage", forHTTPHeaderField: "Referer")
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await self.fetch(request, started: started, limit: Self.byteLimit - bytes) }
            catch let error as CursorAccountError where cursor < now && (error == .networkFailure || error == .incompleteHistory) {
                // Old months can be temporarily unavailable in the migrated ledger.
                // Keep fresh recent records and older cached history; retry the gap later.
                break
            }
            bytes += data.count
            guard response.mimeType == "text/csv", let text = String(data: data, encoding: .utf8) else {
                throw CursorAccountError.invalidResponse
            }
            let page: [ToolUsageRecord]
            do { page = try CursorBillingCSVParser().parse(text, now: now) }
            catch { throw CursorAccountError.invalidResponse }
            // Adjacent windows may both include their boundary. Stable billing IDs below
            // deduplicate that boundary; rows outside the requested range are never accepted.
            guard page.allSatisfy({ $0.timestamp >= beginning.addingTimeInterval(-0.001) && $0.timestamp <= cursor }) else {
                throw CursorAccountError.invalidResponse
            }
            records = records.filter { $0.value.timestamp < beginning || $0.value.timestamp >= cursor }
            for row in page {
                if let other = fetched[row.id], other != row { throw CursorAccountError.incompleteHistory }
                fetched[row.id] = row
                records[row.id] = row
            }
            cursor = beginning
        }
        let complete = cursor <= start
        return try Self.merged(legacy: legacy, billing: Array(records.values),
                               coverage: DateInterval(start: complete ? coverageStart : cursor, end: now),
                               now: now, calendar: calendar, incompleteBilling: !complete)
    }

    private func fetch(_ source: URLRequest, started: TimeInterval, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let remaining = 120 - (self.monotonicNow() - started)
        guard remaining > 0 else { throw CursorAccountError.incompleteHistory }
        guard limit > 0 else { throw CursorAccountError.responseTooLarge }
        var request = source
        request.timeoutInterval = min(20, remaining)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await self.transport.data(for: request, limit: limit) }
        catch { throw CursorAccountError.sanitized(error) }
        guard self.monotonicNow() - started < 120 else { throw CursorAccountError.incompleteHistory }
        guard data.count <= limit else { throw CursorAccountError.responseTooLarge }
        guard response.url?.scheme == "https", response.url?.host == source.url?.host,
              response.url?.port == nil, response.url?.path == source.url?.path else {
            throw CursorAccountError.invalidResponse
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw CursorAccountError.authenticationRequired }
        guard response.statusCode == 200 else { throw CursorAccountError.networkFailure }
        return (data, response)
    }

    static func merged(legacy: ToolUsageSnapshot, billing: [ToolUsageRecord], coverage: DateInterval,
                       now: Date, calendar: Calendar, incompleteBilling: Bool = false) throws -> ToolUsageSnapshot {
        // No guessed migration timestamp: legacy requests can coexist with v2 events.
        // Match only identical timestamps/counters and compatible models, with multiplicity.
        var old = Dictionary(grouping: legacy.usageRecords, by: Self.fingerprint)
        var records: [ToolUsageRecord] = []
        for row in billing.sorted(by: { $0.id < $1.id }) {
            let key = Self.fingerprint(row)
            if var matches = old[key], let index = matches.firstIndex(where: {
                Self.sameProduct(billing: row, legacy: $0)
                    && (row.modelID == nil || $0.modelID == nil || row.modelID == $0.modelID)
            }) {
                let existing = matches.remove(at: index)
                old[key] = matches
                records.append(ToolUsageRecord(id: row.id, timestamp: row.timestamp,
                    modelID: row.modelID ?? existing.modelID, sessionID: existing.sessionID,
                    sessionTitle: existing.sessionTitle, projectPath: existing.projectPath,
                    inputTokens: row.inputTokens, outputTokens: row.outputTokens,
                    cacheReadTokens: row.cacheReadTokens, cacheWriteTokens: row.cacheWriteTokens,
                    totalTokens: row.totalTokens, costUSD: existing.costUSD, costEvidence: existing.costEvidence,
                    billedCostUSD: row.billedCostUSD))
            } else { records.append(row) }
        }
        records.append(contentsOf: old.values.flatMap { $0 })
        records.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        var days: [Date: [ToolUsageRecord]] = Dictionary(grouping: records) { calendar.startOfDay(for: $0.timestamp) }
        // The legacy synchronizer currently produces complete records. Keep daily-only
        // entries too for callers with older snapshots, without silently losing history.
        let legacyOnlyDays = legacy.dailyEntries.filter { days[$0.date] == nil }
        var entries: [ToolUsageDailyEntry] = []
        for day in days.keys.sorted() {
            let rows = days.removeValue(forKey: day)!
            func sum(_ key: KeyPath<ToolUsageRecord, Int>) throws -> Int {
                var value = 0
                for row in rows {
                    let (next, overflow) = value.addingReportingOverflow(row[keyPath: key])
                    guard !overflow else { throw CursorAccountError.invalidResponse }
                    value = next
                }
                return value
            }
            entries.append(ToolUsageDailyEntry(date: day, inputTokens: try sum(\.inputTokens),
                outputTokens: try sum(\.outputTokens), cacheReadTokens: try sum(\.cacheReadTokens),
                cacheWriteTokens: try sum(\.cacheWriteTokens), totalTokens: try sum(\.totalTokens), costUSD: nil))
        }
        entries.append(contentsOf: legacyOnlyDays)
        entries.sort { $0.date < $1.date }
        return ToolCostEstimator.reprice(ToolUsageSnapshot(client: .cursor,
            availability: legacy.availability == .partial || incompleteBilling ? (entries.isEmpty ? .failed : .partial)
                : (entries.isEmpty ? .noRecords : .ready), evidence: .server,
            dailyEntries: entries, usageRecords: records, latestUsageAt: records.map(\.timestamp).max(),
            refreshedAt: now, statusDetail: "已同步账号服务端明细（Grok Bot、Grok 网页及 Cursor，含其他设备）"
                + (legacy.availability == .partial ? "；旧版接口本次未返回记录，沿用已保存历史" : "")
                + (incompleteBilling ? "；部分旧月份导出暂不可用，已保留近期用量与已保存历史" : ""),
            billingHistoryInterval: coverage), calendar: calendar)
    }

    private struct Fingerprint: Hashable {
        let timestampMilliseconds: Int64
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let total: Int
    }

    private static func sameProduct(billing: ToolUsageRecord, legacy: ToolUsageRecord) -> Bool {
        // The legacy endpoint also carried Grok Bot's explicitly named flows.
        // A generic Grok model name alone does not identify a Grok Chat request.
        let legacyBot = legacy.modelID?.hasPrefix("grok-bot-") == true
        return legacyBot ? billing.id.hasPrefix("cursor-billing:grok-bot:")
            : billing.id.hasPrefix("cursor-billing:cursor:")
    }

    private static func fingerprint(_ record: ToolUsageRecord) -> Fingerprint {
        // Both protocols report integer milliseconds. Foundation's ISO parser and
        // epoch initializer can differ by a fraction of a microsecond for the same value.
        Fingerprint(timestampMilliseconds: Int64((record.timestamp.timeIntervalSince1970 * 1000).rounded()), input: record.inputTokens, output: record.outputTokens,
                    cacheRead: record.cacheReadTokens, cacheWrite: record.cacheWriteTokens, total: record.totalTokens)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
