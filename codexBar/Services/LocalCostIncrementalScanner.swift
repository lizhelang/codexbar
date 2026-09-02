import Foundation

struct LocalCostIncrementalScannerResult {
    let progress: LocalCostIndexProgress
    let bytesRead: Int64
    let parsedFiles: Int
}

struct LocalCostScanBudget {
    let maxBytes: Int64?
    let maxDuration: TimeInterval?

    static let unbounded = LocalCostScanBudget(maxBytes: nil, maxDuration: nil)
    static let interactive = LocalCostScanBudget(maxBytes: 64 * 1024 * 1024, maxDuration: 1.5)
    static let accelerated = LocalCostScanBudget(maxBytes: 512 * 1024 * 1024, maxDuration: 8)
}

final class LocalCostIncrementalScanner {
    typealias ProgressHandler = (LocalCostRefreshProgress) -> Void
    private struct FileMetadata {
        let path: String
        let fileIdentifier: String
        let size: Int64
        let modificationTime: Date
    }

    private struct ParserState: Codable, Equatable {
        var sessionID: String?
        var sessionDate: Date?
        var model: String?
        var usageHighWater: SessionLogStore.Usage?
        var currentForkUsageHighWater: SessionLogStore.Usage?
        var billableUsage: SessionLogStore.Usage
        var taskLifecycleState: SessionLogStore.TaskLifecycleState?
        var isForkedSubagent: Bool
        var parentSessionID: String?
        var currentTurnID: String?
        var currentServiceTier: SessionLogStore.ServiceTier
        var inheritedUsageBaseline: SessionLogStore.Usage?
        var didSeeSessionMetadata: Bool
        var hasEmbeddedReplayMetadata: Bool
        var didSkipForkReplayUsage: Bool
        var didStartForkTask: Bool
        var didEncounterInvalidUsageSample: Bool
        var emittedEventCount: Int
        var isSkippingIrrelevantLine: Bool?
        var pendingSubagentEvents: [LocalCostIndexedEvent]

        static let empty = ParserState(
            sessionID: nil,
            sessionDate: nil,
            model: nil,
            usageHighWater: nil,
            currentForkUsageHighWater: nil,
            billableUsage: .zero,
            taskLifecycleState: nil,
            isForkedSubagent: false,
            parentSessionID: nil,
            currentTurnID: nil,
            currentServiceTier: .unknown,
            inheritedUsageBaseline: nil,
            didSeeSessionMetadata: false,
            hasEmbeddedReplayMetadata: false,
            didSkipForkReplayUsage: false,
            didStartForkTask: false,
            didEncounterInvalidUsageSample: false,
            emittedEventCount: 0,
            isSkippingIrrelevantLine: nil,
            pendingSubagentEvents: []
        )
    }

    private struct UsageSample {
        let timestamp: Date?
        let totalUsage: SessionLogStore.Usage
        let incrementalUsage: SessionLogStore.Usage?
        let modelID: String?
        let turnID: String?
        let serviceTier: SessionLogStore.ServiceTier
    }

    private struct SessionStartInfo {
        let parentSessionID: String?
        let isSubagent: Bool
    }

    private struct LineScanResult {
        let parsedBytes: Int64
        let anchorHash: String
        let parserState: ParserState
        let events: [LocalCostIndexedEvent]
        let bytesRead: Int64
        let isComplete: Bool
        let didHitBudget: Bool
        let replaceExistingEvents: Bool
    }

    private let codexRootURL: URL
    private let store: LocalCostIndexStore
    private let fileManager: FileManager
    private let stateEncoder = JSONEncoder()
    private let stateDecoder = JSONDecoder()

    init(
        codexRootURL: URL = CodexPaths.codexRoot,
        store: LocalCostIndexStore,
        fileManager: FileManager = .default
    ) {
        self.codexRootURL = codexRootURL
        self.store = store
        self.fileManager = fileManager
        self.stateEncoder.dateEncodingStrategy = .iso8601
        self.stateDecoder.dateDecodingStrategy = .iso8601
    }

    func scan(
        budget: LocalCostScanBudget = .unbounded,
        forceRebuild: Bool = false,
        progressHandler: ProgressHandler? = nil
    ) throws -> LocalCostIncrementalScannerResult {
        let files = try self.sessionFiles()
        let existingProgress = (try? self.store.progress()) ?? .idle
        let startedAt = Date()
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        var processedBytes: Int64 = 0
        var completedFiles = 0
        var bytesRead: Int64 = 0
        var parsedFiles = 0
        var latestUsageEventAt: Date?
        var hadIncompleteFile = false

        try self.store.updateProgress(
            LocalCostIndexProgress(
                state: .scanning,
                processedBytes: 0,
                totalBytes: totalBytes,
                completedFiles: 0,
                totalFiles: files.count,
                lastSuccessfulScanAt: existingProgress.lastSuccessfulScanAt,
                latestUsageEventAt: existingProgress.latestUsageEventAt,
                errorMessage: nil
            )
        )

        do {
            for metadata in files {
                let indexed = forceRebuild ? nil : try self.store.indexedFile(path: metadata.path)
                if let indexed,
                   indexed.fileIdentifier == metadata.fileIdentifier,
                   indexed.size == metadata.size,
                   indexed.modificationTime == metadata.modificationTime,
                   indexed.isComplete {
                    processedBytes += metadata.size
                    completedFiles += 1
                    if completedFiles.isMultiple(of: 32) || completedFiles == files.count {
                        progressHandler?(
                            LocalCostRefreshProgress(
                                processedBytes: processedBytes,
                                totalBytes: totalBytes,
                                completedFiles: completedFiles,
                                totalFiles: files.count
                            )
                        )
                    }
                    continue
                }

                let replace = self.shouldReplaceExistingIndex(indexed: indexed, metadata: metadata)
                let startOffset = replace ? 0 : (indexed?.parsedBytes ?? 0)
                let startState = replace
                    ? ParserState.empty
                    : self.decodeState(indexed?.parserStateData) ?? .empty
                if replace == false,
                   let indexed,
                   self.anchorHash(path: metadata.path, parsedBytes: indexed.parsedBytes) != indexed.anchorHash {
                    let lineResult = try self.rebuild(
                        metadata: metadata,
                        budget: budget,
                        startedAt: startedAt,
                        priorBytesRead: bytesRead
                    )
                    bytesRead += lineResult.bytesRead
                    parsedFiles += 1
                    latestUsageEventAt = self.latest(latestUsageEventAt, lineResult.events.map(\.timestamp).max())
                    if lineResult.isComplete == false {
                        hadIncompleteFile = true
                    }
                    processedBytes += lineResult.isComplete ? metadata.size : lineResult.parsedBytes
                    completedFiles += lineResult.isComplete ? 1 : 0
                    if lineResult.didHitBudget || completedFiles.isMultiple(of: 16) || completedFiles == files.count {
                        progressHandler?(
                            LocalCostRefreshProgress(
                                processedBytes: processedBytes,
                                totalBytes: totalBytes,
                                completedFiles: completedFiles,
                                totalFiles: files.count
                            )
                        )
                    }
                    if lineResult.didHitBudget || self.isBudgetExhausted(budget: budget, startedAt: startedAt, bytesRead: bytesRead),
                       completedFiles < files.count {
                        let progress = LocalCostIndexProgress(
                            state: .partial,
                            processedBytes: processedBytes,
                            totalBytes: totalBytes,
                            completedFiles: completedFiles,
                            totalFiles: files.count,
                            lastSuccessfulScanAt: existingProgress.lastSuccessfulScanAt,
                            latestUsageEventAt: self.latest(existingProgress.latestUsageEventAt, latestUsageEventAt),
                            errorMessage: nil
                        )
                        try self.store.updateProgress(progress)
                        return LocalCostIncrementalScannerResult(
                            progress: progress,
                            bytesRead: bytesRead,
                            parsedFiles: parsedFiles
                        )
                    }
                    continue
                }

                let lineResult = try self.scanLines(
                    metadata: metadata,
                    startOffset: startOffset,
                    initialState: startState,
                    budget: budget,
                    startedAt: startedAt,
                    priorBytesRead: bytesRead
                )
                bytesRead += lineResult.bytesRead
                parsedFiles += 1
                latestUsageEventAt = self.latest(latestUsageEventAt, lineResult.events.map(\.timestamp).max())
                if lineResult.isComplete == false {
                    hadIncompleteFile = true
                }
                try self.store.commitFileScan(
                    LocalCostFileScanCommit(
                        path: metadata.path,
                        fileIdentifier: metadata.fileIdentifier,
                        size: metadata.size,
                        modificationTime: metadata.modificationTime,
                        parsedBytes: lineResult.parsedBytes,
                        anchorHash: lineResult.anchorHash,
                        parserStateData: try self.stateEncoder.encode(lineResult.parserState),
                        isComplete: lineResult.isComplete,
                        replaceExistingEvents: replace || lineResult.replaceExistingEvents,
                        events: lineResult.events
                    )
                )
                processedBytes += lineResult.isComplete ? metadata.size : lineResult.parsedBytes
                completedFiles += lineResult.isComplete ? 1 : 0
                if lineResult.didHitBudget || completedFiles.isMultiple(of: 16) || completedFiles == files.count {
                    progressHandler?(
                        LocalCostRefreshProgress(
                            processedBytes: processedBytes,
                            totalBytes: totalBytes,
                            completedFiles: completedFiles,
                            totalFiles: files.count
                        )
                    )
                }
                if lineResult.didHitBudget || self.isBudgetExhausted(budget: budget, startedAt: startedAt, bytesRead: bytesRead),
                   completedFiles < files.count {
                    let progress = LocalCostIndexProgress(
                        state: .partial,
                        processedBytes: processedBytes,
                        totalBytes: totalBytes,
                        completedFiles: completedFiles,
                        totalFiles: files.count,
                        lastSuccessfulScanAt: existingProgress.lastSuccessfulScanAt,
                        latestUsageEventAt: self.latest(existingProgress.latestUsageEventAt, latestUsageEventAt),
                        errorMessage: nil
                    )
                    try self.store.updateProgress(progress)
                    return LocalCostIncrementalScannerResult(
                        progress: progress,
                        bytesRead: bytesRead,
                        parsedFiles: parsedFiles
                    )
                }
            }

            let progress = LocalCostIndexProgress(
                state: hadIncompleteFile ? .partial : .idle,
                processedBytes: hadIncompleteFile ? processedBytes : totalBytes,
                totalBytes: totalBytes,
                completedFiles: completedFiles,
                totalFiles: files.count,
                lastSuccessfulScanAt: hadIncompleteFile ? existingProgress.lastSuccessfulScanAt : Date(),
                latestUsageEventAt: self.latest(existingProgress.latestUsageEventAt, latestUsageEventAt),
                errorMessage: nil
            )
            try self.store.updateProgress(progress)
            return LocalCostIncrementalScannerResult(
                progress: progress,
                bytesRead: bytesRead,
                parsedFiles: parsedFiles
            )
        } catch {
            let progress = LocalCostIndexProgress(
                state: .failed,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                completedFiles: completedFiles,
                totalFiles: files.count,
                lastSuccessfulScanAt: existingProgress.lastSuccessfulScanAt,
                latestUsageEventAt: self.latest(existingProgress.latestUsageEventAt, latestUsageEventAt),
                errorMessage: error.localizedDescription
            )
            try? self.store.updateProgress(progress)
            throw error
        }
    }

    private func isBudgetExhausted(
        budget: LocalCostScanBudget,
        startedAt: Date,
        bytesRead: Int64
    ) -> Bool {
        if let maxBytes = budget.maxBytes, bytesRead >= maxBytes {
            return true
        }
        if let maxDuration = budget.maxDuration,
           Date().timeIntervalSince(startedAt) >= maxDuration {
            return true
        }
        return false
    }

    private func rebuild(
        metadata: FileMetadata,
        budget: LocalCostScanBudget,
        startedAt: Date,
        priorBytesRead: Int64
    ) throws -> LineScanResult {
        let lineResult = try self.scanLines(
            metadata: metadata,
            startOffset: 0,
            initialState: .empty,
            budget: budget,
            startedAt: startedAt,
            priorBytesRead: priorBytesRead
        )
        try self.store.commitFileScan(
            LocalCostFileScanCommit(
                path: metadata.path,
                fileIdentifier: metadata.fileIdentifier,
                size: metadata.size,
                modificationTime: metadata.modificationTime,
                parsedBytes: lineResult.parsedBytes,
                anchorHash: lineResult.anchorHash,
                parserStateData: try self.stateEncoder.encode(lineResult.parserState),
                isComplete: lineResult.isComplete,
                replaceExistingEvents: true,
                events: lineResult.events
            )
        )
        return lineResult
    }

    private func shouldReplaceExistingIndex(indexed: LocalCostIndexedFile?, metadata: FileMetadata) -> Bool {
        guard let indexed else { return true }
        return indexed.fileIdentifier != metadata.fileIdentifier ||
            (metadata.size == indexed.size && metadata.modificationTime != indexed.modificationTime) ||
            metadata.size < indexed.parsedBytes ||
            indexed.parsedBytes > metadata.size
    }

    private func decodeState(_ data: Data?) -> ParserState? {
        guard let data else { return nil }
        return try? self.stateDecoder.decode(ParserState.self, from: data)
    }

    private func sessionFiles() throws -> [FileMetadata] {
        // Deliberately do not sweep indexed paths that disappeared from disk. The
        // cost index is the durable Lifetime ledger, so user/Codex log cleanup must
        // not erase already-accounted usage. Active-to-archived moves remain safe
        // because the logical event key deduplicates the copied rollout.
        let directories = [
            self.codexRootURL.appendingPathComponent("sessions", isDirectory: true),
            self.codexRootURL.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        var files: [FileMetadata] = []
        for directory in directories {
            guard self.fileManager.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = self.fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl",
                      let metadata = self.metadata(for: url) else { continue }
                files.append(metadata)
            }
        }
        return files.sorted { lhs, rhs in
            if lhs.modificationTime != rhs.modificationTime {
                return lhs.modificationTime > rhs.modificationTime
            }
            return lhs.path < rhs.path
        }
    }

    private func metadata(for url: URL) -> FileMetadata? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey,
        ]),
        values.isRegularFile == true else { return nil }

        let modificationDate = values.contentModificationDate ?? .distantPast
        let normalizedModificationTime = (
            modificationDate.timeIntervalSince1970 * 1_000
        ).rounded() / 1_000
        return FileMetadata(
            path: url.standardizedFileURL.path,
            fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) } ?? url.standardizedFileURL.path,
            size: Int64(values.fileSize ?? 0),
            modificationTime: Date(timeIntervalSince1970: normalizedModificationTime)
        )
    }

    private func scanLines(
        metadata: FileMetadata,
        startOffset: Int64,
        initialState: ParserState,
        budget: LocalCostScanBudget,
        startedAt: Date,
        priorBytesRead: Int64
    ) throws -> LineScanResult {
        let url = URL(fileURLWithPath: metadata.path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, startOffset)))

        var state = initialState
        var events: [LocalCostIndexedEvent] = []
        var buffer = Data()
        var offset = startOffset
        var bytesRead: Int64 = 0
        var isSkippingIrrelevantLine = state.isSkippingIrrelevantLine == true
        var replaceExistingEvents = false

        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            if isSkippingIrrelevantLine {
                if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                    offset += Int64(newlineIndex) + 1
                    isSkippingIrrelevantLine = false
                    state.isSkippingIrrelevantLine = nil
                    buffer.append(chunk[chunk.index(after: newlineIndex)...])
                } else {
                    offset += Int64(chunk.count)
                    state.isSkippingIrrelevantLine = true
                    if self.isBudgetExhausted(
                        budget: budget,
                        startedAt: startedAt,
                        bytesRead: priorBytesRead + bytesRead
                    ) {
                        return LineScanResult(
                            parsedBytes: offset,
                            anchorHash: self.anchorHash(path: metadata.path, parsedBytes: offset),
                            parserState: state,
                            events: events,
                            bytesRead: bytesRead,
                            isComplete: false,
                            didHitBudget: true,
                            replaceExistingEvents: replaceExistingEvents
                        )
                    }
                    continue
                }
            } else {
                buffer.append(chunk)
            }

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                let lineByteCount = lineData.count + 1
                if self.shouldInspectLine(lineData),
                   let line = String(data: lineData, encoding: .utf8) {
                    self.consume(
                        line: line,
                        metadata: metadata,
                        state: &state,
                        events: &events,
                        replaceExistingEvents: &replaceExistingEvents
                    )
                } else if self.shouldInspectLine(lineData) {
                    state.didEncounterInvalidUsageSample = true
                }
                buffer.removeSubrange(...newlineIndex)
                offset += Int64(lineByteCount)
                if self.isBudgetExhausted(
                    budget: budget,
                    startedAt: startedAt,
                    bytesRead: priorBytesRead + bytesRead
                ) {
                    return LineScanResult(
                        parsedBytes: offset,
                        anchorHash: self.anchorHash(path: metadata.path, parsedBytes: offset),
                        parserState: state,
                        events: events,
                        bytesRead: bytesRead,
                        isComplete: false,
                        didHitBudget: true,
                        replaceExistingEvents: replaceExistingEvents
                    )
                }
            }

            if buffer.count > 4096,
               self.shouldInspectLine(buffer.prefix(4096)) == false {
                offset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                isSkippingIrrelevantLine = true
                state.isSkippingIrrelevantLine = true
                if self.isBudgetExhausted(
                    budget: budget,
                    startedAt: startedAt,
                    bytesRead: priorBytesRead + bytesRead
                ) {
                    return LineScanResult(
                        parsedBytes: offset,
                        anchorHash: self.anchorHash(path: metadata.path, parsedBytes: offset),
                        parserState: state,
                        events: events,
                        bytesRead: bytesRead,
                        isComplete: false,
                        didHitBudget: true,
                        replaceExistingEvents: replaceExistingEvents
                    )
                }
            }
        }

        if isSkippingIrrelevantLine {
            state.isSkippingIrrelevantLine = nil
        }
        if state.isForkedSubagent, state.hasEmbeddedReplayMetadata == false {
            events.append(contentsOf: state.pendingSubagentEvents)
        }
        return LineScanResult(
            parsedBytes: offset,
            anchorHash: self.anchorHash(path: metadata.path, parsedBytes: offset),
            parserState: state,
            events: events,
            bytesRead: bytesRead,
            // Reaching EOF means every complete JSONL record is indexed. Keep an
            // unterminated tail behind parsedBytes so a later append can finish it,
            // without making the whole history catch-up spin forever meanwhile.
            isComplete: true,
            didHitBudget: false,
            replaceExistingEvents: replaceExistingEvents
        )
    }

    private func consume(
        line: String,
        metadata: FileMetadata,
        state: inout ParserState,
        events: inout [LocalCostIndexedEvent],
        replaceExistingEvents: inout Bool
    ) {
        guard line.isEmpty == false else { return }

        if let startInfo = self.parseSessionStartInfo(from: line) {
            if state.didSeeSessionMetadata, state.isForkedSubagent {
                state.hasEmbeddedReplayMetadata = true
                state.didStartForkTask = false
                state.currentForkUsageHighWater = nil
                state.billableUsage = .zero
                events.removeAll(keepingCapacity: true)
                state.pendingSubagentEvents.removeAll(keepingCapacity: true)
                replaceExistingEvents = true
            }
            state.didSeeSessionMetadata = true
            state.parentSessionID = state.parentSessionID ?? startInfo.parentSessionID
            if startInfo.isSubagent {
                state.isForkedSubagent = true
            }
        }

        self.consumeSessionMetadata(in: line, sessionID: &state.sessionID, sessionDate: &state.sessionDate)
        self.consumeTurnContext(in: line, model: &state.model, serviceTier: &state.currentServiceTier)
        self.consumeThreadSettings(in: line, model: &state.model, serviceTier: &state.currentServiceTier)
        self.consumeTaskLifecycle(in: line, taskLifecycleState: &state.taskLifecycleState)
        self.consumeTurnIdentifier(in: line, turnID: &state.currentTurnID)

        if state.isForkedSubagent,
           state.hasEmbeddedReplayMetadata,
           self.isSubagentExecutionMarker(line) {
            state.didStartForkTask = true
        } else if state.taskLifecycleState == .running,
                  state.hasEmbeddedReplayMetadata == false {
            state.didStartForkTask = true
        }

        let isCurrentForkTask = state.isForkedSubagent == false || state.didStartForkTask
        let isUsageSampleCandidate = self.isUsageSampleCandidate(line)
        guard let sample = self.parseUsageSample(from: line) else {
            if isUsageSampleCandidate {
                state.didEncounterInvalidUsageSample = true
            }
            return
        }

        let incrementalUsage: SessionLogStore.Usage
        if isCurrentForkTask {
            if state.isForkedSubagent, state.didSkipForkReplayUsage {
                incrementalUsage = self.forkedTaskIncrementalUsage(
                    sample: sample,
                    inheritedUsageHighWater: state.usageHighWater,
                    currentForkUsageHighWater: state.currentForkUsageHighWater
                )
                state.currentForkUsageHighWater = state.currentForkUsageHighWater
                    .map { $0.highWater(with: sample.totalUsage) }
                    ?? sample.totalUsage
            } else if let usageHighWater = state.usageHighWater {
                incrementalUsage = sample.totalUsage.delta(from: usageHighWater)
            } else if let reportedIncrement = sample.incrementalUsage {
                incrementalUsage = reportedIncrement
                if state.parentSessionID != nil,
                   state.isForkedSubagent == false,
                   state.inheritedUsageBaseline == nil {
                    state.inheritedUsageBaseline = sample.totalUsage.delta(from: reportedIncrement)
                }
            } else if state.parentSessionID != nil, state.isForkedSubagent == false {
                if let inheritedUsageBaseline = state.inheritedUsageBaseline {
                    incrementalUsage = sample.totalUsage.delta(from: inheritedUsageBaseline)
                } else {
                    state.didEncounterInvalidUsageSample = true
                    incrementalUsage = .zero
                }
            } else {
                incrementalUsage = sample.totalUsage
            }
        } else {
            incrementalUsage = .zero
            state.didSkipForkReplayUsage = true
        }

        let eventTimestamp = sample.timestamp
            ?? metadata.modificationTime.addingTimeInterval(Double(state.emittedEventCount) / 1_000)
        if incrementalUsage.isZero == false,
           let model = sample.modelID ?? state.model,
           let sessionDate = state.sessionDate {
            let sessionID = state.sessionID ?? URL(fileURLWithPath: metadata.path).deletingPathExtension().lastPathComponent
            let eventTier = sample.serviceTier == .unknown ? state.currentServiceTier : sample.serviceTier
            let eventSource: SessionLogStore.EventSource = if state.isForkedSubagent {
                .subagent
            } else if state.parentSessionID != nil {
                .fork
            } else {
                .nativeSession
            }
            let event = LocalCostIndexedEvent(
                eventKey: self.eventKey(
                    sessionID: sessionID,
                    timestamp: eventTimestamp,
                    usage: incrementalUsage,
                    model: model,
                    turnID: sample.turnID ?? state.currentTurnID,
                    serviceTier: eventTier,
                    source: eventSource,
                    eventOrdinal: state.emittedEventCount
                ),
                path: metadata.path,
                sessionID: sessionID,
                timestamp: max(eventTimestamp, sessionDate.addingTimeInterval(-1)),
                model: model,
                turnID: sample.turnID ?? state.currentTurnID,
                serviceTier: eventTier,
                source: eventSource,
                usage: incrementalUsage
            )
            if state.isForkedSubagent, state.hasEmbeddedReplayMetadata == false {
                state.pendingSubagentEvents.append(event)
            } else {
                events.append(event)
            }
            state.billableUsage = state.billableUsage + incrementalUsage
            state.emittedEventCount += 1
        }
        state.usageHighWater = state.usageHighWater.map { $0.highWater(with: sample.totalUsage) } ?? sample.totalUsage
    }

    private func shouldInspectLine(_ data: Data.SubSequence) -> Bool {
        let prefix = data.prefix(4096)
        if self.contains(prefix, needle: #"response_item"#) {
            return false
        }
        return self.contains(prefix, needle: #"session_meta"#) ||
            self.contains(prefix, needle: #"turn_context"#) ||
            self.contains(prefix, needle: #"thread_settings_applied"#) ||
            self.contains(prefix, needle: #"task_"#) ||
            self.contains(prefix, needle: #"token_count"#) ||
            self.contains(prefix, needle: #"inter_agent_communication_metadata"#)
    }

    private func contains(_ data: Data.SubSequence, needle: String) -> Bool {
        let needleBytes = Array(needle.utf8)
        guard needleBytes.isEmpty == false,
              data.count >= needleBytes.count else {
            return false
        }

        var matched = 0
        for byte in data {
            if byte == needleBytes[matched] {
                matched += 1
                if matched == needleBytes.count {
                    return true
                }
            } else {
                matched = byte == needleBytes[0] ? 1 : 0
            }
        }
        return false
    }

    private func eventKey(
        sessionID: String,
        timestamp: Date,
        usage: SessionLogStore.Usage,
        model: String,
        turnID: String?,
        serviceTier: SessionLogStore.ServiceTier,
        source: SessionLogStore.EventSource,
        eventOrdinal: Int
    ) -> String {
        [
            sessionID,
            ISO8601DateFormatter().string(from: timestamp),
            String(usage.inputTokens),
            String(usage.cachedInputTokens),
            String(usage.outputTokens),
            model,
            turnID ?? "",
            serviceTier.rawValue,
            source.rawValue,
            String(eventOrdinal),
        ].joined(separator: "|")
    }

    private func anchorHash(path: String, parsedBytes: Int64) -> String {
        guard parsedBytes > 0,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return "empty"
        }
        defer { try? handle.close() }
        let length = min(Int64(128), parsedBytes)
        do {
            try handle.seek(toOffset: UInt64(parsedBytes - length))
            let data = try handle.read(upToCount: Int(length)) ?? Data()
            return Self.hash(data)
        } catch {
            return "unreadable"
        }
    }

    private static func hash(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
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

    private func consumeTurnContext(
        in line: String,
        model: inout String?,
        serviceTier: inout SessionLogStore.ServiceTier
    ) {
        guard line.contains("\"type\":\"turn_context\"") else { return }

        if let payload = self.parsePayload(from: line) {
            let info = payload["info"] as? [String: Any]
            if let currentModel = payload["model"] as? String
                ?? payload["model_name"] as? String
                ?? info?["model"] as? String
                ?? info?["model_name"] as? String
            {
                model = self.normalizeModel(currentModel)
            }
            let parsedTier = SessionLogStore.ServiceTier.parse(
                payload["service_tier"] as? String
                    ?? info?["service_tier"] as? String
            )
            if parsedTier != .unknown {
                serviceTier = parsedTier
            }
            return
        }

        if let payload = self.payloadSlice(in: line),
           let currentModel = self.extractString("model", in: payload) {
            model = self.normalizeModel(currentModel)
        }
    }

    private func consumeTurnIdentifier(in line: String, turnID: inout String?) {
        guard line.contains("\"type\":\"event_msg\""),
              line.contains("\"task_started\""),
              let payload = self.parsePayload(from: line),
              payload["type"] as? String == "task_started" else {
            return
        }
        turnID = payload["turn_id"] as? String
            ?? payload["turnId"] as? String
            ?? payload["id"] as? String
    }

    private func consumeThreadSettings(
        in line: String,
        model: inout String?,
        serviceTier: inout SessionLogStore.ServiceTier
    ) {
        guard line.contains("\"type\":\"event_msg\""),
              line.contains("\"thread_settings_applied\""),
              let payload = self.parsePayload(from: line),
              payload["type"] as? String == "thread_settings_applied" else {
            return
        }
        let settings = payload["thread_settings"] as? [String: Any]
            ?? payload["threadSettings"] as? [String: Any]
        if let settingsModel = settings?["model"] as? String
            ?? settings?["model_name"] as? String {
            model = self.normalizeModel(settingsModel)
        }
        let parsedTier = SessionLogStore.ServiceTier.parse(
            settings?["service_tier"] as? String
                ?? settings?["serviceTier"] as? String
                ?? payload["service_tier"] as? String
        )
        if parsedTier != .unknown {
            serviceTier = parsedTier
        }
    }

    private func consumeTaskLifecycle(
        in line: String,
        taskLifecycleState: inout SessionLogStore.TaskLifecycleState?
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

    private func forkedTaskIncrementalUsage(
        sample: UsageSample,
        inheritedUsageHighWater: SessionLogStore.Usage?,
        currentForkUsageHighWater: SessionLogStore.Usage?
    ) -> SessionLogStore.Usage {
        if let currentForkUsageHighWater {
            return sample.totalUsage.delta(from: currentForkUsageHighWater)
        }

        if let inheritedUsageHighWater {
            if sample.totalUsage == inheritedUsageHighWater {
                return .zero
            }

            let inheritedDelta = sample.totalUsage.delta(from: inheritedUsageHighWater)
            if inheritedDelta.isZero == false {
                return inheritedDelta
            }
        }

        return sample.incrementalUsage ?? sample.totalUsage
    }

    private func parseSessionStartInfo(from line: String) -> SessionStartInfo? {
        guard line.contains("session_meta"),
              let jsonData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        let payload = object["payload"] as? [String: Any]
        let metadata: [String: Any]?
        if object["type"] as? String == "session_meta" {
            metadata = payload ?? object
        } else if payload?["type"] as? String == "session_meta" {
            metadata = payload
        } else {
            metadata = nil
        }

        guard let metadata else { return nil }
        return SessionStartInfo(
            parentSessionID: metadata["forked_from_id"] as? String
                ?? metadata["forkedFromId"] as? String
                ?? metadata["parent_session_id"] as? String
                ?? metadata["parentSessionId"] as? String,
            isSubagent: self.isSubagentSource(metadata["source"]) ||
                self.isSubagentSource(metadata["thread_source"])
        )
    }

    private func isSubagentSource(_ value: Any?) -> Bool {
        if let source = value as? String {
            return source.contains("subagent")
        }
        if let source = value as? [String: Any] {
            return source["subagent"] != nil
        }
        return false
    }

    private func isSubagentExecutionMarker(_ line: String) -> Bool {
        guard line.contains("inter_agent_communication_metadata"),
              let jsonData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return false
        }
        return object["type"] as? String == "inter_agent_communication_metadata"
    }

    private func parseUsageSample(from line: String) -> UsageSample? {
        guard self.isUsageSampleCandidate(line) else { return nil }
        guard let jsonData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }

        let timestamp = (object["timestamp"] as? String).flatMap(ISO8601Parsing.parse(_:))

        if let payloadType = payload["type"] as? String, payloadType == "event_msg",
           let total = payload["total_token_usage"] as? [String: Any] {
            return UsageSample(
                timestamp: timestamp,
                totalUsage: self.parseUsageDictionary(total),
                incrementalUsage: (payload["last_token_usage"] as? [String: Any]).map(self.parseUsageDictionary),
                modelID: self.normalizedModel(payload["model"] as? String ?? payload["model_name"] as? String),
                turnID: payload["turn_id"] as? String ?? payload["turnId"] as? String ?? payload["id"] as? String,
                serviceTier: SessionLogStore.ServiceTier.parse(payload["service_tier"] as? String)
            )
        }

        guard let payloadType = payload["type"] as? String,
              payloadType == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return nil }

        return UsageSample(
            timestamp: timestamp,
            totalUsage: self.parseUsageDictionary(total),
            incrementalUsage: (info["last_token_usage"] as? [String: Any]).map(self.parseUsageDictionary),
            modelID: self.normalizedModel(
                info["model"] as? String
                    ?? info["model_name"] as? String
                    ?? payload["model"] as? String
                    ?? payload["model_name"] as? String
            ),
            turnID: payload["turn_id"] as? String
                ?? payload["turnId"] as? String
                ?? payload["id"] as? String
                ?? info["turn_id"] as? String
                ?? info["turnId"] as? String,
            serviceTier: SessionLogStore.ServiceTier.parse(
                info["service_tier"] as? String
                    ?? payload["service_tier"] as? String
            )
        )
    }

    private func isUsageSampleCandidate(_ line: String) -> Bool {
        line.contains("\"type\":\"event_msg\"") &&
            line.contains("\"token_count\"") &&
            line.contains("\"total_token_usage\"")
    }

    private func parseUsageDictionary(_ dictionary: [String: Any]) -> SessionLogStore.Usage {
        SessionLogStore.Usage(
            inputTokens: self.integerValue(dictionary["input_tokens"] ?? dictionary["inputTokens"]),
            cachedInputTokens: self.integerValue(dictionary["cached_input_tokens"] ?? dictionary["cachedInputTokens"]),
            outputTokens: self.integerValue(dictionary["output_tokens"] ?? dictionary["outputTokens"])
        )
    }

    private func integerValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func parsePayload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["payload"] as? [String: Any]
    }

    private func payloadSlice(in line: String) -> Substring? {
        guard let payloadRange = line.range(of: #""payload":"#, options: .regularExpression) else {
            return nil
        }
        return line[payloadRange.upperBound...]
    }

    private func extractString(_ key: String, in text: Substring) -> String? {
        let pattern = #""\#(key)"\s*:\s*"([^"]+)""#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        guard let separator = match.firstIndex(of: ":") else { return nil }
        return match[match.index(after: separator)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    private func normalizedModel(_ model: String?) -> String? {
        guard let model else { return nil }
        let normalized = self.normalizeModel(model)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizeModel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
