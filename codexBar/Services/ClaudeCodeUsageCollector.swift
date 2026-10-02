import Foundation

/// Reads Claude Code's local JSONL transcripts without retaining conversation content.
nonisolated struct ClaudeCodeUsageCollector: ToolUsageCollecting {
    let client: ToolUsageClient = .claudeCode

    private let projectsURL: URL
    private let transcriptsURL: URL

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
        let fractionalDateParser = ISO8601DateFormatter()
        fractionalDateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime]
        var messages: [MessageKey: UsageSample] = [:]
        var titles: [String: String] = [:]
        var sessionStates: [String: (Date, Bool?)] = [:]

        for file in files {
            do {
                try Self.forEachLine(in: file) { line, lineNumber, isCompleteLine in
                    let record: TranscriptRecord
                    do {
                        record = try decoder.decode(TranscriptRecord.self, from: line)
                    } catch {
                        if isCompleteLine && Self.isDamagedUsageRecord(line) {
                            parseFailed = true
                        }
                        return
                    }
                    let sessionID = record.sessionId ?? file.deletingPathExtension().lastPathComponent
                    if let title = record.customTitle ?? record.aiTitle ?? record.summary, !title.isEmpty {
                        titles[sessionID] = title
                    }
                    if let raw = record.timestamp,
                       let observedAt = fractionalDateParser.date(from: raw) ?? dateParser.date(from: raw), observedAt <= now,
                       sessionStates[sessionID].map({ observedAt >= $0.0 }) ?? true {
                        if record.type == "user" {
                            // A later user/tool row makes the previous assistant completion stale.
                            sessionStates[sessionID] = (observedAt, nil)
                        } else if record.type == "assistant", let reason = record.message?.stopReason, !reason.isEmpty {
                            sessionStates[sessionID] = (observedAt, reason == "tool_use")
                        }
                    }
                    guard record.type == "assistant", let message = record.message else { return }
                    guard let usage = message.usage, usage.hasTokenFields else { return }
                    guard message.role == nil || message.role == "assistant",
                          usage.hasValidTokens,
                          usage.totalTokens != nil,
                          let timestampString = record.timestamp,
                          let timestamp = fractionalDateParser.date(from: timestampString)
                            ?? dateParser.date(from: timestampString) else {
                        parseFailed = true
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
                    if var previous = messages[key] {
                        previous.merge(usage: usage, timestamp: timestamp, modelID: message.model, projectPath: record.cwd)
                        messages[key] = previous
                    } else {
                        messages[key] = UsageSample(
                            usage: usage, timestamp: timestamp, modelID: message.model,
                            sessionID: sessionID, projectPath: record.cwd
                        )
                    }
                }
            } catch {
                readFailed = true
            }
        }

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
                    sessionIsRunning: sessionStates[sample.sessionID]?.1,
                    inputTokens: sample.usage.input, outputTokens: sample.usage.output,
                    cacheReadTokens: sample.usage.cacheRead, cacheWriteTokens: sample.usage.cacheWrite,
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

    private static func forEachLine(in url: URL, body: (Data, Int, Bool) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        var lineNumber = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                lineNumber += 1
                body(Data(pending[..<newline]), lineNumber, true)
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty {
            body(pending, lineNumber + 1, false)
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

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_input_tokens"
            case cacheWriteTokens = "cache_creation_input_tokens"
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
            [self.input, self.output, self.cacheRead, self.cacheWrite].allSatisfy { $0 >= 0 }
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
                cacheWriteTokens: max(self.usage.cacheWrite, next.cacheWrite)
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
