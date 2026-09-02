import Foundation
import SQLite3

private let localCostSQLiteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LocalCostIndexScanState: String, Codable, Equatable {
    case idle
    case scanning
    case partial
    case failed
}

struct LocalCostIndexProgress: Codable, Equatable {
    var state: LocalCostIndexScanState
    var processedBytes: Int64
    var totalBytes: Int64
    var completedFiles: Int
    var totalFiles: Int
    var lastSuccessfulScanAt: Date?
    var latestUsageEventAt: Date?
    var errorMessage: String?

    static let idle = LocalCostIndexProgress(
        state: .idle,
        processedBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0,
        lastSuccessfulScanAt: nil,
        latestUsageEventAt: nil,
        errorMessage: nil
    )

    var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(processedBytes) / Double(totalBytes)))
    }
}

struct LocalCostIndexedFile: Equatable {
    let path: String
    let fileIdentifier: String
    let size: Int64
    let modificationTime: Date
    let parsedBytes: Int64
    let anchorHash: String
    let parserStateData: Data
    let isComplete: Bool
}

struct LocalCostIndexedEvent: Codable, Equatable, Sendable {
    let eventKey: String
    let path: String
    let sessionID: String
    let timestamp: Date
    let model: String
    let turnID: String?
    let serviceTier: SessionLogStore.ServiceTier
    let source: SessionLogStore.EventSource
    let usage: SessionLogStore.Usage
}

struct LocalCostFileScanCommit {
    let path: String
    let fileIdentifier: String
    let size: Int64
    let modificationTime: Date
    let parsedBytes: Int64
    let anchorHash: String
    let parserStateData: Data
    let isComplete: Bool
    let replaceExistingEvents: Bool
    let events: [LocalCostIndexedEvent]
}

struct LocalCostIndexedSummary {
    let summary: LocalCostSummary
    let progress: LocalCostIndexProgress
    let isUsable: Bool
}

final class LocalCostIndexStore: @unchecked Sendable {
    enum StoreError: Error {
        case openFailed(String)
        case executeFailed(String)
        case prepareFailed(String)
        case bindFailed(String)
        case stepFailed(String)
        case invalidTextColumn
    }

    static let currentSchemaVersion = 1

    private let databaseURL: URL
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "lzl.codexbar.local-cost-index", qos: .utility)
    private var database: OpaquePointer?

    init(databaseURL: URL, calendar: Calendar = .current) throws {
        self.databaseURL = databaseURL
        self.calendar = calendar
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try self.open()
        try self.migrate()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func indexedFile(path: String) throws -> LocalCostIndexedFile? {
        try self.queue.sync {
            let statement = try self.prepare(
                """
                SELECT path, file_identifier, size, mtime, parsed_bytes, anchor_hash, parser_state, is_complete
                FROM files WHERE path = ?1
                """
            )
            defer { sqlite3_finalize(statement) }
            try self.bind(path, to: statement, at: 1)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try self.file(from: statement)
        }
    }

    func commitFileScan(_ commit: LocalCostFileScanCommit) throws {
        try self.queue.sync {
            try self.execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                if commit.replaceExistingEvents {
                    let deleteEvents = try self.prepare("DELETE FROM events WHERE path = ?1")
                    defer { sqlite3_finalize(deleteEvents) }
                    try self.bind(commit.path, to: deleteEvents, at: 1)
                    try self.stepDone(deleteEvents)
                }

                let upsertFile = try self.prepare(
                    """
                    INSERT INTO files (
                        path, file_identifier, size, mtime, parsed_bytes, anchor_hash,
                        parser_state, is_complete, last_scanned_at
                    )
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                    ON CONFLICT(path) DO UPDATE SET
                        file_identifier = excluded.file_identifier,
                        size = excluded.size,
                        mtime = excluded.mtime,
                        parsed_bytes = excluded.parsed_bytes,
                        anchor_hash = excluded.anchor_hash,
                        parser_state = excluded.parser_state,
                        is_complete = excluded.is_complete,
                        last_scanned_at = excluded.last_scanned_at
                    """
                )
                defer { sqlite3_finalize(upsertFile) }
                try self.bind(commit.path, to: upsertFile, at: 1)
                try self.bind(commit.fileIdentifier, to: upsertFile, at: 2)
                try self.bind(commit.size, to: upsertFile, at: 3)
                try self.bind(commit.modificationTime.timeIntervalSince1970, to: upsertFile, at: 4)
                try self.bind(commit.parsedBytes, to: upsertFile, at: 5)
                try self.bind(commit.anchorHash, to: upsertFile, at: 6)
                try self.bind(commit.parserStateData, to: upsertFile, at: 7)
                try self.bind(commit.isComplete ? 1 : 0, to: upsertFile, at: 8)
                try self.bind(Date().timeIntervalSince1970, to: upsertFile, at: 9)
                try self.stepDone(upsertFile)

                let insertEvent = try self.prepare(
                    """
                    INSERT OR IGNORE INTO events (
                        event_key, path, session_id, timestamp, day, model, turn_id, service_tier,
                        source, input_tokens, cached_input_tokens, output_tokens, rate_class
                    )
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                    """
                )
                defer { sqlite3_finalize(insertEvent) }

                for event in commit.events {
                    try self.reset(insertEvent)
                    try self.bind(event.eventKey, to: insertEvent, at: 1)
                    try self.bind(event.path, to: insertEvent, at: 2)
                    try self.bind(event.sessionID, to: insertEvent, at: 3)
                    try self.bind(event.timestamp.timeIntervalSince1970, to: insertEvent, at: 4)
                    try self.bind(self.dayKey(for: event.timestamp), to: insertEvent, at: 5)
                    try self.bind(event.model, to: insertEvent, at: 6)
                    try self.bind(event.turnID, to: insertEvent, at: 7)
                    try self.bind(event.serviceTier.rawValue, to: insertEvent, at: 8)
                    try self.bind(event.source.rawValue, to: insertEvent, at: 9)
                    try self.bind(Int64(event.usage.inputTokens), to: insertEvent, at: 10)
                    try self.bind(Int64(event.usage.cachedInputTokens), to: insertEvent, at: 11)
                    try self.bind(Int64(event.usage.outputTokens), to: insertEvent, at: 12)
                    try self.bind(
                        self.rateClass(
                            model: event.model,
                            usage: event.usage,
                            serviceTier: event.serviceTier
                        ),
                        to: insertEvent,
                        at: 13
                    )
                    try self.stepDone(insertEvent)
                }

                let deleteFileAggregate = try self.prepare(
                    "DELETE FROM file_day_aggregates WHERE path = ?1"
                )
                defer { sqlite3_finalize(deleteFileAggregate) }
                try self.bind(commit.path, to: deleteFileAggregate, at: 1)
                try self.stepDone(deleteFileAggregate)

                let rebuildFileAggregate = try self.prepare(
                    """
                    INSERT INTO file_day_aggregates (
                        path, day, model, service_tier, source, rate_class,
                        input_tokens, cached_input_tokens, output_tokens
                    )
                    SELECT path, day, model, service_tier, source, rate_class,
                           SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens)
                    FROM events
                    WHERE path = ?1
                    GROUP BY path, day, model, service_tier, source, rate_class
                    """
                )
                defer { sqlite3_finalize(rebuildFileAggregate) }
                try self.bind(commit.path, to: rebuildFileAggregate, at: 1)
                try self.stepDone(rebuildFileAggregate)

                try self.execute("COMMIT")
            } catch {
                try? self.execute("ROLLBACK")
                throw error
            }
        }
    }

    func rebuildAggregates() throws {
        try self.queue.sync {
            try self.execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try self.rebuildAggregatesLocked()
                try self.execute("COMMIT")
            } catch {
                try? self.execute("ROLLBACK")
                throw error
            }
        }
    }

    func updateProgress(_ progress: LocalCostIndexProgress) throws {
        try self.queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(progress)
            let statement = try self.prepare(
                """
                INSERT INTO scan_metadata(key, value) VALUES ('progress', ?1)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """
            )
            defer { sqlite3_finalize(statement) }
            try self.bind(String(data: data, encoding: .utf8) ?? "{}", to: statement, at: 1)
            try self.stepDone(statement)
        }
    }

    func progress() throws -> LocalCostIndexProgress {
        try self.queue.sync {
            let statement = try self.prepare("SELECT value FROM scan_metadata WHERE key = 'progress'")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = try self.optionalString(statement, column: 0),
                  let data = value.data(using: .utf8) else {
                return .idle
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(LocalCostIndexProgress.self, from: data)) ?? .idle
        }
    }

    func summary(
        now: Date = Date(),
        modelPricingOverrides: [String: CodexBarModelPricing] = [:]
    ) throws -> LocalCostIndexedSummary {
        try self.queue.sync {
            let todayStart = self.calendar.startOfDay(for: now)
            let last30Start = self.calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
            var accumulator = LocalCostSummaryAccumulator()

            let statement = try self.prepare(
                """
                SELECT day, model, service_tier,
                       SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens), rate_class
                FROM file_day_aggregates
                GROUP BY day, model, service_tier, rate_class
                ORDER BY day DESC
                """
            )
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                let day = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
                let model = try self.requiredString(statement, column: 1)
                let tier = SessionLogStore.ServiceTier.parse(try self.optionalString(statement, column: 2))
                let usage = SessionLogStore.Usage(
                    inputTokens: Int(sqlite3_column_int64(statement, 3)),
                    cachedInputTokens: Int(sqlite3_column_int64(statement, 4)),
                    outputTokens: Int(sqlite3_column_int64(statement, 5))
                )
                let rateClass = try self.requiredString(statement, column: 6)
                let cost = LocalCostPricing.costUSD(
                    model: model,
                    usage: usage,
                    serviceTier: tier,
                    customPricingByModel: modelPricingOverrides,
                    forceLongContextPremium: rateClass == "long_context",
                    forcePriorityPricing: rateClass == "priority"
                )

                accumulator.lifetimeCost += cost
                accumulator.lifetimeTokens += usage.totalTokens
                if day >= last30Start {
                    accumulator.last30Cost += cost
                    accumulator.last30Tokens += usage.totalTokens
                }
                if day >= todayStart {
                    accumulator.todayCost += cost
                    accumulator.todayTokens += usage.totalTokens
                }
                let current = accumulator.daily[day] ?? (0, 0)
                accumulator.daily[day] = (current.cost + cost, current.tokens + usage.totalTokens)
            }

            let progress = try self.progressLocked()
            let entries = accumulator.daily.map { day, value in
                DailyCostEntry(
                    id: ISO8601DateFormatter().string(from: day),
                    date: day,
                    costUSD: value.cost,
                    totalTokens: value.tokens
                )
            }.sorted { $0.date > $1.date }

            let summary = LocalCostSummary(
                todayCostUSD: accumulator.todayCost,
                todayTokens: accumulator.todayTokens,
                last30DaysCostUSD: accumulator.last30Cost,
                last30DaysTokens: accumulator.last30Tokens,
                lifetimeCostUSD: accumulator.lifetimeCost,
                lifetimeTokens: accumulator.lifetimeTokens,
                dailyEntries: entries,
                updatedAt: progress.lastSuccessfulScanAt ?? now
            )
            return LocalCostIndexedSummary(
                summary: summary,
                progress: progress,
                isUsable: accumulator.lifetimeTokens > 0 || progress.lastSuccessfulScanAt != nil
            )
        }
    }

    private struct LocalCostSummaryAccumulator {
        var todayCost = 0.0
        var last30Cost = 0.0
        var lifetimeCost = 0.0
        var todayTokens = 0
        var last30Tokens = 0
        var lifetimeTokens = 0
        var daily: [Date: (cost: Double, tokens: Int)] = [:]
    }

    private func open() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(self.databaseURL.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open sqlite database"
            if let handle {
                sqlite3_close(handle)
            }
            throw StoreError.openFailed(message)
        }
        guard sqlite3_busy_timeout(handle, 2_000) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw StoreError.openFailed(message)
        }
        self.database = handle
    }

    private func migrate() throws {
        try self.queue.sync {
            try self.execute("PRAGMA journal_mode=WAL")
            try self.execute("PRAGMA synchronous=NORMAL")
            let existingVersion = try self.integerScalar("PRAGMA user_version")
            if existingVersion != 0, existingVersion != Self.currentSchemaVersion {
                // This database is derived exclusively from read-only session logs.
                // Rebuild incompatible schemas in place while the JSON summary remains
                // available as the user-facing last-known-good fallback.
                try self.execute("DROP TABLE IF EXISTS day_aggregates")
                try self.execute("DROP TABLE IF EXISTS file_day_aggregates")
                try self.execute("DROP TABLE IF EXISTS events")
                try self.execute("DROP TABLE IF EXISTS files")
                try self.execute("DROP TABLE IF EXISTS scan_metadata")
            }
            try self.execute(
                """
                CREATE TABLE IF NOT EXISTS files (
                    path TEXT PRIMARY KEY NOT NULL,
                    file_identifier TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    parsed_bytes INTEGER NOT NULL,
                    anchor_hash TEXT NOT NULL,
                    parser_state BLOB NOT NULL,
                    is_complete INTEGER NOT NULL,
                    last_scanned_at REAL NOT NULL
                )
                """
            )
            try self.execute(
                """
                CREATE TABLE IF NOT EXISTS events (
                    event_key TEXT PRIMARY KEY NOT NULL,
                    path TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    day INTEGER NOT NULL,
                    model TEXT NOT NULL,
                    turn_id TEXT,
                    service_tier TEXT NOT NULL,
                    source TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    rate_class TEXT NOT NULL
                )
                """
            )
            try self.execute("CREATE INDEX IF NOT EXISTS events_day_idx ON events(day)")
            try self.execute("CREATE INDEX IF NOT EXISTS events_path_idx ON events(path)")
            try self.execute(
                """
                CREATE TABLE IF NOT EXISTS file_day_aggregates (
                    path TEXT NOT NULL,
                    day INTEGER NOT NULL,
                    model TEXT NOT NULL,
                    service_tier TEXT NOT NULL,
                    source TEXT NOT NULL,
                    rate_class TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    PRIMARY KEY(path, day, model, service_tier, source, rate_class)
                )
                """
            )
            try self.execute(
                """
                CREATE TABLE IF NOT EXISTS day_aggregates (
                    day INTEGER NOT NULL,
                    model TEXT NOT NULL,
                    service_tier TEXT NOT NULL,
                    source TEXT NOT NULL,
                    rate_class TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    PRIMARY KEY(day, model, service_tier, source, rate_class)
                )
                """
            )
            try self.execute(
                """
                CREATE TABLE IF NOT EXISTS scan_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                )
                """
            )
            try self.execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
        }
    }

    private func rebuildAggregatesLocked() throws {
        try self.execute("DELETE FROM file_day_aggregates")
        try self.execute(
            """
            INSERT INTO file_day_aggregates (
                path, day, model, service_tier, source, rate_class,
                input_tokens, cached_input_tokens, output_tokens
            )
            SELECT path, day, model, service_tier, source, rate_class,
                   SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens)
            FROM events
            GROUP BY path, day, model, service_tier, source, rate_class
            """
        )
        try self.execute("DELETE FROM day_aggregates")
        try self.execute(
            """
            INSERT INTO day_aggregates (
                day, model, service_tier, source, rate_class,
                input_tokens, cached_input_tokens, output_tokens
            )
            SELECT day, model, service_tier, source, rate_class,
                   SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens)
            FROM events
            GROUP BY day, model, service_tier, source, rate_class
            """
        )
    }

    private func progressLocked() throws -> LocalCostIndexProgress {
        let statement = try self.prepare("SELECT value FROM scan_metadata WHERE key = 'progress'")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = try self.optionalString(statement, column: 0),
              let data = value.data(using: .utf8) else {
            return .idle
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LocalCostIndexProgress.self, from: data)) ?? .idle
    }

    private func file(from statement: OpaquePointer?) throws -> LocalCostIndexedFile {
        LocalCostIndexedFile(
            path: try self.requiredString(statement, column: 0),
            fileIdentifier: try self.requiredString(statement, column: 1),
            size: sqlite3_column_int64(statement, 2),
            modificationTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            parsedBytes: sqlite3_column_int64(statement, 4),
            anchorHash: try self.requiredString(statement, column: 5),
            parserStateData: Data(
                bytes: sqlite3_column_blob(statement, 6),
                count: Int(sqlite3_column_bytes(statement, 6))
            ),
            isComplete: sqlite3_column_int(statement, 7) != 0
        )
    }

    private func dayKey(for date: Date) -> Int64 {
        Int64(self.calendar.startOfDay(for: date).timeIntervalSince1970)
    }

    private func rateClass(
        model: String,
        usage: SessionLogStore.Usage,
        serviceTier: SessionLogStore.ServiceTier
    ) -> String {
        if LocalCostPricing.usesPriorityPricing(
            model: model,
            serviceTier: serviceTier,
            usage: usage
        ) {
            return "priority"
        }
        return LocalCostPricing.usesLongContextPremium(model: model, usage: usage)
            ? "long_context"
            : "standard"
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw StoreError.executeFailed("database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw StoreError.executeFailed(message)
        }
    }

    private func integerScalar(_ sql: String) throws -> Int {
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.stepFailed(self.lastErrorMessage())
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let database else { throw StoreError.prepareFailed("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func reset(_ statement: OpaquePointer?) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw StoreError.stepFailed("unable to reset sqlite statement")
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.stepFailed(self.lastErrorMessage())
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, localCostSQLiteTransientDestructor)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw StoreError.bindFailed(self.lastErrorMessage()) }
    }

    private func bind(_ value: Int64, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw StoreError.bindFailed(self.lastErrorMessage())
        }
    }

    private func bind(_ value: Int, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
            throw StoreError.bindFailed(self.lastErrorMessage())
        }
    }

    private func bind(_ value: TimeInterval, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw StoreError.bindFailed(self.lastErrorMessage())
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) throws {
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), localCostSQLiteTransientDestructor)
        }
        guard result == SQLITE_OK else { throw StoreError.bindFailed(self.lastErrorMessage()) }
    }

    private func optionalString(_ statement: OpaquePointer?, column: Int32) throws -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let pointer = sqlite3_column_text(statement, column) else {
            throw StoreError.invalidTextColumn
        }
        return String(cString: pointer)
    }

    private func requiredString(_ statement: OpaquePointer?, column: Int32) throws -> String {
        guard let value = try self.optionalString(statement, column: column) else {
            throw StoreError.invalidTextColumn
        }
        return value
    }

    private func lastErrorMessage() -> String {
        guard let database else { return "database is closed" }
        return String(cString: sqlite3_errmsg(database))
    }
}
