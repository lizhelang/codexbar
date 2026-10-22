import CoreFoundation
import Foundation
import SQLite3

/// Reads reported generation counters from Antigravity's own transcript export.
/// Quota percentages and transcript content are never used to estimate tokens.
nonisolated struct AntigravityUsageCollector: ToolUsageCollecting {
    let client: ToolUsageClient = .antigravity
    let dataDirectories: [URL]
    // Transcript exports and conversation databases are re-read only when they change on disk.
    private static let parsedTranscripts = FileParseCache<Parsed>()
    private static let databaseGenerations = FileParseCache<(wal: FileStamp?, generations: [AntigravityMetadataReader.Generation])>()
    nonisolated var watchedPaths: [URL] { self.dataDirectories }

    init(dataDirectory: URL? = nil) {
        if let dataDirectory {
            self.dataDirectories = [dataDirectory]
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.dataDirectories = ["antigravity", "antigravity-ide"].map {
                home.appendingPathComponent(".gemini").appendingPathComponent($0, isDirectory: true)
            }
        }
    }

    init(dataDirectories: [URL]) {
        self.dataDirectories = dataDirectories
    }

    func collect(now: Date = Date(), calendar: Calendar = .current) -> ToolUsageSnapshot {
        var foundRoot = false
        var sessions = Set<String>()
        var exportedSessions = Set<String>()
        var failures = 0
        var malformed = 0
        var missingUsage = 0
        var unreportedEvents = Set<String>()
        var candidates: [Candidate] = []
        var databases: [URL] = []
        for root in self.dataDirectories {
            guard Self.isDirectory(root) else { continue }
            foundRoot = true
            do {
                let conversations = root.appendingPathComponent("conversations", isDirectory: true)
                if Self.isDirectory(conversations) {
                    for file in try FileManager.default.contentsOfDirectory(
                        at: conversations, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                    ) where ["db", "pb"].contains(file.pathExtension) && Self.isRegularFile(file) {
                        sessions.insert(file.deletingPathExtension().lastPathComponent)
                        if file.pathExtension == "db" { databases.append(file) }
                    }
                }
                let brain = root.appendingPathComponent("brain", isDirectory: true)
                guard Self.isDirectory(brain) else { continue }
                let folders = try FileManager.default.contentsOfDirectory(
                    at: brain, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                for folder in folders where Self.isDirectory(folder) {
                    let sessionID = folder.lastPathComponent
                    let logs = folder.appendingPathComponent(".system_generated/logs", isDirectory: true)
                    let full = logs.appendingPathComponent("transcript_full.jsonl")
                    let compact = logs.appendingPathComponent("transcript.jsonl")
                    // These exports repeat the same event counters. Chunks may be obsolete or
                    // incomplete; use the complete export and never sum all copies together.
                    guard let file = [full, compact].first(where: Self.isRegularFile) else { continue }
                    sessions.insert(sessionID)
                    candidates.append(Candidate(
                        file: file, sessionID: sessionID,
                        modifiedAt: (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    ))
                }
            } catch {
                failures += 1
            }
        }
        guard foundRoot else {
            return ToolUsageSnapshot(client: self.client, availability: .sourceMissing, refreshedAt: now,
                                     statusDetail: "未找到 Antigravity 本地会话目录")
        }

        var records: [String: ToolUsageRecord] = [:]
        // Later snapshots of an identical event replace earlier copies, including mirrored
        // antigravity / antigravity-ide roots. Regenerated steps at different times remain distinct.
        for candidate in candidates.sorted(by: {
            $0.modifiedAt == $1.modifiedAt ? $0.file.path < $1.file.path : $0.modifiedAt < $1.modifiedAt
        }) {
            do {
                let path = candidate.file.standardizedFileURL.path
                let stamp = FileStamp.of(path: path)
                let parsed: Parsed
                if let stamp, let cached = Self.parsedTranscripts.value(for: path, stamp: stamp),
                   cached.earliestSkippedFutureAt.map({ $0 > now }) ?? true {
                    parsed = cached
                } else {
                    let size = try candidate.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 64 * 1024 * 1024 else { throw ReadError.tooLarge }
                    let data = try Data(contentsOf: candidate.file, options: .mappedIfSafe)
                    guard data.count <= 64 * 1024 * 1024 else { throw ReadError.tooLarge }
                    parsed = Self.parse(data, sessionID: candidate.sessionID, now: now)
                    if let stamp { Self.parsedTranscripts.store(parsed, for: path, stamp: stamp) }
                }
                malformed += parsed.malformed
                unreportedEvents.formUnion(parsed.unreportedEvents)
                if parsed.malformed == 0 && parsed.unreportedEvents.isEmpty {
                    exportedSessions.insert(candidate.sessionID)
                }
                for record in parsed.records {
                    records[record.id] = record
                    exportedSessions.insert(candidate.sessionID)
                }
            } catch {
                failures += 1
            }
        }

        var orderedDatabases: [(file: URL, modifiedAt: Date)] = []
        for file in databases {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            let wal = try? URL(fileURLWithPath: file.path + "-wal").resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = max(values?.contentModificationDate ?? .distantPast,
                                 wal?.contentModificationDate ?? .distantPast)
            orderedDatabases.append((file, modifiedAt))
        }
        orderedDatabases.sort {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return $0.file.path < $1.file.path
        }
        for (database, _) in orderedDatabases {
            let sessionID = database.deletingPathExtension().lastPathComponent
            do {
                let generations = try Self.generations(in: database)
                exportedSessions.insert(sessionID)
                for generation in generations {
                    if generation.timestamp == nil,
                       generation.input == 0, generation.output == 0,
                       generation.cacheRead == 0, generation.cacheWrite == 0 { continue }
                    guard let timestamp = generation.timestamp else { missingUsage += 1; continue }
                    guard timestamp <= now else { continue }
                    let uncached = generation.input.addingReportingOverflow(generation.output)
                    let cached = generation.cacheRead.addingReportingOverflow(generation.cacheWrite)
                    let combined = uncached.partialValue.addingReportingOverflow(cached.partialValue)
                    guard !uncached.overflow, !cached.overflow, !combined.overflow else { malformed += 1; continue }
                    // One generation can own many steps. The DB is read after the export and
                    // may hold newer streaming counters for the same event. Replaced attempts
                    // have different creation times and remain in the JSONL history.
                    for (step, createdAt) in generation.steps {
                        let identity = Self.eventID(
                            sessionID: sessionID, step: step,
                            timestamp: Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
                        )
                        unreportedEvents.remove(identity)
                        records.removeValue(forKey: identity)
                    }
                    let identity = "antigravity:\(sessionID):generation:\(generation.index):\(timestamp.timeIntervalSince1970)"
                    records[identity] = ToolUsageRecord(
                        id: identity, timestamp: timestamp, modelID: generation.model, sessionID: sessionID,
                        inputTokens: generation.input, outputTokens: generation.output,
                        cacheReadTokens: generation.cacheRead, cacheWriteTokens: generation.cacheWrite,
                        totalTokens: combined.partialValue
                    )
                    exportedSessions.insert(sessionID)
                }
            } catch {
                failures += 1
            }
        }

        Self.parsedTranscripts.retainOnly(Set(candidates.map(\.file.standardizedFileURL.path)), under: self.dataDirectories)
        Self.databaseGenerations.retainOnly(Set(databases.map(\.standardizedFileURL.path)), under: self.dataDirectories)

        missingUsage += unreportedEvents.count
        let sortedRecords = records.values.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
        var daily: [Date: Totals] = [:]
        for record in sortedRecords {
            let day = calendar.startOfDay(for: record.timestamp)
            var totals = daily[day, default: Totals()]
            if !totals.add(record) { malformed += 1 }
            daily[day] = totals
        }
        let entries = daily.keys.sorted().map { day in
            let total = daily[day]!
            return ToolUsageDailyEntry(date: day, inputTokens: total.input, outputTokens: total.output,
                                      cacheReadTokens: total.cacheRead, cacheWriteTokens: total.cacheWrite,
                                      totalTokens: total.total)
        }
        let unavailableSessions = sessions.subtracting(exportedSessions).count
        let incomplete = failures > 0 || malformed > 0 || missingUsage > 0 || unavailableSessions > 0
        let availability: ToolUsageAvailability
        if failures > 0 && sortedRecords.isEmpty {
            availability = .failed
        } else if sortedRecords.isEmpty {
            availability = malformed > 0 || missingUsage > 0 || unavailableSessions > 0 ? .failed : .noRecords
        } else {
            availability = incomplete ? .partial : .ready
        }
        var details = ["本地记录 \(sortedRecords.count) 次生成；包含缓存读取"]
        if unavailableSessions > 0 { details.append("\(unavailableSessions) 个会话尚无可读取的 Token 记录") }
        if missingUsage > 0 { details.append("\(missingUsage) 条模型事件未记录完整 Token 计数") }
        if malformed > 0 { details.append("跳过 \(malformed) 条损坏记录") }
        if failures > 0 { details.append("\(failures) 个来源无法读取") }
        if sessions.isEmpty { details = ["尚无 Antigravity 会话记录"] }
        return ToolCostEstimator.reprice(ToolUsageSnapshot(
            client: self.client, availability: availability, evidence: .reported,
            dailyEntries: entries, usageRecords: sortedRecords,
            latestUsageAt: sortedRecords.last?.timestamp, refreshedAt: now,
            statusDetail: details.joined(separator: "；")
        ), calendar: calendar)
    }

    /// SQLite commits land in the `-wal` file first, so the database file's own stamp is not enough.
    private static func generations(in database: URL) throws -> [AntigravityMetadataReader.Generation] {
        let path = database.standardizedFileURL.path
        let wal = FileStamp.of(path: path + "-wal")
        guard let stamp = FileStamp.of(path: path) else { return try AntigravityMetadataReader.read(database) }
        if let cached = self.databaseGenerations.value(for: path, stamp: stamp), cached.wal == wal {
            return cached.generations
        }
        let generations = try AntigravityMetadataReader.read(database)
        self.databaseGenerations.store((wal, generations), for: path, stamp: stamp)
        return generations
    }

    private static func parse(_ data: Data, sessionID: String, now: Date) -> Parsed {
        var result = Parsed()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if line.allSatisfy({ [0x20, 0x09, 0x0D].contains($0) }) { continue }
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                // A writer may still be appending the final row.
                if index != lines.count - 1 || data.last == 0x0A { result.malformed += 1 }
                continue
            }
            guard row["source"] as? String == "MODEL", row["type"] as? String == "PLANNER_RESPONSE" else { continue }
            guard let step = Self.integer(row["step_index"]),
                  let rawTimestamp = row["created_at"] as? String,
                  let timestamp = ISO8601Parsing.parse(rawTimestamp) else {
                result.malformed += 1
                continue
            }
            guard timestamp <= now else {
                result.earliestSkippedFutureAt = min(result.earliestSkippedFutureAt ?? timestamp, timestamp)
                continue
            }
            let required = ["input_tokens", "output_tokens", "cache_read_tokens"]
            guard required.allSatisfy({ row[$0] != nil }) else {
                if row["status"] as? String == "DONE" {
                    result.unreportedEvents.insert(Self.eventID(sessionID: sessionID, step: step, timestamp: timestamp))
                }
                continue
            }
            guard let input = Self.integer(row["input_tokens"]),
                  let output = Self.integer(row["output_tokens"]),
                  let cacheRead = Self.integer(row["cache_read_tokens"]),
                  let cacheWrite = row["cache_write_tokens"].map(Self.integer) ?? 0 else {
                result.malformed += 1
                continue
            }
            var total = 0
            var overflow = false
            for count in [input, output, cacheRead, cacheWrite] {
                let addition = total.addingReportingOverflow(count)
                overflow = overflow || addition.overflow
                total = addition.partialValue
            }
            guard !overflow else { result.malformed += 1; continue }
            let identity = Self.eventID(sessionID: sessionID, step: step, timestamp: timestamp)
            result.records.append(ToolUsageRecord(
                id: identity, timestamp: timestamp, modelID: nil, sessionID: sessionID,
                inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite, totalTokens: total
            ))
        }
        return result
    }

    private static func eventID(sessionID: String, step: Int, timestamp: Date) -> String {
        "antigravity:\(sessionID):\(step):\(timestamp.timeIntervalSince1970)"
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), integer >= 0 else { return nil }
        return integer
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private struct Candidate {
        let file: URL
        let sessionID: String
        let modifiedAt: Date
    }

    private struct Parsed {
        var records: [ToolUsageRecord] = []
        var malformed = 0
        var unreportedEvents = Set<String>()
        /// Rows dated after the scan's `now` were skipped; a cached parse is stale once this is due.
        var earliestSkippedFutureAt: Date?
    }

    private enum ReadError: Error { case tooLarge }

    private struct Totals {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var total = 0

        mutating func add(_ record: ToolUsageRecord) -> Bool {
            let pairs = [(input, record.inputTokens), (output, record.outputTokens),
                         (cacheRead, record.cacheReadTokens), (cacheWrite, record.cacheWriteTokens),
                         (total, record.totalTokens)]
            let sums = pairs.map { $0.0.addingReportingOverflow($0.1) }
            guard !sums.contains(where: \.overflow) else { return false }
            input = sums[0].partialValue
            output = sums[1].partialValue
            cacheRead = sums[2].partialValue
            cacheWrite = sums[3].partialValue
            total = sums[4].partialValue
            return true
        }
    }
}

/// Reads only usage/model/time fields from Antigravity's persisted protobuf metadata.
/// Field numbers were checked against the descriptors shipped in Antigravity IDE 2.5.5.
nonisolated private enum AntigravityMetadataReader {
    struct Generation {
        let index: Int
        let steps: [Int: Date]
        let timestamp: Date?
        let model: String?
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
    }

    enum ReadError: Error {
        case database
        case oversizedMetadata
        case invalidProtobuf
    }

    private static let maximumMetadataBytes = 8 * 1024 * 1024

    static func read(_ url: URL) throws -> [Generation] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw ReadError.database
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ReadError.database }
        var committed = false
        defer {
            if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        }

        var stepTimes: [Int: Date] = [:]
        try rows("SELECT idx, metadata FROM steps", database: database) { statement in
            let index = try index(statement)
            let metadata = try WireMessage(blob(statement))
            if let created = try metadata.message(1)?.timestamp() {
                stepTimes[index] = created
            }
        }
        var generations: [Generation] = []
        try rows("SELECT idx, data FROM gen_metadata", database: database) { statement in
            let index = try index(statement)
            let metadata = try WireMessage(blob(statement))
            guard let chat = try metadata.message(1), let usage = try chat.message(4) else { return }
            var times: [Int: Date] = [:]
            for step in try metadata.repeatedIntegers(2) {
                if let time = stepTimes[step] { times[step] = time }
            }
            let chatStartedAt = try chat.message(9)?.message(4)?.timestamp()
            let model = try chat.string(22) ?? chat.string(19) ?? chat.string(21)
            generations.append(Generation(
                index: index, steps: times,
                timestamp: times.values.min() ?? chatStartedAt,
                model: model,
                input: try usage.integer(2), output: try usage.integer(3),
                cacheRead: try usage.integer(5), cacheWrite: try usage.integer(4)
            ))
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw ReadError.database }
        committed = true
        return generations
    }

    private static func rows(_ sql: String, database: OpaquePointer, body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else {
            throw ReadError.database
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return
            case SQLITE_ROW: try body(statement)
            default: throw ReadError.database
            }
        }
    }

    private static func index(_ statement: OpaquePointer) throws -> Int {
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw ReadError.database }
        let value = sqlite3_column_int64(statement, 0)
        guard value >= 0, let result = Int(exactly: value) else { throw ReadError.database }
        return result
    }

    private static func blob(_ statement: OpaquePointer) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, 1))
        guard count <= maximumMetadataBytes else { throw ReadError.oversizedMetadata }
        guard sqlite3_column_type(statement, 1) == SQLITE_BLOB else { throw ReadError.invalidProtobuf }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, 1) else { throw ReadError.invalidProtobuf }
        return Data(bytes: bytes, count: count)
    }

    private struct WireMessage {
        private enum Value {
            case integer(UInt64)
            case bytes(Range<Int>)
            case fixed
        }
        private let data: Data
        private let values: [Int: [Value]]

        init(_ data: Data) throws {
            guard data.count <= maximumMetadataBytes else { throw ReadError.oversizedMetadata }
            self.data = data
            var values: [Int: [Value]] = [:]
            var offset = 0
            while offset < data.count {
                let tag = try Self.varint(data, offset: &offset)
                let number = tag >> 3
                guard number > 0, number <= 536_870_911 else { throw ReadError.invalidProtobuf }
                let value: Value
                switch tag & 7 {
                case 0:
                    value = .integer(try Self.varint(data, offset: &offset))
                case 1, 5:
                    let length = tag & 7 == 1 ? 8 : 4
                    guard length <= data.count - offset else { throw ReadError.invalidProtobuf }
                    offset += length
                    value = .fixed
                case 2:
                    let length = try Self.varint(data, offset: &offset)
                    guard length <= UInt64(data.count - offset) else { throw ReadError.invalidProtobuf }
                    let end = offset + Int(length)
                    value = .bytes(offset..<end)
                    offset = end
                default:
                    throw ReadError.invalidProtobuf
                }
                values[Int(number), default: []].append(value)
            }
            self.values = values
        }

        func integer(_ field: Int) throws -> Int {
            guard let value = values[field]?.last else { return 0 }
            guard case .integer(let integer) = value, let result = Int(exactly: integer) else {
                throw ReadError.invalidProtobuf
            }
            return result
        }

        func repeatedIntegers(_ field: Int) throws -> [Int] {
            var result: [Int] = []
            for value in values[field] ?? [] {
                switch value {
                case .integer(let integer):
                    guard let number = Int(exactly: integer) else { throw ReadError.invalidProtobuf }
                    result.append(number)
                case .bytes(let range):
                    let packed = data.subdata(in: range)
                    var offset = 0
                    while offset < packed.count {
                        guard let number = Int(exactly: try Self.varint(packed, offset: &offset)) else {
                            throw ReadError.invalidProtobuf
                        }
                        result.append(number)
                    }
                case .fixed:
                    throw ReadError.invalidProtobuf
                }
            }
            return result
        }

        func message(_ field: Int) throws -> WireMessage? {
            guard let value = values[field]?.last else { return nil }
            guard case .bytes(let range) = value else { throw ReadError.invalidProtobuf }
            return try WireMessage(data.subdata(in: range))
        }

        func string(_ field: Int) throws -> String? {
            guard let value = values[field]?.last else { return nil }
            guard case .bytes(let range) = value, range.count <= 1_024,
                  let decoded = String(data: data.subdata(in: range), encoding: .utf8) else {
                throw ReadError.invalidProtobuf
            }
            let result = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }

        func timestamp() throws -> Date? {
            let seconds = try integer(1)
            let nanos = try integer(2)
            guard nanos < 1_000_000_000 else { throw ReadError.invalidProtobuf }
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        }

        private static func varint(_ data: Data, offset: inout Int) throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < data.count else { throw ReadError.invalidProtobuf }
                let byte = data[offset]
                offset += 1
                guard shift < 63 || byte <= 1 else { throw ReadError.invalidProtobuf }
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
            }
            throw ReadError.invalidProtobuf
        }
    }
}
