import Foundation

final class SessionLogStore {
    static let shared = SessionLogStore()

    struct Usage: Codable {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
    }

    struct SessionRecord: Codable {
        let id: String
        let startedAt: Date
        let model: String
        let usage: Usage
    }

    struct Snapshot {
        let sessions: [SessionRecord]
    }

    private struct FileFingerprint: Codable, Equatable {
        let fileSize: Int
        let modificationDate: Date
    }

    private struct CachedSessionRecord: Codable {
        let fingerprint: FileFingerprint
        let record: SessionRecord?
    }

    private struct PersistedCache: Codable {
        let version: Int
        let files: [String: CachedSessionRecord]
    }

    private let queue = DispatchQueue(label: "lzl.codexbar.session-log-store", qos: .utility)
    private let snapshotReuseWindow: TimeInterval = 2
    private let headerScanBytes = 4 * 1024
    private let tailScanBytes = 32 * 1024
    private let persistedCacheVersion = 1

    private var sessionCache: [URL: CachedSessionRecord] = [:]
    private var cachedSnapshot: Snapshot?
    private var cachedSnapshotAt: Date?

    private init() {
        self.sessionCache = self.loadPersistedCache()
    }

    func snapshot() -> Snapshot {
        self.queue.sync {
            let now = Date()
            if let cachedSnapshot = self.cachedSnapshot,
               let cachedSnapshotAt = self.cachedSnapshotAt,
               now.timeIntervalSince(cachedSnapshotAt) < self.snapshotReuseWindow {
                return cachedSnapshot
            }

            let snapshot = self.buildSnapshot()
            self.cachedSnapshot = snapshot
            self.cachedSnapshotAt = now
            return snapshot
        }
    }

    private func buildSnapshot() -> Snapshot {
        let files = self.sessionFiles()
        var nextSessionCache: [URL: CachedSessionRecord] = [:]
        var sessions: [SessionRecord] = []
        sessions.reserveCapacity(files.count)

        for fileURL in files {
            guard let fingerprint = self.fingerprint(for: fileURL) else { continue }
            if let cached = self.sessionCache[fileURL], cached.fingerprint == fingerprint {
                nextSessionCache[fileURL] = cached
                if let record = cached.record {
                    sessions.append(record)
                }
                continue
            }

            let record = self.parseSession(fileURL)
            let cached = CachedSessionRecord(fingerprint: fingerprint, record: record)
            nextSessionCache[fileURL] = cached
            if let record {
                sessions.append(record)
            }
        }

        self.sessionCache = nextSessionCache
        self.persistSessionCache(nextSessionCache)

        return Snapshot(sessions: sessions)
    }

    private func sessionFiles() -> [URL] {
        let fileManager = FileManager.default
        let directories = [
            CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true),
            CodexPaths.codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
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

    private func parseSession(_ fileURL: URL) -> SessionRecord? {
        if let record = self.parseSessionFast(fileURL) {
            return record
        }
        return self.parseSessionSlow(fileURL)
    }

    private func parseSessionFast(_ fileURL: URL) -> SessionRecord? {
        var sessionID: String?
        var sessionDate: Date?
        var model: String?
        var latestUsage: Usage?

        if let headerLines = self.readLines(in: fileURL, maxBytes: self.headerScanBytes, fromEnd: false) {
            for line in headerLines {
                if sessionDate == nil {
                    self.consumeSessionMetadata(in: line, sessionID: &sessionID, sessionDate: &sessionDate)
                }
                if model == nil {
                    self.consumeTurnContext(in: line, model: &model)
                }
                if sessionDate != nil, model != nil {
                    break
                }
            }
        }

        if let tailLines = self.readLines(in: fileURL, maxBytes: self.tailScanBytes, fromEnd: true) {
            for line in tailLines.reversed() {
                if latestUsage == nil {
                    latestUsage = self.parseUsage(from: line)
                }
                if model == nil {
                    self.consumeTurnContext(in: line, model: &model)
                }
                if latestUsage != nil, model != nil {
                    break
                }
            }
        }

        guard let startedAt = sessionDate,
              let resolvedModel = model,
              let usage = latestUsage else { return nil }

        return SessionRecord(
            id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
            startedAt: startedAt,
            model: resolvedModel,
            usage: usage
        )
    }

    private func parseSessionSlow(_ fileURL: URL) -> SessionRecord? {
        var sessionID: String?
        var sessionDate: Date?
        var model: String?
        var latestUsage: Usage?

        let didRead = self.enumerateLines(in: fileURL) { line in
            self.consumeSessionMetadata(in: line, sessionID: &sessionID, sessionDate: &sessionDate)
            self.consumeTurnContext(in: line, model: &model)
            if let usage = self.parseUsage(from: line) {
                latestUsage = usage
            }
        }

        guard didRead,
              let startedAt = sessionDate,
              let resolvedModel = model,
              let usage = latestUsage else { return nil }

        return SessionRecord(
            id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
            startedAt: startedAt,
            model: resolvedModel,
            usage: usage
        )
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

    private func parseUsage(from line: String) -> Usage? {
        guard line.contains("\"type\":\"event_msg\""),
              line.contains("\"token_count\""),
              line.contains("\"total_token_usage\"") else { return nil }

        if let totalUsage = self.objectSlice(named: "total_token_usage", in: line),
           let inputTokens = self.extractInt("input_tokens", in: totalUsage),
           let cachedInputTokens = self.extractInt("cached_input_tokens", in: totalUsage),
           let outputTokens = self.extractInt("output_tokens", in: totalUsage) {
            return Usage(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens
            )
        }

        guard let payload = self.parsePayload(from: line),
              let payloadType = payload["type"] as? String,
              payloadType == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return nil }

        return Usage(
            inputTokens: total["input_tokens"] as? Int ?? 0,
            cachedInputTokens: total["cached_input_tokens"] as? Int ?? 0,
            outputTokens: total["output_tokens"] as? Int ?? 0
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
                    self.emitLine(from: buffer[..<newlineIndex], handleLine: handleLine)
                    let nextIndex = buffer.index(after: newlineIndex)
                    buffer.removeSubrange(buffer.startIndex..<nextIndex)
                }
            }

            if buffer.isEmpty == false {
                self.emitLine(from: buffer[buffer.startIndex..<buffer.endIndex], handleLine: handleLine)
            }

            return true
        } catch {
            return false
        }
    }

    private func readLines(in fileURL: URL, maxBytes: Int, fromEnd: Bool) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        do {
            let data: Data
            let shouldDropFirstPartialLine: Bool

            if fromEnd {
                let fileSize = try handle.seekToEnd()
                let readSize = min(UInt64(maxBytes), fileSize)
                let startOffset = fileSize > readSize ? fileSize - readSize : 0
                try handle.seek(toOffset: startOffset)
                data = try handle.read(upToCount: Int(readSize)) ?? Data()
                shouldDropFirstPartialLine = startOffset > 0
            } else {
                try handle.seek(toOffset: 0)
                data = try handle.read(upToCount: maxBytes) ?? Data()
                shouldDropFirstPartialLine = false
            }

            return self.lines(from: data, dropFirstPartialLine: shouldDropFirstPartialLine)
        } catch {
            return nil
        }
    }

    private func lines(from data: Data, dropFirstPartialLine: Bool) -> [String] {
        guard data.isEmpty == false else { return [] }

        let newline = UInt8(ascii: "\n")
        var parts = data.split(separator: newline, omittingEmptySubsequences: false)
        if dropFirstPartialLine, parts.isEmpty == false {
            parts.removeFirst()
        }

        return parts.compactMap { self.normalizedLine(from: $0) }
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
        guard let data = try? Data(contentsOf: CodexPaths.costSessionCacheURL) else { return [:] }

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
        try? CodexPaths.writeSecureFile(data, to: CodexPaths.costSessionCacheURL)
    }

    private func normalizeModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            return String(trimmed.dropFirst("openai/".count))
        }
        return trimmed
    }
}
