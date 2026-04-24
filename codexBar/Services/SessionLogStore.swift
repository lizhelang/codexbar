import Foundation

final class SessionLogStore: @unchecked Sendable, RecordsSourceSnapshotLoading {
    static let shared = SessionLogStore()

    enum TaskLifecycleState: String, Codable, Equatable {
        case running
        case completed
    }

    struct Usage: Codable, Equatable, Hashable {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int

        nonisolated static let zero = Usage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)

        nonisolated var totalTokens: Int {
            self.inputTokens + self.cachedInputTokens + self.outputTokens
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

        nonisolated func highWater(with other: Usage) -> Usage {
            Usage(
                inputTokens: max(self.inputTokens, other.inputTokens),
                cachedInputTokens: max(self.cachedInputTokens, other.cachedInputTokens),
                outputTokens: max(self.outputTokens, other.outputTokens)
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

    struct SessionLifecycleRecord: Codable, Equatable {
        let id: String
        let startedAt: Date
        let lastActivityAt: Date
        let isArchived: Bool
        let taskLifecycleState: TaskLifecycleState?
    }

    struct UsageEvent: Codable, Equatable {
        let timestamp: Date
        let usage: Usage
    }

    struct BillableUsageEvent: Codable, Equatable {
        let sessionID: String
        let model: String
        let sessionUsage: Usage
        let timestamp: Date
        let usage: Usage
        let costUSD: Double
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

    private struct CachedSessionLifecycleRecord: Codable {
        let fingerprint: FileFingerprint
        let record: SessionLifecycleRecord?
    }

    private struct RefreshedCachedSessions {
        let records: [CachedSessionRecord]
        let warnings: [RecordsSnapshotWarning]
    }

    private struct SessionFileScanResult {
        let files: [URL]
        let warnings: [RecordsSnapshotWarning]
    }

    private struct ParsedSessionResult {
        let cachedRecord: CachedSessionRecord
        let warning: RecordsSnapshotWarning?
    }

    private struct PersistedLedgerEvent: Codable, Equatable {
        let timestamp: Date
        let usage: Usage
        let costUSD: Double
    }

    private struct PersistedLedgerSession: Codable, Equatable {
        var model: String
        var events: [PersistedLedgerEvent]

        enum CodingKeys: String, CodingKey {
            case model
            case events
        }

        init(model: String = "", events: [PersistedLedgerEvent]) {
            self.model = model
            self.events = events
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
            self.events = try container.decode([PersistedLedgerEvent].self, forKey: .events)
        }
    }

    private struct PersistedUsageLedger: Codable, Equatable {
        var version: Int
        var didSeedFromSessionCache: Bool
        var sessions: [String: PersistedLedgerSession]

        static func empty(version: Int, didSeedFromSessionCache: Bool = false) -> PersistedUsageLedger {
            PersistedUsageLedger(
                version: version,
                didSeedFromSessionCache: didSeedFromSessionCache,
                sessions: [:]
            )
        }
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
    private let persistedUsageLedgerURL: URL
    private let billableCostCalculator: (String, Usage, Usage) -> Double?
    private let queue = DispatchQueue(label: "lzl.codexbar.session-log-store", qos: .utility)
    private let persistedCacheVersion = 4
    private let persistedUsageLedgerVersion = 2

    private var sessionCache: [URL: CachedSessionRecord] = [:]
    private var sessionLifecycleCache: [URL: CachedSessionLifecycleRecord] = [:]
    private var seedSessionCache: [URL: CachedSessionRecord]?
    private var usageLedger = PersistedUsageLedger.empty(version: 2)

    init(
        fileManager: FileManager = .default,
        codexRootURL: URL = CodexPaths.codexRoot,
        persistedCacheURL: URL = CodexPaths.costSessionCacheURL,
        persistedUsageLedgerURL: URL? = nil,
        billableCostCalculator: @escaping (String, Usage, Usage) -> Double? = { model, usage, sessionUsage in
            LocalCostPricing.costUSD(model: model, usage: usage, sessionUsage: sessionUsage)
        }
    ) {
        self.fileManager = fileManager
        self.codexRootURL = codexRootURL
        self.persistedCacheURL = persistedCacheURL
        self.persistedUsageLedgerURL = persistedUsageLedgerURL
            ?? persistedCacheURL.deletingLastPathComponent().appendingPathComponent("cost-event-ledger.json")
        self.billableCostCalculator = billableCostCalculator

        let loadedSessionCache = self.loadPersistedCache()
        self.sessionCache = loadedSessionCache
        self.seedSessionCache = loadedSessionCache
        self.usageLedger = self.loadPersistedUsageLedger()

        let currentSessions = self.refreshCachedSessionsLocked()
        _ = self.projectSessionUsageLedgerLocked(using: currentSessions)
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

    func currentSessionLifecycleRecords(
        matchingSessionIDs: Set<String>? = nil
    ) -> [SessionLifecycleRecord] {
        guard matchingSessionIDs?.isEmpty != true else { return [] }

        return self.reduceSessionLifecycle(
            into: [SessionLifecycleRecord](),
            matchingSessionIDs: matchingSessionIDs
        ) { result, record in
            result.append(record)
        }
        .filter { $0.isArchived == false }
    }

    func historicalModels(refreshSessionCache: Bool = false) -> [String] {
        self.queue.sync {
            let cachedSessions = refreshSessionCache ? self.refreshCachedSessionsLocked() : Array(self.sessionCache.values)
            return Array(
                Set(
                    cachedSessions.compactMap(\.record?.model)
                )
            )
            .sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }

    func loadRecordsSourceSnapshot(
        refreshMode: RecordsRefreshMode
    ) async throws -> RecordsSourceSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                do {
                    let snapshot = try self.loadRecordsSourceSnapshotLocked(refreshMode: refreshMode)
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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

    func reduceBillableEvents<Result>(
        into initialResult: Result,
        refreshSessionCache: Bool = true,
        costCalculator: ((String, Usage, Usage) -> Double)? = nil,
        _ update: (inout Result, BillableUsageEvent) -> Void
    ) -> Result {
        self.queue.sync {
            var result = initialResult
            let resolvedCostCalculator: (String, Usage, Usage) -> Double = { model, usage, sessionUsage in
                costCalculator?(model, usage, sessionUsage)
                    ?? self.billableCostCalculator(model, usage, sessionUsage)
                    ?? 0
            }

            let cachedSessions = refreshSessionCache
                ? self.refreshCachedSessionsLocked()
                : Array(self.sessionCache.values)

            if let projection = self.projectSessionUsageLedgerLocked(using: cachedSessions),
               projection.ledger.didSeedFromSessionCache {
                for event in self.billableEventsLocked(costCalculator: resolvedCostCalculator) {
                    update(&result, event)
                }
                return result
            }

            for cached in cachedSessions {
                guard let record = cached.record else { continue }
                for event in cached.usageEvents {
                    update(
                        &result,
                        BillableUsageEvent(
                            sessionID: record.id,
                            model: record.model,
                            sessionUsage: record.usage,
                            timestamp: event.timestamp,
                            usage: event.usage,
                            costUSD: resolvedCostCalculator(record.model, event.usage, record.usage)
                        )
                    )
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
        for cached in self.refreshCachedSessionsLocked() {
            update(&result, cached)
        }
    }

    private func refreshCachedSessionsLocked() -> [CachedSessionRecord] {
        (try? self.refreshCachedSessionsLocked(
            rebuildAll: false,
            collectWarnings: false
        ).records) ?? Array(self.sessionCache.values)
    }

    private func refreshCachedSessionsLocked(
        rebuildAll: Bool,
        collectWarnings: Bool
    ) throws -> RefreshedCachedSessions {
        let scanResult = try self.sessionFilesThrowing(collectWarnings: collectWarnings)
        let files = scanResult.files
        let previousSessionCache = rebuildAll ? [:] : self.sessionCache

        var nextSessionCache: [URL: CachedSessionRecord] = [:]
        nextSessionCache.reserveCapacity(files.count)

        var cachedSessions: [CachedSessionRecord] = []
        cachedSessions.reserveCapacity(files.count)

        var warnings = scanResult.warnings
        warnings.reserveCapacity(files.count)

        for fileURL in files {
            autoreleasepool {
                guard let fingerprint = self.fingerprint(for: fileURL) else {
                    if collectWarnings {
                        warnings.append(
                            RecordsSnapshotWarning(
                                sessionFilePath: fileURL.path,
                                kind: .unreadableSessionFile,
                                message: "Unable to read session file metadata."
                            )
                        )
                    }
                    return
                }

                if let cached = previousSessionCache[fileURL],
                   cached.fingerprint == fingerprint,
                   collectWarnings == false || cached.record != nil {
                    nextSessionCache[fileURL] = cached
                    cachedSessions.append(cached)
                    return
                }

                let parsed = self.parseSession(
                    fileURL,
                    fingerprint: fingerprint,
                    collectWarning: collectWarnings
                )
                nextSessionCache[fileURL] = parsed.cachedRecord
                cachedSessions.append(parsed.cachedRecord)
                if let warning = parsed.warning {
                    warnings.append(warning)
                }
            }
        }

        self.sessionCache = nextSessionCache
        self.persistSessionCache(nextSessionCache)

        return RefreshedCachedSessions(
            records: cachedSessions,
            warnings: warnings.sorted { lhs, rhs in
                if lhs.sessionFilePath != rhs.sessionFilePath {
                    return lhs.sessionFilePath < rhs.sessionFilePath
                }
                if lhs.kind != rhs.kind {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.message < rhs.message
            }
        )
    }

    private func loadRecordsSourceSnapshotLocked(
        refreshMode: RecordsRefreshMode
    ) throws -> RecordsSourceSnapshot {
        let refreshed = try self.refreshCachedSessionsLocked(
            rebuildAll: refreshMode == .rebuildAll,
            collectWarnings: true
        )
        let historicalSessions = self
            .projectSessionUsageLedgerLocked(using: refreshed.records)?
            .historicalSessions
            .map(Self.historicalSessionRecord(from:))
            ?? []

        return RecordsSourceSnapshot(
            generatedAt: Date(),
            refreshMode: refreshMode,
            sessions: historicalSessions,
            warnings: refreshed.warnings
        )
    }

    private func projectSessionUsageLedgerLocked(
        using cachedSessions: [CachedSessionRecord]
    ) -> PortableCoreSessionUsageLedgerProjectionResult? {
        let seedSessions: [CachedSessionRecord]
        if self.usageLedger.didSeedFromSessionCache {
            seedSessions = []
        } else {
            seedSessions = Array((self.seedSessionCache ?? self.loadPersistedCache()).values)
        }

        let request = PortableCoreSessionUsageLedgerProjectionRequest(
            currentSessions: cachedSessions.map(Self.portableCachedSessionRecord(from:)),
            persistedLedger: Self.portablePersistedUsageLedger(from: self.usageLedger),
            seedSessions: seedSessions.map(Self.portableCachedSessionRecord(from:))
        )

        let projection: PortableCoreSessionUsageLedgerProjectionResult
        do {
            projection = try RustPortableCoreAdapter.shared.projectSessionUsageLedger(
                request,
                buildIfNeeded: false
            )
        } catch {
            return nil
        }

        let nextLedger = Self.persistedUsageLedger(from: projection.ledger)
        if nextLedger != self.usageLedger {
            let requiredSeedPersistence =
                self.usageLedger.didSeedFromSessionCache == false &&
                nextLedger.didSeedFromSessionCache
            let didPersist = self.persistUsageLedger(nextLedger)
            guard didPersist || requiredSeedPersistence == false else {
                return nil
            }
            if didPersist {
                self.usageLedger = nextLedger
            }
        }

        if nextLedger.didSeedFromSessionCache {
            self.seedSessionCache = nil
        }

        return projection
    }

    private static func portableCachedSessionRecord(
        from cached: CachedSessionRecord
    ) -> PortableCoreCachedSessionRecordInput {
        PortableCoreCachedSessionRecordInput(
            record: cached.record.map { record in
                PortableCoreSessionRecordInput(
                    sessionID: record.id,
                    startedAt: record.startedAt.timeIntervalSince1970,
                    lastActivityAt: record.lastActivityAt.timeIntervalSince1970,
                    isArchived: record.isArchived,
                    model: record.model,
                    usage: .legacy(from: record.usage)
                )
            },
            usageEvents: cached.usageEvents.map { event in
                PortableCoreUsageEventInput(
                    timestamp: event.timestamp.timeIntervalSince1970,
                    usage: .legacy(from: event.usage)
                )
            }
        )
    }

    private static func portablePersistedUsageLedger(
        from ledger: PersistedUsageLedger
    ) -> PortableCorePersistedUsageLedger {
        PortableCorePersistedUsageLedger(
            version: ledger.version,
            didSeedFromSessionCache: ledger.didSeedFromSessionCache,
            sessions: ledger.sessions.mapValues { session in
                PortableCorePersistedLedgerSession(
                    model: session.model,
                    events: session.events.map { event in
                        PortableCorePersistedLedgerEvent(
                            timestamp: event.timestamp.timeIntervalSince1970,
                            usage: .legacy(from: event.usage),
                            costUsd: event.costUSD
                        )
                    }
                )
            }
        )
    }

    private static func persistedUsageLedger(
        from ledger: PortableCorePersistedUsageLedger
    ) -> PersistedUsageLedger {
        PersistedUsageLedger(
            version: ledger.version,
            didSeedFromSessionCache: ledger.didSeedFromSessionCache,
            sessions: ledger.sessions.mapValues { session in
                PersistedLedgerSession(
                    model: session.model,
                    events: session.events.map { event in
                        PersistedLedgerEvent(
                            timestamp: Date(timeIntervalSince1970: event.timestamp),
                            usage: event.usage.sessionUsage(),
                            costUSD: event.costUsd
                        )
                    }
                )
            }
        )
    }

    private static func historicalSessionRecord(
        from record: PortableCoreHistoricalSessionRecord
    ) -> HistoricalSessionRecord {
        HistoricalSessionRecord(
            sessionID: record.sessionID,
            modelID: record.modelId,
            startedAt: Date(timeIntervalSince1970: record.startedAt),
            lastActivityAt: Date(timeIntervalSince1970: record.lastActivityAt),
            isArchived: record.isArchived,
            totalTokens: record.totalTokens
        )
    }

    private func billableEventsLocked(
        costCalculator: (String, Usage, Usage) -> Double
    ) -> [BillableUsageEvent] {
        self.usageLedger.sessions.keys.sorted().flatMap { sessionID in
            let session = self.usageLedger.sessions[sessionID]
            let model = session?.model ?? ""
            let sessionUsage = (session?.events ?? []).reduce(Usage.zero) { partial, event in
                partial + event.usage
            }
            return (session?.events ?? []).map { event in
                BillableUsageEvent(
                    sessionID: sessionID,
                    model: model,
                    sessionUsage: sessionUsage,
                    timestamp: event.timestamp,
                    usage: event.usage,
                    costUSD: model.isEmpty == false
                        ? costCalculator(model, event.usage, sessionUsage)
                        : event.costUSD
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.sessionID < rhs.sessionID
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private func reduceSessionLifecycle<Result>(
        into initialResult: Result,
        matchingSessionIDs: Set<String>?,
        _ update: (inout Result, SessionLifecycleRecord) -> Void
    ) -> Result {
        self.queue.sync {
            var result = initialResult
            self.reduceCachedSessionLifecycleLocked(
                into: &result,
                matchingSessionIDs: matchingSessionIDs
            ) { partialResult, cached in
                if let record = cached.record {
                    update(&partialResult, record)
                }
            }
            return result
        }
    }

    private func reduceCachedSessionLifecycleLocked<Result>(
        into result: inout Result,
        matchingSessionIDs: Set<String>?,
        _ update: (inout Result, CachedSessionLifecycleRecord) -> Void
    ) {
        let files = self.sessionFiles()
        var nextLifecycleCache: [URL: CachedSessionLifecycleRecord] = [:]
        nextLifecycleCache.reserveCapacity(files.count)

        for fileURL in files {
            autoreleasepool {
                if let matchingSessionIDs,
                   self.matchesSessionLifecycleFilter(
                        fileURL: fileURL,
                        sessionIDs: matchingSessionIDs
                   ) == false {
                    return
                }

                guard let fingerprint = self.fingerprint(for: fileURL) else { return }

                if let cached = self.sessionLifecycleCache[fileURL], cached.fingerprint == fingerprint {
                    nextLifecycleCache[fileURL] = cached
                    update(&result, cached)
                    return
                }

                if let cachedSession = self.sessionCache[fileURL],
                   cachedSession.fingerprint == fingerprint,
                   let record = cachedSession.record {
                    let lifecycleRecord = CachedSessionLifecycleRecord(
                        fingerprint: fingerprint,
                        record: SessionLifecycleRecord(
                            id: record.id,
                            startedAt: record.startedAt,
                            lastActivityAt: record.lastActivityAt,
                            isArchived: record.isArchived,
                            taskLifecycleState: record.taskLifecycleState
                        )
                    )
                    nextLifecycleCache[fileURL] = lifecycleRecord
                    update(&result, lifecycleRecord)
                    return
                }

                let cached = self.parseSessionLifecycle(fileURL, fingerprint: fingerprint)
                nextLifecycleCache[fileURL] = cached
                update(&result, cached)
            }
        }

        self.sessionLifecycleCache = nextLifecycleCache
    }

    private func matchesSessionLifecycleFilter(
        fileURL: URL,
        sessionIDs: Set<String>
    ) -> Bool {
        let filename = fileURL.lastPathComponent
        return sessionIDs.contains { filename.contains($0) }
    }

    private func sessionFiles() -> [URL] {
        (try? self.sessionFilesThrowing(collectWarnings: false).files) ?? []
    }

    private func sessionFilesThrowing(
        collectWarnings: Bool
    ) throws -> SessionFileScanResult {
        let directories = [
            self.codexRootURL.appendingPathComponent("sessions", isDirectory: true),
            self.codexRootURL.appendingPathComponent("archived_sessions", isDirectory: true),
        ]

        var files: [URL] = []
        var warnings: [RecordsSnapshotWarning] = []
        for directory in directories {
            guard self.fileManager.fileExists(atPath: directory.path) else { continue }

            var enumeratorDidFail = false
            guard let enumerator = self.fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                errorHandler: { fileURL, error in
                    guard collectWarnings else {
                        enumeratorDidFail = true
                        return false
                    }

                    warnings.append(
                        RecordsSnapshotWarning(
                            sessionFilePath: fileURL.path,
                            kind: .unreadableSessionFile,
                            message: error.localizedDescription
                        )
                    )
                    return true
                }
            ) else {
                throw RecordsSourceSnapshotError.directoryEnumerationFailed(path: directory.path)
            }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                files.append(url)
            }

            if enumeratorDidFail {
                throw RecordsSourceSnapshotError.directoryEnumerationFailed(path: directory.path)
            }
        }
        return SessionFileScanResult(
            files: files.sorted { $0.path < $1.path },
            warnings: warnings
        )
    }

    private func fingerprint(for fileURL: URL) -> FileFingerprint? {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }

        return FileFingerprint(
            fileSize: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate ?? .distantPast
        )
    }

    private func parseSession(
        _ fileURL: URL,
        fingerprint: FileFingerprint,
        collectWarning: Bool
    ) -> ParsedSessionResult {
        var sessionID: String?
        var sessionDate: Date?
        var model: String?
        var usageHighWater: Usage?
        var usageEvents: [UsageEvent] = []
        var taskLifecycleState: TaskLifecycleState?

        let didRead = self.enumerateLines(in: fileURL) { line in
            self.consumeSessionMetadata(in: line, sessionID: &sessionID, sessionDate: &sessionDate)
            self.consumeTurnContext(in: line, model: &model)
            self.consumeTaskLifecycle(in: line, taskLifecycleState: &taskLifecycleState)
            if let sample = self.parseUsageSample(from: line) {
                let incrementalUsage = usageHighWater.map { sample.totalUsage.delta(from: $0) }
                    ?? sample.incrementalUsage
                    ?? sample.totalUsage
                usageHighWater = usageHighWater.map { $0.highWater(with: sample.totalUsage) } ?? sample.totalUsage

                let eventTimestamp = sample.timestamp
                    ?? fingerprint.modificationDate.addingTimeInterval(Double(usageEvents.count) / 1_000)
                if incrementalUsage.isZero == false {
                    usageEvents.append(
                        UsageEvent(timestamp: eventTimestamp, usage: incrementalUsage)
                    )
                }
            }
        }

        let record: SessionRecord?
        let warning: RecordsSnapshotWarning?
        let resolvedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)

        if didRead,
           let startedAt = sessionDate,
           let resolvedModel,
           resolvedModel.isEmpty == false {
            record = SessionRecord(
                id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                startedAt: startedAt,
                lastActivityAt: fingerprint.modificationDate,
                isArchived: self.isArchivedSessionFile(fileURL),
                model: resolvedModel,
                usage: usageHighWater ?? .zero,
                taskLifecycleState: taskLifecycleState
            )
            warning = nil
        } else {
            record = nil
            if collectWarning {
                warning = RecordsSnapshotWarning(
                    sessionFilePath: fileURL.path,
                    kind: didRead ? .incompleteSessionRecord : .unreadableSessionFile,
                    message: didRead
                        ? "Missing required session metadata or model."
                        : "Unable to read session file."
                )
            } else {
                warning = nil
            }
        }

        return ParsedSessionResult(
            cachedRecord: CachedSessionRecord(
                fingerprint: fingerprint,
                record: record,
                usageEvents: usageEvents
            ),
            warning: warning
        )
    }

    private func parseSessionLifecycle(
        _ fileURL: URL,
        fingerprint: FileFingerprint
    ) -> CachedSessionLifecycleRecord {
        var sessionID: String?
        var sessionDate: Date?
        var taskLifecycleState: TaskLifecycleState?

        let didRead = self.enumerateLines(in: fileURL) { line in
            self.consumeSessionMetadata(in: line, sessionID: &sessionID, sessionDate: &sessionDate)
            self.consumeTaskLifecycle(in: line, taskLifecycleState: &taskLifecycleState)
        }

        let record: SessionLifecycleRecord?
        if didRead,
           let startedAt = sessionDate {
            record = SessionLifecycleRecord(
                id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                startedAt: startedAt,
                lastActivityAt: fingerprint.modificationDate,
                isArchived: self.isArchivedSessionFile(fileURL),
                taskLifecycleState: taskLifecycleState
            )
        } else {
            record = nil
        }

        return CachedSessionLifecycleRecord(
            fingerprint: fingerprint,
            record: record
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

        let decoder = self.makePersistedJSONDecoder()

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

    private func loadPersistedUsageLedger() -> PersistedUsageLedger {
        guard let data = try? Data(contentsOf: self.persistedUsageLedgerURL) else {
            return PersistedUsageLedger.empty(version: self.persistedUsageLedgerVersion)
        }

        let decoder = self.makePersistedJSONDecoder()

        guard let persisted = try? decoder.decode(PersistedUsageLedger.self, from: data) else {
            return PersistedUsageLedger.empty(version: self.persistedUsageLedgerVersion)
        }

        if persisted.version == self.persistedUsageLedgerVersion {
            return persisted
        }

        if persisted.version == 1,
           self.fileManager.fileExists(atPath: self.persistedCacheURL.path) {
            return PersistedUsageLedger.empty(version: self.persistedUsageLedgerVersion)
        }

        guard persisted.version < self.persistedUsageLedgerVersion else {
            return PersistedUsageLedger.empty(version: self.persistedUsageLedgerVersion)
        }

        var migrated = persisted
        migrated.version = self.persistedUsageLedgerVersion
        return migrated
    }

    private func persistSessionCache(_ cache: [URL: CachedSessionRecord]) {
        let payload = PersistedCache(
            version: self.persistedCacheVersion,
            files: Dictionary(uniqueKeysWithValues: cache.map { ($0.key.path, $0.value) })
        )

        let encoder = self.makePersistedJSONEncoder()

        guard let data = try? encoder.encode(payload) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.persistedCacheURL)
    }

    @discardableResult
    private func persistUsageLedger(_ ledger: PersistedUsageLedger) -> Bool {
        let encoder = self.makePersistedJSONEncoder()

        guard let data = try? encoder.encode(ledger) else { return false }
        do {
            try CodexPaths.writeSecureFile(data, to: self.persistedUsageLedgerURL)
            return true
        } catch {
            return false
        }
    }

    private func makePersistedJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ISO8601Parsing.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }

    private func makePersistedJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.persistedDateFormatter.string(from: date))
        }
        return encoder
    }

    nonisolated(unsafe) private static let persistedDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func normalizeModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            return String(trimmed.dropFirst("openai/".count))
        }
        return trimmed
    }
}

private enum RecordsSourceSnapshotError: LocalizedError {
    case directoryEnumerationFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .directoryEnumerationFailed(let path):
            return "Failed to enumerate session directory at \(path)."
        }
    }
}
