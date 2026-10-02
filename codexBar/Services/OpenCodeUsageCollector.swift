import Foundation
import SQLite3

/// Reads OpenCode's reported usage without opening message parts or transcript text.
nonisolated struct OpenCodeUsageCollector: ToolUsageCollecting {
    let client: ToolUsageClient = .openCode

    private let dataDirectory: URL
    private let databaseURL: URL

    init(dataDirectory: URL? = nil, databaseURL: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let defaultDataRoot = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        let directory = dataDirectory ?? defaultDataRoot.appendingPathComponent("opencode", isDirectory: true)
        self.dataDirectory = directory
        self.databaseURL = databaseURL
            ?? environment["OPENCODE_DB"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? directory.appendingPathComponent("opencode.db")
    }

    func collect(now: Date = Date(), calendar: Calendar = .current) -> ToolUsageSnapshot {
        let fileManager = FileManager.default
        let legacyDirectories = ["message", "session_message"].map {
            self.dataDirectory.appendingPathComponent("storage/\($0)", isDirectory: true)
        }
        let databaseExists = fileManager.fileExists(atPath: self.databaseURL.path)
        let legacyExists = legacyDirectories.contains { fileManager.fileExists(atPath: $0.path) }
        guard databaseExists || legacyExists else {
            return ToolUsageSnapshot(
                client: self.client, availability: .sourceMissing,
                refreshedAt: now, statusDetail: "未找到 OpenCode 本地数据"
            )
        }

        var messages: [String: UsageMessage] = [:]
        var databaseError = false
        var legacyError = false
        if databaseExists {
            do {
                try self.readDatabase(into: &messages, now: now)
            } catch {
                databaseError = true
            }
        }
        for directory in legacyDirectories where fileManager.fileExists(atPath: directory.path) {
            do {
                try self.readLegacyDirectory(directory, into: &messages)
            } catch {
                legacyError = true
            }
        }

        messages = messages.filter { $0.value.timestamp <= now }
        let entries = self.dailyEntries(messages.values, calendar: calendar)
        let records: [ToolUsageRecord] = messages.values.map { message in
            ToolUsageRecord(
                id: message.id.isEmpty ? message.fingerprint : message.id,
                timestamp: message.timestamp, modelID: message.modelID, sessionID: message.sessionID,
                sessionTitle: message.sessionTitle, projectPath: message.projectPath,
                sessionIsRunning: message.sessionIsRunning,
                inputTokens: message.input, outputTokens: message.output,
                cacheReadTokens: message.cacheRead, cacheWriteTokens: message.cacheWrite,
                totalTokens: message.total, costUSD: message.costUSD
            )
        }
        let usageRecords = records.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        let latestUsageAt = messages.values.map(\.timestamp).max()
        let availability: ToolUsageAvailability
        let statusDetail: String
        if !entries.isEmpty {
            let hasReadError = databaseError || legacyError
            availability = hasReadError ? .partial : .ready
            statusDetail = hasReadError ? "部分 OpenCode 数据不可读" : "已读取 OpenCode 本地用量"
        } else if databaseError || legacyError {
            availability = .failed
            statusDetail = "OpenCode 本地数据不可读"
        } else {
            availability = .noRecords
            statusDetail = "暂无 OpenCode Token 记录"
        }
        return ToolCostEstimator.reprice(ToolUsageSnapshot(
            client: self.client, availability: availability, evidence: .reported,
            dailyEntries: entries, usageRecords: usageRecords, latestUsageAt: latestUsageAt,
            refreshedAt: now, statusDetail: statusDetail
        ), calendar: calendar)
    }

    private func readDatabase(into messages: inout [String: UsageMessage], now: Date) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(self.databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ReadError.database
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        let sessionMetadata = (try? self.readSessionMetadata(in: database)) ?? [:]
        var foundMessageTable = false
        for table in ["message", "session_message"] {
            guard let columns = try self.columns(of: table, in: database) else { continue }
            foundMessageTable = true
            guard columns.contains("data") else { throw ReadError.schema }
            try self.readRows(table: table, columns: columns, database: database, sessionMetadata: sessionMetadata, into: &messages)
        }
        guard foundMessageTable else { throw ReadError.schema }
        let states = (try? self.readSessionStates(in: database, now: now)) ?? [:]
        for key in messages.keys {
            if let sessionID = messages[key]?.sessionID {
                messages[key]?.sessionIsRunning = states[sessionID]?.running
            }
        }
    }

    private struct SessionState {
        let observedAt: Date
        let running: Bool?
    }

    private func readSessionStates(in database: OpaquePointer, now: Date) throws -> [String: SessionState] {
        var states: [String: SessionState] = [:]
        for table in ["message", "session_message"] {
            guard let columns = try self.columns(of: table, in: database), columns.contains("data") else { continue }
            let session = columns.contains("session_id") ? "session_id" : "json_extract(data, '$.sessionID')"
            let created = columns.contains("time_created") ? "time_created" : "NULL"
            let sql = """
                SELECT \(session), COALESCE(json_extract(data, '$.time.created'), \(created)),
                       json_extract(data, '$.role'), json_extract(data, '$.finish')
                FROM \(table) WHERE json_valid(data)
                """
            let statement = try self.prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw ReadError.database }
                let sessionID = Self.text(at: 0, in: statement)
                guard !sessionID.isEmpty, let time = Self.date(from: Self.number(at: 1, in: statement)), time <= now,
                      states[sessionID].map({ time >= $0.observedAt }) ?? true else { continue }
                let role = Self.text(at: 2, in: statement)
                let finish = Self.text(at: 3, in: statement)
                let running: Bool? = role == "user" ? true : role == "assistant" && !finish.isEmpty ? finish == "tool-calls" : nil
                states[sessionID] = SessionState(observedAt: time, running: running)
            }
        }
        return states
    }

    private struct SessionMetadata {
        let title: String?
        let directory: String?
    }

    private func readSessionMetadata(in database: OpaquePointer) throws -> [String: SessionMetadata] {
        guard let columns = try self.columns(of: "session", in: database), columns.contains("id") else { return [:] }
        let title = columns.contains("title") ? "title" : "NULL"
        let directory = columns.contains("directory") ? "directory" : "NULL"
        let statement = try self.prepare("SELECT id, \(title), \(directory) FROM session", in: database)
        defer { sqlite3_finalize(statement) }
        var result: [String: SessionMetadata] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError.database }
            let title = Self.text(at: 1, in: statement)
            let directory = Self.text(at: 2, in: statement)
            result[Self.text(at: 0, in: statement)] = SessionMetadata(
                title: title.isEmpty ? nil : title, directory: directory.isEmpty ? nil : directory
            )
        }
        return result
    }

    private func columns(of table: String, in database: OpaquePointer) throws -> Set<String>? {
        // `table` is one of two fixed names, never supplied by a database record.
        let statement = try self.prepare("PRAGMA table_info(\(table))", in: database)
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ReadError.database }
            if let pointer = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: pointer))
            }
        }
        return columns.isEmpty ? nil : columns
    }

    private func readRows(
        table: String,
        columns: Set<String>,
        database: OpaquePointer,
        sessionMetadata: [String: SessionMetadata],
        into messages: inout [String: UsageMessage]
    ) throws {
        let id = columns.contains("id") ? "id" : "json_extract(data, '$.id')"
        let session = columns.contains("session_id") ? "session_id" : "json_extract(data, '$.sessionID')"
        let created = columns.contains("time_created") ? "time_created"
            : columns.contains("created_at") ? "created_at" : "NULL"
        let updated = columns.contains("time_updated") ? "time_updated"
            : columns.contains("updated_at") ? "updated_at" : "NULL"
        let sql = """
            SELECT \(id), \(session), \(created), \(updated),
                   json_extract(data, '$.tokens.input'),
                   json_extract(data, '$.tokens.output'),
                   json_extract(data, '$.tokens.reasoning'),
                   json_extract(data, '$.tokens.cache.read'),
                   json_extract(data, '$.tokens.cache.write'),
                   json_extract(data, '$.tokens.total'),
                   json_extract(data, '$.cost'),
                   json_extract(data, '$.time.created'),
                   json_extract(data, '$.time.completed'),
                   json_extract(data, '$.modelID'),
                   json_extract(data, '$.path.cwd')
            FROM \(table)
            WHERE json_valid(data)
              AND json_extract(data, '$.role') = 'assistant'
              AND json_type(data, '$.tokens') = 'object'
            """
        let statement = try self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ReadError.database }
            let identifier = Self.text(at: 0, in: statement)
            let sessionID = Self.text(at: 1, in: statement)
            let createdAt = Self.number(at: 2, in: statement)
            let updatedAt = Self.number(at: 3, in: statement)
            let timeCreated = Self.number(at: 11, in: statement)
            let timeCompleted = Self.number(at: 12, in: statement)
            guard let timestamp = Self.date(from: timeCompleted)
                ?? Self.date(from: timeCreated)
                ?? Self.date(from: createdAt) else { continue }
            let usage = UsageMessage(
                id: identifier, sessionID: sessionID, timestamp: timestamp,
                updatedAt: Self.date(from: updatedAt) ?? timestamp,
                input: Self.token(at: 4, in: statement),
                rawOutput: Self.token(at: 5, in: statement),
                reasoning: Self.token(at: 6, in: statement),
                cacheRead: Self.token(at: 7, in: statement),
                cacheWrite: Self.token(at: 8, in: statement),
                reportedTotal: Self.token(at: 9, in: statement),
                costUSD: Self.number(at: 10, in: statement),
                modelID: Self.text(at: 13, in: statement),
                sessionTitle: sessionMetadata[sessionID]?.title,
                projectPath: sessionMetadata[sessionID]?.directory ?? Self.text(at: 14, in: statement)
            )
            Self.offer(usage, into: &messages)
        }
    }

    private func readLegacyDirectory(_ directory: URL, into messages: inout [String: UsageMessage]) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw ReadError.legacy }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["role"] as? String == "assistant",
                  let tokens = object["tokens"] as? [String: Any] else { continue }
            let times = object["time"] as? [String: Any] ?? [:]
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            guard let timestamp = Self.date(from: Self.number(times["completed"]))
                ?? Self.date(from: Self.number(times["created"]))
                ?? Self.date(from: Self.number(object["time_created"])) else { continue }
            let usage = UsageMessage(
                id: object["id"] as? String ?? url.deletingPathExtension().lastPathComponent,
                sessionID: object["sessionID"] as? String ?? url.deletingLastPathComponent().lastPathComponent,
                timestamp: timestamp,
                updatedAt: Self.date(from: Self.number(object["time_updated"])) ?? timestamp,
                input: Self.integer(tokens["input"]),
                rawOutput: Self.integer(tokens["output"]),
                reasoning: Self.integer(tokens["reasoning"]),
                cacheRead: Self.integer(cache["read"]),
                cacheWrite: Self.integer(cache["write"]),
                reportedTotal: Self.integer(tokens["total"]),
                costUSD: Self.number(object["cost"]),
                modelID: object["modelID"] as? String,
                sessionTitle: object["title"] as? String,
                projectPath: (object["path"] as? [String: Any])?["cwd"] as? String
            )
            Self.offer(usage, into: &messages)
        }
    }

    private func dailyEntries(_ messages: Dictionary<String, UsageMessage>.Values, calendar: Calendar) -> [ToolUsageDailyEntry] {
        struct Bucket {
            var input = 0
            var output = 0
            var cacheRead = 0
            var cacheWrite = 0
            var total = 0
            var cost = 0.0
            var allCostsReported = true
        }
        var buckets: [Date: Bucket] = [:]
        for message in messages {
            let day = calendar.startOfDay(for: message.timestamp)
            var bucket = buckets[day, default: Bucket()]
            bucket.input = Self.add(bucket.input, message.input)
            bucket.output = Self.add(bucket.output, message.output)
            bucket.cacheRead = Self.add(bucket.cacheRead, message.cacheRead)
            bucket.cacheWrite = Self.add(bucket.cacheWrite, message.cacheWrite)
            bucket.total = Self.add(bucket.total, message.total)
            if let cost = message.costUSD {
                bucket.cost += cost
            } else {
                bucket.allCostsReported = false
            }
            buckets[day] = bucket
        }
        return buckets.keys.sorted().compactMap { day in
            guard let bucket = buckets[day] else { return nil }
            return ToolUsageDailyEntry(
                date: day, inputTokens: bucket.input, outputTokens: bucket.output,
                cacheReadTokens: bucket.cacheRead, cacheWriteTokens: bucket.cacheWrite,
                totalTokens: bucket.total,
                costUSD: bucket.allCostsReported && bucket.cost.isFinite ? bucket.cost : nil
            )
        }
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ReadError.database }
        return statement
    }

    private static func offer(_ message: UsageMessage, into messages: inout [String: UsageMessage]) {
        guard message.total > 0 else { return }
        let key = message.id.isEmpty ? message.fingerprint : "id:\(message.id)"
        if let previous = messages[key], previous.updatedAt > message.updatedAt { return }
        messages[key] = message
    }

    private static func text(at index: Int32, in statement: OpaquePointer) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private static func number(at index: Int32, in statement: OpaquePointer) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let result = sqlite3_column_double(statement, index)
        return result.isFinite ? result : nil
    }

    private static func token(at index: Int32, in statement: OpaquePointer) -> Int? {
        self.integer(self.number(at: index, in: statement))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let string = value as? String, let number = Double(string), number.isFinite { return number }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = self.number(value) else { return nil }
        return Int(exactly: number)
    }

    private static func date(from timestamp: Double?) -> Date? {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp)
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private enum ReadError: Error {
        case database
        case schema
        case legacy
    }

    private struct UsageMessage {
        let id: String
        let sessionID: String
        let timestamp: Date
        let updatedAt: Date
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let total: Int
        let costUSD: Double?
        let modelID: String?
        let sessionTitle: String?
        let projectPath: String?
        var sessionIsRunning: Bool? = nil

        init(
            id: String, sessionID: String, timestamp: Date, updatedAt: Date,
            input: Int?, rawOutput: Int?, reasoning: Int?, cacheRead: Int?, cacheWrite: Int?,
            reportedTotal: Int?, costUSD: Double?, modelID: String? = nil,
            sessionTitle: String? = nil, projectPath: String? = nil
        ) {
            self.id = id
            self.modelID = modelID
            self.sessionTitle = sessionTitle
            self.projectPath = projectPath
            self.sessionID = sessionID
            self.timestamp = timestamp
            self.updatedAt = updatedAt
            self.input = max(0, input ?? 0)
            // OpenCode reports reasoning separately from output. Combining them
            // keeps the public output bucket aligned with its reported total.
            self.output = max(0, OpenCodeUsageCollector.add(rawOutput ?? 0, reasoning ?? 0))
            self.cacheRead = max(0, cacheRead ?? 0)
            self.cacheWrite = max(0, cacheWrite ?? 0)
            let calculated = OpenCodeUsageCollector.add(
                OpenCodeUsageCollector.add(self.input, self.output),
                OpenCodeUsageCollector.add(self.cacheRead, self.cacheWrite)
            )
            self.total = reportedTotal.flatMap { $0 > 0 ? $0 : nil } ?? calculated
            self.costUSD = costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }

        var fingerprint: String {
            "fingerprint:\(self.sessionID)|\(self.timestamp.timeIntervalSince1970)|\(self.input)|\(self.output)|\(self.cacheRead)|\(self.cacheWrite)|\(self.total)|\(self.costUSD ?? -1)"
        }
    }
}
