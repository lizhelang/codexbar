import CoreFoundation
import Foundation

/// Reads only persisted usage metadata; transcript text never enters a snapshot.
nonisolated struct DeepSeekHarnessUsageCollector: ToolUsageCollecting {
    let client: ToolUsageClient = .deepSeekHarness
    let sessionsDirectory: URL

    init(sessionsDirectory: URL? = nil) {
        if let sessionsDirectory {
            self.sessionsDirectory = sessionsDirectory
        } else {
            let environment = ProcessInfo.processInfo.environment
            let home = environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh").path
            self.sessionsDirectory = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
    }

    func collect(now: Date = Date(), calendar: Calendar = .current) -> ToolUsageSnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ToolUsageSnapshot(client: client, availability: .sourceMissing,
                                     refreshedAt: now, statusDetail: "未找到 DSH 会话目录")
        }
        let files = preferredSessionFiles()
        guard !files.isEmpty else {
            return ToolUsageSnapshot(client: client, availability: .noRecords,
                                     refreshedAt: now, statusDetail: "尚无 DSH 会话记录")
        }

        var records: [DSHUsageRecord] = []
        var failedFiles = 0
        var malformedLines = 0
        for file in files {
            do {
                let bytes = try sessionBytes(at: file)
                let parsed = parseSession(bytes, sessionName: file.deletingLastPathComponent().lastPathComponent)
                records.append(contentsOf: parsed.records)
                malformedLines += parsed.malformedLines
            } catch {
                failedFiles += 1
            }
        }

        var seen = Set<String>()
        var daily: [Date: DSHTokenTotals] = [:]
        var latestUsageAt: Date?
        var usageRecords: [ToolUsageRecord] = []
        for record in records where record.timestamp <= now && seen.insert(record.identity).inserted {
            usageRecords.append(ToolUsageRecord(
                id: record.identity, timestamp: record.timestamp, modelID: record.model == "unknown" ? nil : record.model,
                sessionID: record.sessionID, sessionTitle: record.sessionTitle, projectPath: record.projectPath,
                sessionIsRunning: record.sessionIsRunning, contextWindowTokens: record.contextWindowTokens,
                contextUsedTokens: record.contextUsedTokens,
                inputTokens: record.totals.input, outputTokens: record.totals.output,
                cacheReadTokens: record.totals.cacheRead, cacheWriteTokens: record.totals.cacheWrite,
                totalTokens: record.totals.total
            ))
            let day = calendar.startOfDay(for: record.timestamp)
            daily[day, default: .zero].add(record.totals)
            if latestUsageAt == nil || record.timestamp > latestUsageAt! {
                latestUsageAt = record.timestamp
            }
        }
        let entries = daily.keys.sorted().map { day in
            let total = daily[day]!
            return ToolUsageDailyEntry(date: day,
                                       inputTokens: total.input,
                                       outputTokens: total.output,
                                       cacheReadTokens: total.cacheRead,
                                       cacheWriteTokens: total.cacheWrite,
                                       totalTokens: total.total)
        }
        let availability: ToolUsageAvailability
        let detail: String?
        if failedFiles > 0 {
            availability = .failed
            detail = "有 \(failedFiles) 个 DSH 会话无法读取，统计可能不完整"
        } else if malformedLines > 0 {
            availability = .partial
            detail = "跳过 \(malformedLines) 行损坏的 DSH 记录，统计可能不完整"
        } else {
            availability = entries.isEmpty ? .noRecords : .ready
            detail = nil
        }
        return ToolCostEstimator.reprice(ToolUsageSnapshot(client: client, availability: availability, dailyEntries: entries,
                                 usageRecords: usageRecords.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp },
                                 latestUsageAt: latestUsageAt, refreshedAt: now, statusDetail: detail), calendar: calendar)
    }

    private func preferredSessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var preferred: [String: (version: Int, compressed: Bool, url: URL)] = [:]
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            guard let candidate = Self.transcriptVersion(file.lastPathComponent) else { continue }
            let key = file.deletingLastPathComponent().standardizedFileURL.path
            if let previous = preferred[key],
               previous.version > candidate.version ||
               (previous.version == candidate.version && previous.compressed && !candidate.compressed) {
                continue
            }
            preferred[key] = (candidate.version, candidate.compressed, file)
        }
        return preferred.keys.sorted().compactMap { preferred[$0]?.url }
    }

    private static func transcriptVersion(_ name: String) -> (version: Int, compressed: Bool)? {
        let compressed = name.hasSuffix(".zstd")
        let suffix = compressed ? ".jsonl.zstd" : ".jsonl"
        guard name.hasSuffix(suffix) else { return nil }
        let stem = String(name.dropLast(suffix.count))
        if stem == "session" { return (0, compressed) }
        guard stem.hasPrefix("session.v"),
              let version = Int(stem.dropFirst("session.v".count)), version > 0 else { return nil }
        return (version, compressed)
    }

    private func sessionBytes(at url: URL) throws -> Data {
        let cap = 64 * 1024 * 1024
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > cap {
            throw DSHReadError.tooLarge
        }
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        guard raw.count <= cap else { throw DSHReadError.tooLarge }
        if raw.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) {
            return try DSHSystemZstd.decode(raw, limit: cap)
        }
        return raw
    }

    private func parseSession(_ data: Data, sessionName: String) -> (records: [DSHUsageRecord], malformedLines: Int) {
        var records: [DSHUsageRecord] = []
        var malformedLines = 0
        var seen = Set<String>()
        var seedLength = 0
        var waitingForSeedEnd = false
        var sessionID = sessionName
        var fallbackProvider = "unknown"
        var fallbackModel = "unknown"
        var sessionTitle: String?
        var projectPath: String?
        var sessionIsRunning: Bool?
        var contextWindowTokens: Int?
        var contextUsedTokens: Int?
        var lastSettlement: (turn: Int, step: Int, index: Int)?

        // Ignore a live writer's incomplete final JSONL row.
        var start = data.startIndex
        for end in data.indices where data[end] == 0x0A {
            defer { start = data.index(after: end) }
            guard start < end else { continue }
            let line = data[start..<end]
            if line.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) { continue }
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = row["type"] as? String else {
                malformedLines += 1
                continue
            }
            let payload = row["data"] as? [String: Any] ?? [:]

            if type == "session" {
                sessionID = (row["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionName
                projectPath = row["cwd"] as? String
                seedLength = Self.integer(row["seedLength"])
                waitingForSeedEnd = (row["isSeeded"] as? Bool == true) && seedLength == 0
                continue
            }
            if type == "turn/start" { sessionIsRunning = true; continue }
            if type == "turn/end" { sessionIsRunning = false; continue }
            if type == "request/context" {
                contextWindowTokens = Self.optionalInteger(payload["contextWindow"]).flatMap { $0 > 0 ? $0 : nil }
                contextUsedTokens = nil
                continue
            }
            if let chunk = payload["chunk"] as? [String: Any], chunk["type"] as? String == "usage",
               let usage = chunk["usage"] as? [String: Any] {
                let used = Self.integer(usage["inputTokens"]).addingReportingOverflow(Self.integer(usage["outputTokens"]))
                if !used.overflow, used.partialValue > 0 { contextUsedTokens = used.partialValue }
            }
            if type == "session/title" {
                sessionTitle = Self.nonEmpty(payload["title"] as? String) ?? sessionTitle
                continue
            }
            if type == "session/end-seed", (payload["inherited"] as? Bool) == true {
                waitingForSeedEnd = false
                continue
            }
            if type == "request/header" {
                let header = payload["header"] as? [String: Any] ?? [:]
                let config = header["config"] as? [String: Any] ?? [:]
                projectPath = header["cwd"] as? String ?? projectPath
                fallbackProvider = config["provider"] as? String ?? fallbackProvider
                fallbackModel = config["model"] as? String ?? fallbackModel
                continue
            }
            if type == "llm/retry-started" {
                let turn = Self.integer(payload["turn"])
                let step = Self.integer(payload["step"])
                if let previous = lastSettlement, previous.turn == turn, previous.step == step {
                    lastSettlement = nil
                }
                continue
            }
            guard type == "assistant/message" || type == "assistant/attempt" || type == "compaction/summary" else { continue }
            guard !waitingForSeedEnd else { continue }
            if seedLength > 0, let seq = Self.optionalInteger(row["seq"]), seq < seedLength { continue }
            guard let usage = Self.usage(in: payload, type: type),
                  let timestampMs = Self.optionalInteger(row["time"]), timestampMs > 0 else { continue }
            let totals = DSHTokenTotals(usage)
            guard totals.total > 0 else { continue }
            let source = (payload["message"] as? [String: Any])?["source"] as? [String: Any] ?? [:]
            let replayState = source["replayState"] as? [String: Any] ?? [:]
            let response = replayState["response"] as? [String: Any] ?? [:]
            let provider = source["provider"] as? String ?? fallbackProvider
            let model = Self.nonEmpty(response["responseModel"] as? String)
                ?? Self.nonEmpty(source["model"] as? String) ?? fallbackModel
            let identity = Self.identity(row: row, payload: payload, type: type, sessionID: sessionID,
                                         timestampMs: timestampMs, provider: provider, model: model, totals: totals)
            guard seen.insert(identity).inserted else { continue }
            let record = DSHUsageRecord(identity: identity,
                                        timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
                                        totals: totals, sessionID: sessionID, model: model,
                                        sessionTitle: sessionTitle, projectPath: projectPath,
                                        sessionIsRunning: sessionIsRunning, contextWindowTokens: contextWindowTokens,
                                        contextUsedTokens: contextUsedTokens)
            let turn = Self.optionalInteger(payload["turn"])
            let step = Self.optionalInteger(payload["step"])
            if type != "compaction/summary", let turn, let step {
                if let prior = lastSettlement, prior.turn == turn && prior.step == step {
                    records[prior.index] = record
                    continue
                }
                lastSettlement = (turn, step, records.count)
            } else if type != "compaction/summary" {
                lastSettlement = nil
            }
            records.append(record)
        }
        // Titles can be assigned after the first response; apply the persisted final title to the whole session.
        for index in records.indices {
            records[index].sessionIsRunning = sessionIsRunning
            records[index].contextWindowTokens = contextWindowTokens
            records[index].contextUsedTokens = contextUsedTokens
            records[index].sessionTitle = sessionTitle
            records[index].projectPath = records[index].projectPath ?? projectPath
        }
        return (records, malformedLines)
    }

    private static func usage(in payload: [String: Any], type: String) -> [String: Any]? {
        if type != "assistant/attempt", let usage = payload["usage"] as? [String: Any] { return usage }
        guard type != "compaction/summary", let stream = payload["stream"] as? [[String: Any]] else { return nil }
        for item in stream.reversed() where item["type"] as? String == "chunk" {
            guard let chunk = item["chunk"] as? [String: Any], chunk["type"] as? String == "usage" else { continue }
            return chunk["usage"] as? [String: Any]
        }
        return nil
    }

    private static func identity(row: [String: Any], payload: [String: Any], type: String,
                                 sessionID: String, timestampMs: Int, provider: String, model: String,
                                 totals: DSHTokenTotals) -> String {
        let message = payload["message"] as? [String: Any] ?? [:]
        let prefix: String
        if type == "assistant/attempt" {
            let attemptID = nonEmpty(payload["attemptId"] as? String) ?? nonEmpty(payload["retryId"] as? String)
            prefix = "attempt:" + (attemptID ?? "\(sessionID):\(Self.integer(row["seq"]))")
        } else if type == "compaction/summary" {
            let compactionID = nonEmpty(payload["compactionId"] as? String)
            prefix = "summary:" + (compactionID ?? "seq:\(Self.integer(row["seq"]))")
        } else {
            let messageID = nonEmpty(message["id"] as? String)
            prefix = "message:" + (messageID ?? "\(sessionID):\(Self.integer(row["seq"]))")
        }
        return "\(prefix):\(timestampMs):\(provider):\(model):\(totals.input):\(totals.output):\(totals.cacheRead):\(totals.cacheWrite)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    private static func optionalInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    private static func integer(_ value: Any?) -> Int { max(0, optionalInteger(value) ?? 0) }
}

nonisolated private struct DSHUsageRecord {
    let identity: String
    let timestamp: Date
    let totals: DSHTokenTotals
    let sessionID: String
    let model: String
    var sessionTitle: String?
    var projectPath: String?
    var sessionIsRunning: Bool?
    var contextWindowTokens: Int?
    var contextUsedTokens: Int?
}

nonisolated private struct DSHTokenTotals {
    static let zero = DSHTokenTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var total: Int { [input, output, cacheRead, cacheWrite].reduce(0, Self.sum) }

    init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    init(_ usage: [String: Any]) {
        self.init(input: Self.amount(usage["inputTokens"]),
                  output: Self.amount(usage["outputTokens"]),
                  cacheRead: Self.amount(usage["cacheReadTokens"]),
                  cacheWrite: Self.amount(usage["cacheWriteTokens"]))
        // reasoningTokens is already part of outputTokens.
    }

    mutating func add(_ other: DSHTokenTotals) {
        input = Self.sum(input, other.input)
        output = Self.sum(output, other.output)
        cacheRead = Self.sum(cacheRead, other.cacheRead)
        cacheWrite = Self.sum(cacheWrite, other.cacheWrite)
    }

    private static func amount(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue) else { return 0 }
        return max(0, integer)
    }

    private static func sum(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : value
    }
}

nonisolated private enum DSHReadError: Error {
    case tooLarge
    case decoderUnavailable
    case invalidCompressedData
}

/// Decode concatenated DSH frames with the bundled upstream zstd decompressor.
nonisolated private enum DSHSystemZstd {
    static func decode(_ compressed: Data, limit: Int) throws -> Data {
        guard let stream = dshZstdCreateStream() else { throw DSHReadError.decoderUnavailable }
        defer { _ = dshZstdFreeStream(stream) }
        guard dshZstdIsError(dshZstdInitStream(stream)) == 0 else { throw DSHReadError.decoderUnavailable }
        return try compressed.withUnsafeBytes { source in
            var input = DSHZstdInput(src: source.baseAddress, size: source.count, pos: 0)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 128 * 1024)
            var lastHint: UInt = 1
            var needsDrain = false
            while input.pos < input.size || needsDrain {
                let before = input.pos
                let remaining = limit - result.count
                let outputCapacity = min(buffer.count, remaining + 1)
                let (hint, produced) = buffer.withUnsafeMutableBytes { bytes -> (UInt, Int) in
                    var output = DSHZstdOutput(dst: bytes.baseAddress, size: outputCapacity, pos: 0)
                    let hint = dshZstdDecompress(stream, &output, &input)
                    return (hint, output.pos)
                }
                guard dshZstdIsError(hint) == 0 else { throw DSHReadError.invalidCompressedData }
                guard produced <= remaining else { throw DSHReadError.tooLarge }
                result.append(contentsOf: buffer.prefix(produced))
                if input.pos == before && produced == 0 {
                    guard input.pos == input.size else { throw DSHReadError.invalidCompressedData }
                    break // Incomplete final frame; a later scan will see the rest.
                }
                lastHint = hint
                needsDrain = input.pos == input.size && produced == outputCapacity && hint != 0
            }
            // A live session may end halfway through a newly appended frame.
            // Complete JSONL records in the decoded prefix remain usable.
            if lastHint != 0, result.isEmpty { throw DSHReadError.invalidCompressedData }
            return result
        }
    }
}

nonisolated private struct DSHZstdInput {
    var src: UnsafeRawPointer?
    var size: Int
    var pos: Int
}

nonisolated private struct DSHZstdOutput {
    var dst: UnsafeMutableRawPointer?
    var size: Int
    var pos: Int
}

@_silgen_name("ZSTD_createDStream")
nonisolated private func dshZstdCreateStream() -> UnsafeMutableRawPointer?
@_silgen_name("ZSTD_initDStream")
nonisolated private func dshZstdInitStream(_ stream: UnsafeMutableRawPointer?) -> UInt
@_silgen_name("ZSTD_decompressStream")
nonisolated private func dshZstdDecompress(_ stream: UnsafeMutableRawPointer?,
                               _ output: UnsafeMutablePointer<DSHZstdOutput>,
                               _ input: UnsafeMutablePointer<DSHZstdInput>) -> UInt
@_silgen_name("ZSTD_isError")
nonisolated private func dshZstdIsError(_ code: UInt) -> UInt32
@_silgen_name("ZSTD_freeDStream")
nonisolated private func dshZstdFreeStream(_ stream: UnsafeMutableRawPointer?) -> UInt
