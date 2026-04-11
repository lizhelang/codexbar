import Foundation

final class SessionLogStore {
    static let shared = SessionLogStore()

    enum TaskLifecycleState: String, Codable, Equatable {
        case running
        case completed
    }

    struct Usage: Codable, Equatable {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int

        nonisolated static let zero = Usage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)

        nonisolated var totalTokens: Int {
            self.inputTokens + self.outputTokens
        }

        nonisolated var isZero: Bool {
            self.inputTokens == 0 &&
            self.cachedInputTokens == 0 &&
            self.outputTokens == 0
        }

        nonisolated static func +(lhs: Usage, rhs: Usage) -> Usage {
            Usage(
                inputTokens: lhs.inputTokens + rhs.inputTokens,
                cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
                outputTokens: lhs.outputTokens + rhs.outputTokens
            )
        }

        nonisolated func delta(from previous: Usage) -> Usage {
            Usage(
                inputTokens: max(0, self.inputTokens - previous.inputTokens),
                cachedInputTokens: max(0, self.cachedInputTokens - previous.cachedInputTokens),
                outputTokens: max(0, self.outputTokens - previous.outputTokens)
            )
        }
    }

    struct SessionRecord: Codable, Equatable {
        let id: String
        let startedAt: Date
        let lastActivityAt: Date
        let isArchived: Bool
        let model: String
        let usage: Usage
        let taskLifecycleState: TaskLifecycleState?
    }

    struct UsageEvent: Codable, Equatable {
        let timestamp: Date
        let usage: Usage
    }

    private struct FileFingerprint: Codable, Equatable {
        let fileSize: Int
        let modificationDate: Date
    }

    private struct CachedSessionRecord: Codable {
        let fingerprint: FileFingerprint
        let record: SessionRecord?
        let usageEvents: [UsageEvent]
    }

    private struct UsageSample {
        let timestamp: Date?
        let totalUsage: Usage
        let incrementalUsage: Usage?
    }

    private struct PersistedCache: Codable {
        let version: Int
        let files: [String: CachedSessionRecord]
    }

    private let fileManager: FileManager
    private let codexRootURL: URL
    private let persistedCacheURL: URL
    private let queue = DispatchQueue(label: "lzl.codexbar.session-log-store", qos: .utility)
    private let persistedCacheVersion = 4

    private var sessionCache: [URL: CachedSessionRecord] = [:]

    init(
        fileManager: FileManager = .default,
        codexRootURL: URL = CodexPaths.codexRoot,
        persistedCacheURL: URL = CodexPaths.costSessionCacheURL
    ) {
        self.fileManager = fileManager
        self.codexRootURL = codexRootURL
        self.persistedCacheURL = persistedCacheURL
        self.sessionCache = self.loadPersistedCache()
    }

    func reduceSessions<Result>(
        into initialResult: Result,
        _ update: (inout Result, SessionRecord) -> Void
    ) -> Result {
        self.queue.sync {
            var result = initialResult
            self.reduceSessionsLocked(into: &result, update)
            return result
        }
    }

    func sessionRecords() -> [SessionRecord] {
        self.reduceSessions(into: [SessionRecord]()) { result, record in
            result.append(record)
        }
    }

    func currentSessionRecords() -> [SessionRecord] {
        self.sessionRecords().filter { $0.isArchived == false }
    }

    func reduceUsageEvents<Result>(
        into initialResult: Result,
        _ update: (inout Result, SessionRecord, UsageEvent) -> Void
    ) -> Result {
        self.queue.sync {
            var result = initialResult
            self.reduceCachedSessionsLocked(into: &result) { partialResult, cached in
                guard let record = cached.record else { return }
                for event in cached.usageEvents {
                    update(&partialResult, record, event)
                }
            }
            return result
        }
    }

    private func reduceSessionsLocked<Result>(
        into result: inout Result,
        _ update: (inout Result, SessionRecord) -> Void
    ) {
        self.reduceCachedSessionsLocked(into: &result) { partialResult, cached in
            if let record = cached.record {
                update(&partialResult, record)
            }
        }
    }

    private func reduceCachedSessionsLocked<Result>(
        into result: inout Result,
        _ update: (inout Result, CachedSessionRecord) -> Void
    ) {
        let files = self.sessionFiles()
        var nextSessionCache: [URL: CachedSessionRecord] = [:]
        nextSessionCache.reserveCapacity(files.count)

        for fileURL in files {
            autoreleasepool {
                guard let fingerprint = self.fingerprint(for: fileURL) else { return }

                if let cached = self.sessionCache[fileURL], cached.fingerprint == fingerprint {
                    nextSessionCache[fileURL] = cached
                    update(&result, cached)
                    return
                }

                let cached = self.parseSession(fileURL, fingerprint: fingerprint)
                nextSessionCache[fileURL] = cached
                update(&result, cached)
            }
        }

        self.sessionCache = nextSessionCache
        self.persistSessionCache(nextSessionCache)
    }

    private func sessionFiles() -> [URL] {
        let directories = [
            self.codexRootURL.appendingPathComponent("sessions", isDirectory: true),
            self.codexRootURL.appendingPathComponent("archived_sessions", isDirectory: true),
        ]

        var files: [URL] = []
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            )
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func fingerprint(for fileURL: URL) -> FileFingerprint? {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }

        return FileFingerprint(
            fileSize: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate ?? .distantPast
        )
    }

    private func parseSession(_ fileURL: URL, fingerprint: FileFingerprint) -> CachedSessionRecord {
        var sessionID: String?
        var sessionDate: Date?
        var model: String?
        var latestUsage: Usage?
        var previousTotalUsage: Usage?
        var usageEvents: [UsageEvent] = []
        var taskLifecycleState: TaskLifecycleState?

        let didRead = self.enumerateLines(in: fileURL) { line in
            self.consumeSessionMetadata(in: line, sessionID: &sessionID, sessionDate: &sessionDate)
            self.consumeTurnContext(in: line, model: &model)
            self.consumeTaskLifecycle(in: line, taskLifecycleState: &taskLifecycleState)
            if let sample = self.parseUsageSample(from: line) {
                latestUsage = sample.totalUsage

                let incrementalUsage = sample.incrementalUsage
                    ?? previousTotalUsage.map { sample.totalUsage.delta(from: $0) }
                    ?? sample.totalUsage
                previousTotalUsage = sample.totalUsage

                let eventTimestamp = sample.timestamp ?? sessionDate ?? fingerprint.modificationDate
                if incrementalUsage.isZero == false {
                    usageEvents.append(
                        UsageEvent(timestamp: eventTimestamp, usage: incrementalUsage)
                    )
                }
            }
        }

        let record: SessionRecord?
        if didRead,
           let startedAt = sessionDate,
           let resolvedModel = model,
           let usage = latestUsage {
            record = SessionRecord(
                id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                startedAt: startedAt,
                lastActivityAt: fingerprint.modificationDate,
                isArchived: self.isArchivedSessionFile(fileURL),
                model: resolvedModel,
                usage: usage,
                taskLifecycleState: taskLifecycleState
            )
        } else {
            record = nil
        }

        return CachedSessionRecord(
            fingerprint: fingerprint,
            record: record,
            usageEvents: usageEvents
        )
    }

    private func isArchivedSessionFile(_ fileURL: URL) -> Bool {
        let archivedRoot = self.codexRootURL
            .appendingPathComponent("archived_sessions", isDirectory: true)
            .standardizedFileURL
            .path
        return fileURL.standardizedFileURL.path.hasPrefix(archivedRoot)
    }

    private func consumeSessionMetadata(in line: String, sessionID: inout String?, sessionDate: inout Date?) {
        guard sessionDate == nil,
              line.contains("\"type\":\"session_meta\"") else { return }

        if let payload = self.payloadSlice(in: line) {
            if sessionID == nil {
                sessionID = self.extractString("id", in: payload)
            }
            if let timestamp = self.extractString("timestamp", in: payload) {
                sessionDate = ISO8601Parsing.parse(timestamp)
            }
        }

        if sessionDate == nil,
           let payload = self.parsePayload(from: line) {
            if sessionID == nil {
                sessionID = payload["id"] as? String
            }
            if let timestamp = payload["timestamp"] as? String {
                sessionDate = ISO8601Parsing.parse(timestamp)
            }
        }
    }

    private func consumeTurnContext(in line: String, model: inout String?) {
        guard model == nil,
              line.contains("\"type\":\"turn_context\"") else { return }

        if let payload = self.payloadSlice(in: line),
           let currentModel = self.extractString("model", in: payload) {
            model = self.normalizeModel(currentModel)
            return
        }

        if let payload = self.parsePayload(from: line),
           let currentModel = payload["model"] as? String {
            model = self.normalizeModel(currentModel)
        }
    }

    private func consumeTaskLifecycle(
        in line: String,
        taskLifecycleState: inout TaskLifecycleState?
    ) {
        guard line.contains("\"type\":\"event_msg\""),
              line.contains("\"task_"),
              let payload = self.parsePayload(from: line),
              let payloadType = payload["type"] as? String else {
            return
        }

        switch payloadType {
        case "task_started":
            taskLifecycleState = .running
        case "task_complete", "task_cancelled", "task_failed":
            taskLifecycleState = .completed
        default:
            break
        }
    }

    private func parseUsageSample(from line: String) -> UsageSample? {
        guard line.contains("\"type\":\"event_msg\""),
              line.contains("\"token_count\""),
              line.contains("\"total_token_usage\"") else { return nil }

        guard let jsonData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }

        let timestamp = (object["timestamp"] as? String).flatMap(ISO8601Parsing.parse(_:))

        if let payloadType = payload["type"] as? String, payloadType == "event_msg",
           let total = payload["total_token_usage"] as? [String: Any] {
            return UsageSample(
                timestamp: timestamp,
                totalUsage: self.parseUsageDictionary(total),
                incrementalUsage: (payload["last_token_usage"] as? [String: Any]).map(self.parseUsageDictionary)
            )
        }

        guard let payloadType = payload["type"] as? String,
              payloadType == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return nil }

        return UsageSample(
            timestamp: timestamp,
            totalUsage: self.parseUsageDictionary(total),
            incrementalUsage: (info["last_token_usage"] as? [String: Any]).map(self.parseUsageDictionary)
        )
    }

    private func parseUsageDictionary(_ object: [String: Any]) -> Usage {
        Usage(
            inputTokens: object["input_tokens"] as? Int ?? 0,
            cachedInputTokens: object["cached_input_tokens"] as? Int ?? 0,
            outputTokens: object["output_tokens"] as? Int ?? 0
        )
    }

    private func parsePayload(from line: String) -> [String: Any]? {
        guard let jsonData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
        return object["payload"] as? [String: Any]
    }

    private func payloadSlice(in line: String) -> Substring? {
        guard let range = line.range(of: "\"payload\":{") else { return nil }
        return line[range.upperBound...]
    }

    private func objectSlice(named key: String, in line: String) -> Substring? {
        guard let range = line.range(of: "\"\(key)\":{") else { return nil }
        return line[range.upperBound...]
    }

    private func extractString(_ key: String, in text: Substring) -> String? {
        guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
        let valueStart = range.upperBound
        guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(text[valueStart..<valueEnd])
    }

    private func extractInt(_ key: String, in text: Substring) -> Int? {
        guard let range = text.range(of: "\"\(key)\":") else { return nil }
        let valueStart = range.upperBound
        let digits = text[valueStart...].prefix { $0.isNumber || $0 == "-" }
        guard digits.isEmpty == false else { return nil }
        return Int(digits)
    }

    private func enumerateLines(in fileURL: URL, handleLine: (String) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        var buffer = Data()
        let chunkSize = 64 * 1024
        let newline = UInt8(ascii: "\n")

        do {
            while let chunk = try handle.read(upToCount: chunkSize), chunk.isEmpty == false {
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: newline) {
                    autoreleasepool {
                        self.emitLine(from: buffer[..<newlineIndex], handleLine: handleLine)
                    }
                    let nextIndex = buffer.index(after: newlineIndex)
                    buffer.removeSubrange(buffer.startIndex..<nextIndex)
                }
            }

            if buffer.isEmpty == false {
                autoreleasepool {
                    self.emitLine(from: buffer[buffer.startIndex..<buffer.endIndex], handleLine: handleLine)
                }
            }

            return true
        } catch {
            return false
        }
    }

    private func emitLine(from bytes: Data.SubSequence, handleLine: (String) -> Void) {
        guard let line = self.normalizedLine(from: bytes) else { return }
        handleLine(line)
    }

    private func normalizedLine(from bytes: Data.SubSequence) -> String? {
        var slice = bytes
        if slice.last == UInt8(ascii: "\r") {
            slice = slice.dropLast()
        }
        guard slice.isEmpty == false,
              let line = String(data: Data(slice), encoding: .utf8) else { return nil }
        return line
    }

    private func loadPersistedCache() -> [URL: CachedSessionRecord] {
        guard let data = try? Data(contentsOf: self.persistedCacheURL) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let persisted = try? decoder.decode(PersistedCache.self, from: data),
              persisted.version == self.persistedCacheVersion else {
            return [:]
        }

        var cache: [URL: CachedSessionRecord] = [:]
        cache.reserveCapacity(persisted.files.count)
        for (path, record) in persisted.files {
            cache[URL(fileURLWithPath: path)] = record
        }
        return cache
    }

    private func persistSessionCache(_ cache: [URL: CachedSessionRecord]) {
        let payload = PersistedCache(
            version: self.persistedCacheVersion,
            files: Dictionary(uniqueKeysWithValues: cache.map { ($0.key.path, $0.value) })
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(payload) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.persistedCacheURL)
    }

    private func normalizeModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            return String(trimmed.dropFirst("openai/".count))
        }
        return trimmed
    }
}
