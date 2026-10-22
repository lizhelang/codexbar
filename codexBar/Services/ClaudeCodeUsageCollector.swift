import Foundation

/// Reads Claude Code's local JSONL transcripts without retaining conversation content.
nonisolated struct ClaudeCodeUsageCollector: ToolUsageCollecting {
    let client: ToolUsageClient = .claudeCode

    private let projectsURL: URL
    private let transcriptsURL: URL
    nonisolated var watchedPaths: [URL] { [self.projectsURL, self.transcriptsURL] }

    nonisolated init(
        projectsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        transcriptsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/transcripts", isDirectory: true)
    ) {
        self.projectsURL = projectsURL
        self.transcriptsURL = transcriptsURL
    }

    nonisolated func collect(now: Date = Date(), calendar: Calendar = .current) -> ToolUsageSnapshot {
        let fileManager = FileManager.default
        var sourceFound = false
        var readFailed = false
        var parseFailed = false
        var seenFiles = Set<String>()
        var files: [URL] = []

        for root in [self.projectsURL, self.transcriptsURL] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                readFailed = true
                continue
            }
            sourceFound = true

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, _ in
                    readFailed = true
                    return true
                }
            ) else {
                readFailed = true
                continue
            }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    continue
                }
                let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                if seenFiles.insert(canonicalPath).inserted {
                    files.append(url)
                }
            }
        }

        let decoder = JSONDecoder()
        var messages: [MessageKey: UsageSample] = [:]
        var titles: [String: String] = [:]
        var sessionStates: [String: SessionState] = [:]

        // Transcripts are append-only, so each file's parse result is cached and only new lines are
        // decoded on later scans. Merging per-file results in file order matches a single pass over
        // every line: usage merges take maxima, titles are last-wins, session states keep the latest.
        let cache = TranscriptCache.shared
        var nextCacheEntries: [String: CachedTranscript] = [:]
        for file in files {
            let path = file.standardizedFileURL.path
            guard let result = Self.parseState(
                for: file,
                path: path,
                cached: cache.entry(for: path),
                now: now,
                decoder: decoder
            ) else {
                readFailed = true
                continue
            }
            nextCacheEntries[path] = result.entry
            let state = result.state
            parseFailed = parseFailed || state.parseFailed
            for (key, sample) in state.messages {
                if var previous = messages[key] {
                    previous.merge(
                        usage: sample.usage, timestamp: sample.timestamp,
                        modelID: sample.modelID, projectPath: sample.projectPath
                    )
                    messages[key] = previous
                } else {
                    messages[key] = sample
                }
            }
            titles.merge(state.titles) { _, next in next }
            for (sessionID, next) in state.sessionStates {
                if let existing = sessionStates[sessionID], next.observedAt < existing.observedAt { continue }
                sessionStates[sessionID] = next
            }
        }
        cache.replaceEntries(with: nextCacheEntries, under: [self.projectsURL, self.transcriptsURL])

        var days: [Date: DayTotals] = [:]
        var latestUsageAt: Date?
        var usageRecords: [ToolUsageRecord] = []
        for (key, sample) in messages {
            let day = calendar.startOfDay(for: sample.timestamp)
            var totals = days[day] ?? DayTotals()
            if totals.add(sample.usage) {
                days[day] = totals
                usageRecords.append(ToolUsageRecord(
                    id: key.recordID, timestamp: sample.timestamp, modelID: sample.modelID,
                    sessionID: sample.sessionID, sessionTitle: titles[sample.sessionID], projectPath: sample.projectPath,
                    sessionIsRunning: sessionStates[sample.sessionID]?.isRunning,
                    inputTokens: sample.usage.input, outputTokens: sample.usage.output,
                    cacheReadTokens: sample.usage.cacheRead, cacheWriteTokens: sample.usage.cacheWrite,
                    cacheWriteOneHourTokens: sample.usage.cacheCreation?.oneHourInputTokens,
                    totalTokens: sample.usage.totalTokens ?? 0
                ))
                latestUsageAt = max(latestUsageAt ?? sample.timestamp, sample.timestamp)
            } else {
                readFailed = true
            }
        }
        let entries = days.keys.sorted().compactMap { day -> ToolUsageDailyEntry? in
            guard let totals = days[day], let total = totals.totalTokens else { return nil }
            return ToolUsageDailyEntry(
                date: day,
                inputTokens: totals.inputTokens,
                outputTokens: totals.outputTokens,
                cacheReadTokens: totals.cacheReadTokens,
                cacheWriteTokens: totals.cacheWriteTokens,
                totalTokens: total
            )
        }

        let availability: ToolUsageAvailability
        let detail: String?
        if readFailed {
            availability = .failed
            detail = "部分 Claude Code 本地记录无法读取"
        } else if !sourceFound {
            availability = .sourceMissing
            detail = "未找到 Claude Code 本地记录"
        } else if parseFailed {
            availability = .partial
            detail = "部分 Claude Code 用量记录无法解析"
        } else if entries.isEmpty {
            availability = .noRecords
            detail = "未发现可统计的 Token 用量"
        } else {
            availability = .ready
            detail = nil
        }
        return ToolCostEstimator.reprice(ToolUsageSnapshot(
            client: self.client,
            availability: availability,
            dailyEntries: entries,
            usageRecords: usageRecords.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp },
            latestUsageAt: latestUsageAt,
            refreshedAt: now,
            statusDetail: detail
        ), calendar: calendar)
    }

    private static func isDamagedUsageRecord(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) else {
            // A complete JSONL line with invalid JSON may have contained usage.
            return !line.allSatisfy { $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }
        }
        return (object as? [String: Any])?["type"] as? String == "assistant"
    }

    /// Calls `body` for each newline-terminated line after `offset`. Returns the offset just past the
    /// last complete line plus the unterminated tail, or nil when `offset` is not a line boundary.
    private static func forEachCompleteLine(
        in handle: FileHandle,
        from offset: Int64,
        body: (Data) -> Void
    ) throws -> (parsedBytes: Int64, trailingLine: Data)? {
        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset - 1))
            guard let previous = try handle.read(upToCount: 1), previous.first == 0x0A else { return nil }
        } else {
            // The same handle is reused for a full re-read after a failed resume.
            try handle.seek(toOffset: 0)
        }
        var consumed = offset
        var pending = Data()
        var scanFrom = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            var searchStart = pending.index(pending.startIndex, offsetBy: scanFrom)
            while let newline = pending[searchStart...].firstIndex(of: 0x0A) {
                body(Data(pending[lineStart..<newline]))
                lineStart = pending.index(after: newline)
                searchStart = lineStart
            }
            let processed = pending.distance(from: pending.startIndex, to: lineStart)
            consumed += Int64(processed)
            // Removing the head of a Data shifts the remaining bytes; do it once per chunk, not per line.
            if processed > 0 {
                pending = Data(pending[lineStart...])
            }
            scanFrom = pending.count
        }
        return (consumed, pending)
    }

    private static func parseState(
        for file: URL,
        path: String,
        cached: CachedTranscript?,
        now: Date,
        decoder: JSONDecoder
    ) -> (state: ParseState, entry: CachedTranscript)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let identity = FileIdentity(
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date ?? .distantPast
        )

        var resumable = cached
        // Rows timestamped after the previous scan's `now` were skipped; once they are due, start over.
        if let skipped = cached?.result.earliestSkippedFutureAt, skipped <= now {
            resumable = nil
        }
        if let entry = resumable {
            if entry.identity == identity {
                return (entry.result, entry)
            }
            if entry.identity.fileNumber != identity.fileNumber ||
                identity.size < entry.parsedBytes ||
                identity.modificationDate < entry.identity.modificationDate {
                resumable = nil
            }
        }

        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            if let entry = resumable,
               try Self.anchor(in: handle, endingAt: entry.parsedBytes) == entry.anchor,
               let parsed = try Self.parse(handle: handle, from: entry.parsedBytes, state: entry.resume,
                                           file: file, now: now, decoder: decoder) {
                return Self.finish(parsed, identity: identity, file: file, now: now, decoder: decoder)
            }
            guard let parsed = try Self.parse(handle: handle, from: 0, state: ParseState(),
                                              file: file, now: now, decoder: decoder) else { return nil }
            return Self.finish(parsed, identity: identity, file: file, now: now, decoder: decoder)
        } catch {
            return nil
        }
    }

    private static func parse(
        handle: FileHandle,
        from offset: Int64,
        state: ParseState,
        file: URL,
        now: Date,
        decoder: JSONDecoder
    ) throws -> ParsedTranscript? {
        var state = state
        guard let scan = try Self.forEachCompleteLine(in: handle, from: offset, body: { line in
            state.lineNumber += 1
            Self.consume(line, lineNumber: state.lineNumber, isCompleteLine: true,
                         file: file, now: now, decoder: decoder, state: &state)
        }) else { return nil }
        let anchor = try Self.anchor(in: handle, endingAt: scan.parsedBytes)
        return ParsedTranscript(state: state, parsedBytes: scan.parsedBytes, anchor: anchor, trailingLine: scan.trailingLine)
    }

    /// The bytes just before a resume offset. An in-place rewrite that happens to leave a newline at
    /// the old offset still changes these bytes, so it is re-read from the start instead of resumed.
    private static func anchor(in handle: FileHandle, endingAt offset: Int64) throws -> Data {
        let length = min(offset, 64)
        guard length > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset - length))
        return try handle.read(upToCount: Int(length)) ?? Data()
    }

    private static func finish(
        _ parsed: ParsedTranscript,
        identity: FileIdentity,
        file: URL,
        now: Date,
        decoder: JSONDecoder
    ) -> (state: ParseState, entry: CachedTranscript) {
        // An unterminated tail counts toward this scan's result but is re-read once it is finished.
        var result = parsed.state
        if !parsed.trailingLine.isEmpty {
            Self.consume(parsed.trailingLine, lineNumber: result.lineNumber + 1, isCompleteLine: false,
                         file: file, now: now, decoder: decoder, state: &result)
        }
        let entry = CachedTranscript(identity: identity, parsedBytes: parsed.parsedBytes, anchor: parsed.anchor,
                                     resume: parsed.state, result: result)
        return (result, entry)
    }

    /// Lines that cannot affect usage, titles or session state (attachments, snapshots, system rows)
    /// are skipped before the comparatively expensive full decode.
    private static let relevantLineMarkers: [Data] = [
        "\"assistant\"", "\"user\"", "\"usage\"", "Title\"", "\"summary\"",
    ].map { Data($0.utf8) }

    private static func consume(
        _ line: Data,
        lineNumber: Int,
        isCompleteLine: Bool,
        file: URL,
        now: Date,
        decoder: JSONDecoder,
        state: inout ParseState
    ) {
        guard Self.relevantLineMarkers.contains(where: { line.range(of: $0) != nil }) else { return }
        let record: TranscriptRecord
        do {
            record = try decoder.decode(TranscriptRecord.self, from: line)
        } catch {
            if isCompleteLine && Self.isDamagedUsageRecord(line) {
                state.parseFailed = true
            }
            return
        }
        let sessionID = record.sessionId ?? file.deletingPathExtension().lastPathComponent
        if let title = record.customTitle ?? record.aiTitle ?? record.summary, !title.isEmpty {
            state.titles[sessionID] = title
        }
        let observedAt = record.timestamp.flatMap(ISO8601Parsing.parse)
        if let observedAt, observedAt > now {
            state.earliestSkippedFutureAt = min(state.earliestSkippedFutureAt ?? observedAt, observedAt)
        }
        if let observedAt, observedAt <= now,
           state.sessionStates[sessionID].map({ observedAt >= $0.observedAt }) ?? true {
            if record.type == "user" {
                // A later user/tool row makes the previous assistant completion stale.
                state.sessionStates[sessionID] = SessionState(observedAt: observedAt, isRunning: nil)
            } else if record.type == "assistant", let reason = record.message?.stopReason, !reason.isEmpty {
                state.sessionStates[sessionID] = SessionState(observedAt: observedAt, isRunning: reason == "tool_use")
            }
        }
        guard record.type == "assistant", let message = record.message else { return }
        guard let usage = message.usage, usage.hasTokenFields else { return }
        guard message.role == nil || message.role == "assistant",
              usage.hasValidTokens,
              usage.totalTokens != nil,
              let timestamp = observedAt else {
            state.parseFailed = true
            return
        }
        guard usage.hasTokens, timestamp <= now else { return }

        let key: MessageKey
        if let id = message.id, !id.isEmpty {
            key = .message(id, record.requestId)
        } else if let requestId = record.requestId, !requestId.isEmpty {
            key = .request(requestId)
        } else {
            key = .line(file.standardizedFileURL.path, lineNumber)
        }
        if var previous = state.messages[key] {
            previous.merge(usage: usage, timestamp: timestamp, modelID: message.model, projectPath: record.cwd)
            state.messages[key] = previous
        } else {
            state.messages[key] = UsageSample(
                usage: usage, timestamp: timestamp, modelID: message.model,
                sessionID: sessionID, projectPath: record.cwd
            )
        }
    }

    private struct SessionState {
        let observedAt: Date
        let isRunning: Bool?
    }

    private struct ParseState {
        var messages: [MessageKey: UsageSample] = [:]
        var titles: [String: String] = [:]
        var sessionStates: [String: SessionState] = [:]
        var parseFailed = false
        var lineNumber = 0
        var earliestSkippedFutureAt: Date?
    }

    private struct FileIdentity: Equatable {
        let fileNumber: UInt64
        let size: Int64
        let modificationDate: Date
    }

    private struct ParsedTranscript {
        let state: ParseState
        let parsedBytes: Int64
        let anchor: Data
        let trailingLine: Data
    }

    private struct CachedTranscript {
        let identity: FileIdentity
        /// Offset just past the last newline-terminated line folded into `resume`.
        let parsedBytes: Int64
        let anchor: Data
        let resume: ParseState
        /// `resume` plus the unterminated tail, if any; returned as-is while the file is unchanged.
        let result: ParseState
    }

    private final class TranscriptCache: @unchecked Sendable {
        static let shared = TranscriptCache()

        private let lock = NSLock()
        private var entries: [String: CachedTranscript] = [:]

        func entry(for path: String) -> CachedTranscript? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.entries[path]
        }

        /// Replaces the entries under `roots` so deleted transcripts do not linger in memory,
        /// leaving other collectors' roots (custom data directories, tests) untouched.
        func replaceEntries(with next: [String: CachedTranscript], under roots: [URL]) {
            let prefixes = roots.map { $0.standardizedFileURL.path + "/" }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.entries = self.entries.filter { path, _ in !prefixes.contains { path.hasPrefix($0) } }
            self.entries.merge(next) { _, new in new }
        }
    }

    private enum MessageKey: Hashable {
        case message(String, String?)
        case request(String)
        case line(String, Int)

        var recordID: String {
            switch self {
            case .message(let id, let request): "message:\(id):\(request ?? "")"
            case .request(let id): "request:\(id)"
            case .line(let path, let line): "line:\(path):\(line)"
            }
        }
    }

    private struct TranscriptRecord: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let sessionId: String?
        let cwd: String?
        let aiTitle: String?
        let customTitle: String?
        let summary: String?
        let message: TranscriptMessage?
    }

    private struct TranscriptMessage: Decodable {
        let id: String?
        let role: String?
        let model: String?
        let stopReason: String?
        let usage: TokenUsage?

        enum CodingKeys: String, CodingKey {
            case id, role, model, usage
            case stopReason = "stop_reason"
        }
    }

    private struct TokenUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let cacheCreation: CacheCreation?

        struct CacheCreation: Decodable {
            let oneHourInputTokens: Int?
            let fiveMinuteInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case oneHourInputTokens = "ephemeral_1h_input_tokens"
                case fiveMinuteInputTokens = "ephemeral_5m_input_tokens"
            }
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_input_tokens"
            case cacheWriteTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
        }

        var input: Int { self.inputTokens ?? 0 }
        var output: Int { self.outputTokens ?? 0 }
        var cacheRead: Int { self.cacheReadTokens ?? 0 }
        var cacheWrite: Int { self.cacheWriteTokens ?? 0 }

        var hasTokens: Bool {
            [self.input, self.output, self.cacheRead, self.cacheWrite].contains { $0 > 0 }
        }

        var hasTokenFields: Bool {
            self.inputTokens != nil || self.outputTokens != nil
                || self.cacheReadTokens != nil || self.cacheWriteTokens != nil
        }

        var hasValidTokens: Bool {
            let oneHour = self.cacheCreation?.oneHourInputTokens ?? 0
            let fiveMinute = self.cacheCreation?.fiveMinuteInputTokens ?? 0
            return [self.input, self.output, self.cacheRead, self.cacheWrite, oneHour, fiveMinute].allSatisfy { $0 >= 0 }
                && Self.checkedSum([oneHour, fiveMinute]).map { $0 <= self.cacheWrite } == true
        }

        var totalTokens: Int? {
            Self.checkedSum([self.input, self.output, self.cacheRead, self.cacheWrite])
        }

        static func checkedSum(_ values: [Int]) -> Int? {
            var result = 0
            for value in values {
                let (sum, overflow) = result.addingReportingOverflow(value)
                guard !overflow else { return nil }
                result = sum
            }
            return result
        }
    }

    private struct UsageSample {
        var usage: TokenUsage
        var timestamp: Date
        var modelID: String?
        let sessionID: String
        var projectPath: String?

        mutating func merge(usage next: TokenUsage, timestamp nextTimestamp: Date, modelID: String?, projectPath: String?) {
            self.modelID = modelID ?? self.modelID
            self.projectPath = projectPath ?? self.projectPath
            self.usage = TokenUsage(
                inputTokens: max(self.usage.input, next.input),
                outputTokens: max(self.usage.output, next.output),
                cacheReadTokens: max(self.usage.cacheRead, next.cacheRead),
                cacheWriteTokens: max(self.usage.cacheWrite, next.cacheWrite),
                cacheCreation: self.usage.cacheCreation == nil && next.cacheCreation == nil ? nil : TokenUsage.CacheCreation(
                    oneHourInputTokens: max(self.usage.cacheCreation?.oneHourInputTokens ?? 0, next.cacheCreation?.oneHourInputTokens ?? 0),
                    fiveMinuteInputTokens: max(self.usage.cacheCreation?.fiveMinuteInputTokens ?? 0, next.cacheCreation?.fiveMinuteInputTokens ?? 0)
                )
            )
            self.timestamp = max(self.timestamp, nextTimestamp)
        }
    }

    private struct DayTotals {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0

        var totalTokens: Int? {
            TokenUsage.checkedSum([
                self.inputTokens, self.outputTokens, self.cacheReadTokens, self.cacheWriteTokens,
            ])
        }

        mutating func add(_ usage: TokenUsage) -> Bool {
            guard let input = TokenUsage.checkedSum([self.inputTokens, usage.input]),
                  let output = TokenUsage.checkedSum([self.outputTokens, usage.output]),
                  let cacheRead = TokenUsage.checkedSum([self.cacheReadTokens, usage.cacheRead]),
                  let cacheWrite = TokenUsage.checkedSum([self.cacheWriteTokens, usage.cacheWrite]),
                  TokenUsage.checkedSum([input, output, cacheRead, cacheWrite]) != nil else { return false }
            self.inputTokens = input
            self.outputTokens = output
            self.cacheReadTokens = cacheRead
            self.cacheWriteTokens = cacheWrite
            return true
        }
    }
}
