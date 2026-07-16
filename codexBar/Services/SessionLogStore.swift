import Foundation

final class SessionLogStore: @unchecked Sendable, RecordsSourceSnapshotLoading {
    static let shared = SessionLogStore()

    private static let skippedTopLevelLineTypes: Set<String> = ["response_item"]
    private static let topLevelTypeKey = Data("type".utf8)

    enum TaskLifecycleState: String, Codable, Equatable {
        case running
        case completed
    }

    enum ServiceTier: String, Codable, Equatable, Sendable {
        case standard
        case priority
        case unknown

        static func parse(_ value: String?) -> ServiceTier {
            switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "priority", "fast": .priority
            case "standard", "flex": .standard
            default: .unknown
            }
        }
    }

    enum EventSource: String, Codable, Equatable, Sendable {
        case nativeSession
        case fork
        case subagent
        case legacyMigration
    }

    struct Usage: Codable, Equatable, Hashable {
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
        let parentSessionID: String?
        let isSubagent: Bool?
        let inheritedUsageBaseline: Usage?
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
        let modelID: String?
        let turnID: String?
        let serviceTier: ServiceTier
        let source: EventSource

        init(
            timestamp: Date,
            usage: Usage,
            modelID: String? = nil,
            turnID: String? = nil,
            serviceTier: ServiceTier = .unknown,
            source: EventSource = .nativeSession
        ) {
            self.timestamp = timestamp
            self.usage = usage
            self.modelID = modelID
            self.turnID = turnID
            self.serviceTier = serviceTier
            self.source = source
        }

        private enum CodingKeys: String, CodingKey {
            case timestamp
            case usage
            case modelID
            case turnID
            case serviceTier
            case source
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.timestamp = try container.decode(Date.self, forKey: .timestamp)
            self.usage = try container.decode(Usage.self, forKey: .usage)
            self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
            self.turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
            self.serviceTier = try container.decodeIfPresent(ServiceTier.self, forKey: .serviceTier) ?? .unknown
            self.source = try container.decodeIfPresent(EventSource.self, forKey: .source) ?? .nativeSession
        }
    }

    struct BillableUsageEvent: Codable, Equatable {
        let sessionID: String
        let model: String
        let sessionUsage: Usage
        let timestamp: Date
        let usage: Usage
        let costUSD: Double
        let turnID: String?
        let serviceTier: ServiceTier
        let source: EventSource
    }

    struct BillableEventsReduction<Result> {
        let result: Result
        let isComplete: Bool
    }

    private struct FileFingerprint: Codable, Equatable {
        let fileSize: Int
        let modificationDate: Date
    }

    private struct CachedSessionRecord: Codable {
        let fingerprint: FileFingerprint
        let record: SessionRecord?
        let usageEvents: [UsageEvent]
        let scanWarning: RecordsSnapshotWarning?
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
        let modelID: String?
        let turnID: String?
        let serviceTier: ServiceTier
        let source: EventSource

        init(
            timestamp: Date,
            usage: Usage,
            costUSD: Double,
            modelID: String? = nil,
            turnID: String? = nil,
            serviceTier: ServiceTier = .unknown,
            source: EventSource = .legacyMigration
        ) {
            self.timestamp = timestamp
            self.usage = usage
            self.costUSD = costUSD
            self.modelID = modelID
            self.turnID = turnID
            self.serviceTier = serviceTier
            self.source = source
        }

        private enum CodingKeys: String, CodingKey {
            case timestamp
            case usage
            case costUSD
            case modelID
            case turnID
            case serviceTier
            case source
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.timestamp = try container.decode(Date.self, forKey: .timestamp)
            self.usage = try container.decode(Usage.self, forKey: .usage)
            self.costUSD = try container.decode(Double.self, forKey: .costUSD)
            self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
            self.turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
            self.serviceTier = try container.decodeIfPresent(ServiceTier.self, forKey: .serviceTier) ?? .unknown
            self.source = try container.decodeIfPresent(EventSource.self, forKey: .source) ?? .legacyMigration
        }
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
        let modelID: String?
        let turnID: String?
        let serviceTier: ServiceTier
    }

    private struct SessionStartInfo {
        let parentSessionID: String?
        let isSubagent: Bool
    }

    private struct PersistedCache: Codable {
        let version: Int
        let files: [String: CachedSessionRecord]
    }

    private let fileManager: FileManager
    private let codexRootURL: URL
    private let persistedCacheURL: URL
    private let persistedUsageLedgerURL: URL
    private let billableCostCalculator: (String, ServiceTier, Usage, Usage) -> Double?
    private let queue = DispatchQueue(label: "lzl.codexbar.session-log-store", qos: .utility)
    private let persistedCacheVersion = 7
    private let persistedUsageLedgerVersion = 4

    private var sessionCache: [URL: CachedSessionRecord] = [:]
    private var sessionLifecycleCache: [URL: CachedSessionLifecycleRecord] = [:]
    private var seedSessionCache: [URL: CachedSessionRecord]?
    private lazy var usageLedger = self.loadPersistedUsageLedger()

    init(
        fileManager: FileManager = .default,
        codexRootURL: URL = CodexPaths.codexRoot,
        persistedCacheURL: URL = CodexPaths.costSessionCacheURL,
        persistedUsageLedgerURL: URL? = nil,
        billableCostCalculator: @escaping (String, ServiceTier, Usage, Usage) -> Double? = {
            model,
            serviceTier,
            usage,
            sessionUsage in
            LocalCostPricing.costUSD(
                model: model,
                usage: usage,
                sessionUsage: sessionUsage,
                serviceTier: serviceTier
            )
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
    }

    convenience init(
        fileManager: FileManager = .default,
        codexRootURL: URL = CodexPaths.codexRoot,
        persistedCacheURL: URL = CodexPaths.costSessionCacheURL,
        persistedUsageLedgerURL: URL? = nil,
        billableCostCalculator: @escaping (String, Usage, Usage) -> Double?
    ) {
        self.init(
            fileManager: fileManager,
            codexRootURL: codexRootURL,
            persistedCacheURL: persistedCacheURL,
            persistedUsageLedgerURL: persistedUsageLedgerURL,
            billableCostCalculator: { model, _, usage, sessionUsage in
                billableCostCalculator(model, usage, sessionUsage)
            }
        )
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
            var models = Set(cachedSessions.compactMap(\.record?.model))
            for cached in cachedSessions {
                for modelID in cached.usageEvents.compactMap(\.modelID) where modelID.isEmpty == false {
                    models.insert(modelID)
                }
            }
            return Array(models)
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
        costCalculator: ((String, ServiceTier, Usage, Usage) -> Double)? = nil,
        _ update: (inout Result, BillableUsageEvent) -> Void
    ) -> Result {
        self.reduceBillableEventsWithStatus(
            into: initialResult,
            refreshSessionCache: refreshSessionCache,
            costCalculator: costCalculator,
            update
        ).result
    }

    func reduceBillableEventsWithStatus<Result>(
        into initialResult: Result,
        refreshSessionCache: Bool = true,
        costCalculator: ((String, ServiceTier, Usage, Usage) -> Double)? = nil,
        _ update: (inout Result, BillableUsageEvent) -> Void
    ) -> BillableEventsReduction<Result> {
        self.queue.sync {
            var result = initialResult
            let resolvedCostCalculator: (String, ServiceTier, Usage, Usage) -> Double = {
                model,
                serviceTier,
                usage,
                sessionUsage in
                costCalculator?(model, serviceTier, usage, sessionUsage)
                    ?? self.billableCostCalculator(model, serviceTier, usage, sessionUsage)
                    ?? 0
            }

            var refreshedSessions: RefreshedCachedSessions?
            var isComplete = true
            if self.usageLedger.didSeedFromSessionCache == false || refreshSessionCache {
                do {
                    let refreshed = try self.refreshCachedSessionsLocked(
                        rebuildAll: false,
                        collectWarnings: true
                    )
                    refreshedSessions = refreshed
                    isComplete = refreshed.warnings.isEmpty
                } catch {
                    isComplete = false
                }
            }

            if self.usageLedger.didSeedFromSessionCache == false,
               isComplete,
               let refreshedSessions {
                if self.ensureUsageLedgerSeededLocked(using: refreshedSessions.records) {
                    self.refreshUsageLedgerLocked(using: refreshedSessions.records)
                }
            } else if self.usageLedger.didSeedFromSessionCache,
                      refreshSessionCache,
                      isComplete,
                      let refreshedSessions {
                self.refreshUsageLedgerLocked(using: refreshedSessions.records)
            }

            if self.usageLedger.didSeedFromSessionCache {
                for event in self.billableEventsLocked(costCalculator: resolvedCostCalculator) {
                    update(&result, event)
                }
                return BillableEventsReduction(result: result, isComplete: isComplete)
            }

            let cachedSessions = refreshedSessions?.records ?? Array(self.sessionCache.values)
            for cached in cachedSessions {
                guard let record = cached.record else { continue }
                for event in cached.usageEvents {
                    let model = self.resolvedBillingModel(
                        eventModelID: event.modelID,
                        source: event.source,
                        sessionModel: record.model
                    )
                    update(
                        &result,
                        BillableUsageEvent(
                            sessionID: record.id,
                            model: model,
                            sessionUsage: record.usage,
                            timestamp: event.timestamp,
                            usage: event.usage,
                            costUSD: resolvedCostCalculator(
                                model,
                                event.serviceTier,
                                event.usage,
                                record.usage
                            ),
                            turnID: event.turnID,
                            serviceTier: event.serviceTier,
                            source: event.source
                        )
                    )
                }
            }
            return BillableEventsReduction(result: result, isComplete: isComplete)
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
        var didParseSession = rebuildAll
        var parsedSessionIDs: Set<String> = []

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
                    if collectWarnings, let warning = cached.scanWarning {
                        warnings.append(warning)
                    }
                    return
                }

                let parsed = self.parseSession(
                    fileURL,
                    fingerprint: fingerprint,
                    collectWarning: collectWarnings
                )
                didParseSession = true
                nextSessionCache[fileURL] = parsed.cachedRecord
                cachedSessions.append(parsed.cachedRecord)
                if let sessionID = parsed.cachedRecord.record?.id {
                    parsedSessionIDs.insert(sessionID)
                }
                if collectWarnings, let warning = parsed.warning {
                    warnings.append(warning)
                }
            }
        }

        let fileURLsBySessionID = Dictionary(
            grouping: nextSessionCache.compactMap { fileURL, cached -> (String, URL)? in
                guard let sessionID = cached.record?.id else { return nil }
                return (sessionID, fileURL)
            },
            by: \.0
        ).mapValues { entries in
            entries.map(\.1).sorted { $0.path < $1.path }
        }

        func preferredRecordsBySessionID() -> [String: CachedSessionRecord] {
            var preferred: [String: CachedSessionRecord] = [:]
            for cached in nextSessionCache.values {
                guard let record = cached.record else { continue }
                if let existing = preferred[record.id],
                   self.shouldIngestBefore(existing, cached) {
                    continue
                }
                preferred[record.id] = cached
            }
            return preferred
        }

        var preferredRecordBySessionID = preferredRecordsBySessionID()
        var absoluteBaselineBySessionID: [String: Usage] = [:]
        var pendingForkSessionIDs: Set<String> = []
        var dirtySessionIDs = parsedSessionIDs

        for (sessionID, cached) in preferredRecordBySessionID {
            guard let record = cached.record,
                  record.isSubagent != true else { continue }
            if record.parentSessionID == nil {
                absoluteBaselineBySessionID[sessionID] = .zero
            } else {
                pendingForkSessionIDs.insert(sessionID)
            }
        }

        var didResolveFork = true
        while didResolveFork, pendingForkSessionIDs.isEmpty == false {
            didResolveFork = false
            for sessionID in pendingForkSessionIDs.sorted() {
                guard let cached = preferredRecordBySessionID[sessionID],
                      let record = cached.record,
                      let parentSessionID = record.parentSessionID else {
                    pendingForkSessionIDs.remove(sessionID)
                    continue
                }

                let inheritedUsage: Usage
                if let parent = preferredRecordBySessionID[parentSessionID],
                   let parentBaseline = absoluteBaselineBySessionID[parentSessionID] {
                    inheritedUsage = parent.usageEvents.reduce(parentBaseline) { partial, event in
                        event.timestamp <= record.startedAt ? partial + event.usage : partial
                    }
                } else if let cachedBaseline = record.inheritedUsageBaseline {
                    inheritedUsage = cachedBaseline
                } else {
                    continue
                }

                let shouldReparse = dirtySessionIDs.contains(sessionID) ||
                    dirtySessionIDs.contains(parentSessionID) ||
                    record.inheritedUsageBaseline != inheritedUsage
                if shouldReparse {
                    for fileURL in fileURLsBySessionID[sessionID] ?? [] {
                        guard let fileCached = nextSessionCache[fileURL],
                              fileCached.record?.id == sessionID else { continue }
                        let reparsed = self.parseSession(
                            fileURL,
                            fingerprint: fileCached.fingerprint,
                            collectWarning: collectWarnings,
                            inheritedUsageBaseline: inheritedUsage
                        )
                        nextSessionCache[fileURL] = reparsed.cachedRecord
                        if collectWarnings, let warning = reparsed.warning {
                            warnings.append(warning)
                        }
                    }
                    dirtySessionIDs.insert(sessionID)
                    preferredRecordBySessionID = preferredRecordsBySessionID()
                }

                absoluteBaselineBySessionID[sessionID] = inheritedUsage
                pendingForkSessionIDs.remove(sessionID)
                didResolveFork = true
            }
        }

        if collectWarnings {
            for sessionID in pendingForkSessionIDs.sorted() {
                guard let cached = preferredRecordBySessionID[sessionID],
                      let record = cached.record else { continue }
                warnings.append(
                    RecordsSnapshotWarning(
                        sessionFilePath: fileURLsBySessionID[sessionID]?.first?.path ?? sessionID,
                        kind: .incompleteSessionRecord,
                        message: "Unable to resolve inherited usage baseline from parent session \(record.parentSessionID ?? "unknown")."
                    )
                )
            }
        }

        cachedSessions = Array(nextSessionCache.values)

        self.sessionCache = nextSessionCache
        if didParseSession || nextSessionCache.count != previousSessionCache.count {
            self.persistSessionCache(nextSessionCache)
        }

        var uniqueWarningsByID: [String: RecordsSnapshotWarning] = [:]
        for warning in warnings {
            uniqueWarningsByID[warning.id] = warning
        }

        return RefreshedCachedSessions(
            records: cachedSessions,
            warnings: uniqueWarningsByID.values.sorted { lhs, rhs in
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

        if refreshed.warnings.isEmpty,
           self.ensureUsageLedgerSeededLocked(using: refreshed.records) {
            self.refreshUsageLedgerLocked(using: refreshed.records)
        }

        return RecordsSourceSnapshot(
            generatedAt: Date(),
            refreshMode: refreshMode,
            sessions: self.historicalSessionRecords(from: refreshed.records),
            warnings: refreshed.warnings
        )
    }

    private func historicalSessionRecords(
        from cachedSessions: [CachedSessionRecord]
    ) -> [HistoricalSessionRecord] {
        var preferredRecordBySessionID: [String: CachedSessionRecord] = [:]
        preferredRecordBySessionID.reserveCapacity(cachedSessions.count)

        for cached in cachedSessions {
            guard let record = cached.record else { continue }

            if let existing = preferredRecordBySessionID[record.id],
               self.shouldIngestBefore(existing, cached) {
                continue
            }
            preferredRecordBySessionID[record.id] = cached
        }

        return preferredRecordBySessionID.values.compactMap { cached in
            guard let record = cached.record else { return nil }
            return HistoricalSessionRecord(
                sessionID: record.id,
                modelID: record.model,
                startedAt: record.startedAt,
                lastActivityAt: record.lastActivityAt,
                isArchived: record.isArchived,
                totalTokens: record.usage.totalTokens
            )
        }
        .sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.sessionID < rhs.sessionID
        }
    }

    private func ensureUsageLedgerSeededLocked(using currentSessions: [CachedSessionRecord]) -> Bool {
        guard self.usageLedger.didSeedFromSessionCache == false else { return true }

        var nextLedger = self.usageLedger
        let seedCache = self.seedSessionCache ?? self.loadPersistedCache()
        let alignedSeedCache = self.alignedSeedSessions(
            Array(seedCache.values),
            using: currentSessions
        )
        _ = self.ingestBillableEvents(from: alignedSeedCache, into: &nextLedger)
        nextLedger.didSeedFromSessionCache = true

        guard self.persistUsageLedger(nextLedger) else { return false }

        self.usageLedger = nextLedger
        self.seedSessionCache = nil
        return true
    }

    private func refreshUsageLedgerLocked(using cachedSessions: [CachedSessionRecord]) {
        guard self.usageLedger.didSeedFromSessionCache else { return }

        var nextLedger = self.usageLedger
        guard self.ingestBillableEvents(from: cachedSessions, into: &nextLedger) else { return }
        guard self.persistUsageLedger(nextLedger) else { return }
        self.usageLedger = nextLedger
    }

    private func ingestBillableEvents(
        from cachedSessions: [CachedSessionRecord],
        into ledger: inout PersistedUsageLedger
    ) -> Bool {
        let groupedBySessionID = Dictionary(grouping: cachedSessions.compactMap { cached -> CachedSessionRecord? in
            guard cached.record != nil, cached.usageEvents.isEmpty == false else { return nil }
            return cached
        }, by: { $0.record?.id ?? "" })

        guard groupedBySessionID.isEmpty == false else { return false }

        var changed = false

        for sessionID in groupedBySessionID.keys.sorted() {
            let records = (groupedBySessionID[sessionID] ?? []).sorted(by: self.shouldIngestBefore)
            let existingSession = ledger.sessions[sessionID]
            let shouldRebuildPreferredRecord = records.first?.record?.isArchived == false ||
                existingSession?.events.contains(where: { $0.source == .legacyMigration }) == true
            if shouldRebuildPreferredRecord,
               let preferredRecord = records.first,
               let rebuiltSession = self.rebuiltLedgerSession(from: preferredRecord, existingSession: existingSession) {
                if existingSession != rebuiltSession {
                    ledger.sessions[sessionID] = rebuiltSession
                    changed = true
                }
                continue
            }

            var ledgerSession = existingSession ?? PersistedLedgerSession(model: "", events: [])
            var eventIndexByKey: [String: Int] = [:]
            for (index, event) in ledgerSession.events.enumerated() {
                let key = self.ledgerEventKey(
                    sessionID: sessionID,
                    timestamp: event.timestamp,
                    usage: event.usage,
                    modelID: event.modelID,
                    turnID: event.turnID,
                    serviceTier: event.serviceTier,
                    source: event.source
                )
                if eventIndexByKey[key] == nil {
                    eventIndexByKey[key] = index
                }
            }
            var observedUsageTotal = ledgerSession.events.reduce(Usage.zero) { partial, event in
                partial + event.usage
            }
            var changedSession = false
            var updatedModel = false

            for cached in records {
                guard let record = cached.record else { continue }
                if ledgerSession.model != record.model {
                    ledgerSession.model = record.model
                    updatedModel = true
                }

                let shouldNormalizeSingleSnapshot =
                    cached.usageEvents.count == 1 &&
                    cached.usageEvents[0].usage == record.usage

                for usageEvent in cached.usageEvents {
                    let normalizedUsage = shouldNormalizeSingleSnapshot
                        ? usageEvent.usage.delta(from: observedUsageTotal)
                        : usageEvent.usage

                    guard normalizedUsage.isZero == false else { continue }

                    let eventKey = self.ledgerEventKey(
                        sessionID: sessionID,
                        timestamp: usageEvent.timestamp,
                        usage: normalizedUsage,
                        modelID: usageEvent.modelID,
                        turnID: usageEvent.turnID,
                        serviceTier: usageEvent.serviceTier,
                        source: usageEvent.source
                    )
                    if let existingIndex = eventIndexByKey[eventKey] {
                        let existingEvent = ledgerSession.events[existingIndex]
                        let upgradedEvent = PersistedLedgerEvent(
                            timestamp: existingEvent.timestamp,
                            usage: existingEvent.usage,
                            costUSD: existingEvent.costUSD,
                            modelID: usageEvent.modelID,
                            turnID: usageEvent.turnID,
                            serviceTier: usageEvent.serviceTier,
                            source: usageEvent.source
                        )
                        if existingEvent != upgradedEvent {
                            ledgerSession.events[existingIndex] = upgradedEvent
                            changed = true
                            changedSession = true
                        }
                        continue
                    }

                    ledgerSession.events.append(
                        PersistedLedgerEvent(
                            timestamp: usageEvent.timestamp,
                            usage: normalizedUsage,
                            costUSD: self.billableCostCalculator(
                                self.resolvedBillingModel(
                                    eventModelID: usageEvent.modelID,
                                    source: usageEvent.source,
                                    sessionModel: record.model
                                ),
                                usageEvent.serviceTier,
                                normalizedUsage,
                                record.usage
                            ) ?? 0,
                            modelID: usageEvent.modelID,
                            turnID: usageEvent.turnID,
                            serviceTier: usageEvent.serviceTier,
                            source: usageEvent.source
                        )
                    )
                    eventIndexByKey[eventKey] = ledgerSession.events.count - 1
                    observedUsageTotal = observedUsageTotal + normalizedUsage
                    changed = true
                    changedSession = true
                }
            }

            if changedSession || updatedModel {
                ledgerSession.events.sort(by: self.shouldOrderLedgerEventBefore)
                if existingSession != ledgerSession {
                    ledger.sessions[sessionID] = ledgerSession
                    changed = true
                }
            } else if ledger.sessions[sessionID] == nil, ledgerSession.events.isEmpty == false {
                ledger.sessions[sessionID] = ledgerSession
                changed = true
            }
        }

        return changed
    }

    private func rebuiltLedgerSession(
        from cached: CachedSessionRecord,
        existingSession: PersistedLedgerSession?
    ) -> PersistedLedgerSession? {
        guard let record = cached.record,
              cached.usageEvents.isEmpty == false else {
            return nil
        }

        var persistedCostByKey: [String: Double] = [:]
        for event in existingSession?.events ?? [] {
            let eventKey = self.ledgerEventKey(
                sessionID: record.id,
                timestamp: event.timestamp,
                usage: event.usage,
                modelID: event.modelID,
                turnID: event.turnID,
                serviceTier: event.serviceTier,
                source: event.source
            )
            if persistedCostByKey[eventKey] == nil {
                persistedCostByKey[eventKey] = event.costUSD
            }
        }
        var knownEventKeys: Set<String> = []
        var events: [PersistedLedgerEvent] = []
        events.reserveCapacity(cached.usageEvents.count)

        for usageEvent in cached.usageEvents {
            let eventKey = self.ledgerEventKey(
                sessionID: record.id,
                timestamp: usageEvent.timestamp,
                usage: usageEvent.usage,
                modelID: usageEvent.modelID,
                turnID: usageEvent.turnID,
                serviceTier: usageEvent.serviceTier,
                source: usageEvent.source
            )
            guard knownEventKeys.contains(eventKey) == false else { continue }
            events.append(
                PersistedLedgerEvent(
                    timestamp: usageEvent.timestamp,
                    usage: usageEvent.usage,
                    costUSD: persistedCostByKey[eventKey]
                        ?? self.billableCostCalculator(
                            self.resolvedBillingModel(
                                eventModelID: usageEvent.modelID,
                                source: usageEvent.source,
                                sessionModel: record.model
                            ),
                            usageEvent.serviceTier,
                            usageEvent.usage,
                            record.usage
                    )
                    ?? 0,
                    modelID: usageEvent.modelID,
                    turnID: usageEvent.turnID,
                    serviceTier: usageEvent.serviceTier,
                    source: usageEvent.source
                )
            )
            knownEventKeys.insert(eventKey)
        }

        guard events.isEmpty == false else { return nil }
        events.sort(by: self.shouldOrderLedgerEventBefore)
        return PersistedLedgerSession(model: record.model, events: events)
    }

    private func alignedSeedSessions(
        _ seedSessions: [CachedSessionRecord],
        using currentSessions: [CachedSessionRecord]
    ) -> [CachedSessionRecord] {
        let currentUsageEventsBySessionID = Dictionary(
            grouping: currentSessions.compactMap { cached -> CachedSessionRecord? in
                guard cached.record != nil, cached.usageEvents.isEmpty == false else { return nil }
                return cached
            },
            by: { $0.record?.id ?? "" }
        )

        return seedSessions.map { cached in
            guard let record = cached.record,
                  cached.usageEvents.isEmpty == false,
                  let currentMatches = currentUsageEventsBySessionID[record.id] else {
                return cached
            }

            let currentUsageEvents = currentMatches
                .sorted(by: self.shouldIngestBefore)
                .map(\.usageEvents)
                .flatMap { $0 }

            return CachedSessionRecord(
                fingerprint: cached.fingerprint,
                record: cached.record,
                usageEvents: self.alignedSeedUsageEvents(
                    cached.usageEvents,
                    using: currentUsageEvents
                ),
                scanWarning: cached.scanWarning
            )
        }
    }

    private func alignedSeedUsageEvents(
        _ seedEvents: [UsageEvent],
        using currentUsageEvents: [UsageEvent]
    ) -> [UsageEvent] {
        guard currentUsageEvents.isEmpty == false else { return seedEvents }

        var timestampsByUsage = Dictionary(grouping: currentUsageEvents, by: \.usage)
            .mapValues { Array($0.map(\.timestamp)) }

        return seedEvents.map { event in
            guard var timestamps = timestampsByUsage[event.usage],
                  let matchedTimestamp = timestamps.first else {
                return event
            }
            timestamps.removeFirst()
            timestampsByUsage[event.usage] = timestamps
            return UsageEvent(
                timestamp: matchedTimestamp,
                usage: event.usage,
                modelID: event.modelID,
                turnID: event.turnID,
                serviceTier: event.serviceTier,
                source: event.source
            )
        }
    }

    private func billableEventsLocked(
        costCalculator: (String, ServiceTier, Usage, Usage) -> Double
    ) -> [BillableUsageEvent] {
        self.usageLedger.sessions.keys.sorted().flatMap { sessionID in
            let session = self.usageLedger.sessions[sessionID]
            let model = session?.model ?? ""
            let sessionUsage = (session?.events ?? []).reduce(Usage.zero) { partial, event in
                partial + event.usage
            }
            return (session?.events ?? []).map { event in
                let eventModel = self.resolvedBillingModel(
                    eventModelID: event.modelID,
                    source: event.source,
                    sessionModel: model
                )
                return BillableUsageEvent(
                    sessionID: sessionID,
                    model: eventModel,
                    sessionUsage: sessionUsage,
                    timestamp: event.timestamp,
                    usage: event.usage,
                    costUSD: eventModel.isEmpty == false
                        ? costCalculator(eventModel, event.serviceTier, event.usage, sessionUsage)
                        : event.costUSD,
                    turnID: event.turnID,
                    serviceTier: event.serviceTier,
                    source: event.source
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

    private func resolvedBillingModel(
        eventModelID: String?,
        source: EventSource,
        sessionModel: String
    ) -> String {
        if let eventModelID, eventModelID.isEmpty == false {
            return eventModelID
        }
        return source == .legacyMigration ? sessionModel : ""
    }

    private func shouldIngestBefore(_ lhs: CachedSessionRecord, _ rhs: CachedSessionRecord) -> Bool {
        if lhs.usageEvents.count != rhs.usageEvents.count {
            return lhs.usageEvents.count > rhs.usageEvents.count
        }

        let leftTokens = lhs.usageEvents.reduce(0) { partial, event in
            partial + event.usage.totalTokens
        }
        let rightTokens = rhs.usageEvents.reduce(0) { partial, event in
            partial + event.usage.totalTokens
        }
        if leftTokens != rightTokens {
            return leftTokens > rightTokens
        }

        let leftArchived = lhs.record?.isArchived ?? false
        let rightArchived = rhs.record?.isArchived ?? false
        if leftArchived != rightArchived {
            return leftArchived == false
        }

        let leftActivity = lhs.record?.lastActivityAt ?? .distantPast
        let rightActivity = rhs.record?.lastActivityAt ?? .distantPast
        if leftActivity != rightActivity {
            return leftActivity > rightActivity
        }

        let leftStartedAt = lhs.record?.startedAt ?? .distantPast
        let rightStartedAt = rhs.record?.startedAt ?? .distantPast
        if leftStartedAt != rightStartedAt {
            return leftStartedAt < rightStartedAt
        }

        return (lhs.record?.id ?? "") < (rhs.record?.id ?? "")
    }

    private func shouldOrderLedgerEventBefore(
        _ lhs: PersistedLedgerEvent,
        _ rhs: PersistedLedgerEvent
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.usage.inputTokens != rhs.usage.inputTokens {
            return lhs.usage.inputTokens < rhs.usage.inputTokens
        }
        if lhs.usage.cachedInputTokens != rhs.usage.cachedInputTokens {
            return lhs.usage.cachedInputTokens < rhs.usage.cachedInputTokens
        }
        if lhs.usage.outputTokens != rhs.usage.outputTokens {
            return lhs.usage.outputTokens < rhs.usage.outputTokens
        }
        if lhs.modelID != rhs.modelID {
            return (lhs.modelID ?? "") < (rhs.modelID ?? "")
        }
        if lhs.turnID != rhs.turnID {
            return (lhs.turnID ?? "") < (rhs.turnID ?? "")
        }
        if lhs.serviceTier != rhs.serviceTier {
            return lhs.serviceTier.rawValue < rhs.serviceTier.rawValue
        }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private func ledgerEventKey(
        sessionID: String,
        timestamp: Date,
        usage: Usage,
        modelID: String?,
        turnID: String?,
        serviceTier: ServiceTier,
        source: EventSource
    ) -> String {
        [
            sessionID,
            Self.ledgerTimestampFormatter.string(from: timestamp),
            String(usage.inputTokens),
            String(usage.cachedInputTokens),
            String(usage.outputTokens),
            modelID ?? "",
            turnID ?? "",
            serviceTier.rawValue,
            source.rawValue,
        ].joined(separator: "|")
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

        let modificationDate = values.contentModificationDate ?? .distantPast
        let normalizedModificationTime = (
            modificationDate.timeIntervalSince1970 * 1_000
        ).rounded() / 1_000
        return FileFingerprint(
            fileSize: values.fileSize ?? 0,
            modificationDate: Date(timeIntervalSince1970: normalizedModificationTime)
        )
    }

    private func parseSession(
        _ fileURL: URL,
        fingerprint: FileFingerprint,
        collectWarning _: Bool,
        inheritedUsageBaseline: Usage? = nil
    ) -> ParsedSessionResult {
        var sessionID: String?
        var sessionDate: Date?
        var model: String?
        var usageHighWater: Usage?
        var currentForkUsageHighWater: Usage?
        var billableUsage = Usage.zero
        var usageEvents: [UsageEvent] = []
        var taskLifecycleState: TaskLifecycleState?
        var isForkedSubagent = false
        var parentSessionID: String?
        var currentTurnID: String?
        var currentServiceTier: ServiceTier = .unknown
        var resolvedInheritedUsageBaseline = inheritedUsageBaseline
        var didSeeSessionMetadata = false
        var hasEmbeddedReplayMetadata = false
        var didSkipForkReplayUsage = false
        var didStartForkTask = false
        var didEncounterInvalidUsageSample = false

        let didRead = self.enumerateLines(in: fileURL) { line in
            guard let line else {
                didEncounterInvalidUsageSample = true
                return
            }
            guard self.isValidJSONLine(line) else {
                didEncounterInvalidUsageSample = true
                return
            }
            if let startInfo = self.parseSessionStartInfo(from: line) {
                if didSeeSessionMetadata, isForkedSubagent {
                    hasEmbeddedReplayMetadata = true
                    didStartForkTask = false
                    currentForkUsageHighWater = nil
                    billableUsage = .zero
                    usageEvents.removeAll(keepingCapacity: true)
                }
                didSeeSessionMetadata = true
                parentSessionID = parentSessionID ?? startInfo.parentSessionID
                if startInfo.isSubagent {
                    isForkedSubagent = true
                }
            }
            self.consumeSessionMetadata(in: line, sessionID: &sessionID, sessionDate: &sessionDate)
            self.consumeTurnContext(
                in: line,
                model: &model,
                serviceTier: &currentServiceTier
            )
            self.consumeThreadSettings(
                in: line,
                model: &model,
                serviceTier: &currentServiceTier
            )
            self.consumeTaskLifecycle(in: line, taskLifecycleState: &taskLifecycleState)
            self.consumeTurnIdentifier(in: line, turnID: &currentTurnID)
            if isForkedSubagent,
               hasEmbeddedReplayMetadata,
               self.isSubagentExecutionMarker(line) {
                didStartForkTask = true
            } else if taskLifecycleState == .running,
                      hasEmbeddedReplayMetadata == false {
                didStartForkTask = true
            }
            let isCurrentForkTask = isForkedSubagent == false || didStartForkTask
            let isUsageSampleCandidate = self.isUsageSampleCandidate(line)
            if let sample = self.parseUsageSample(from: line) {
                let incrementalUsage: Usage
                if isCurrentForkTask {
                    if isForkedSubagent, didSkipForkReplayUsage {
                        incrementalUsage = self.forkedTaskIncrementalUsage(
                            sample: sample,
                            inheritedUsageHighWater: usageHighWater,
                            currentForkUsageHighWater: currentForkUsageHighWater
                        )
                        currentForkUsageHighWater = currentForkUsageHighWater
                            .map { $0.highWater(with: sample.totalUsage) }
                            ?? sample.totalUsage
                    } else {
                        if let usageHighWater {
                            incrementalUsage = sample.totalUsage.delta(from: usageHighWater)
                        } else if let reportedIncrement = sample.incrementalUsage {
                            incrementalUsage = reportedIncrement
                            if parentSessionID != nil,
                               isForkedSubagent == false,
                               resolvedInheritedUsageBaseline == nil {
                                resolvedInheritedUsageBaseline = sample.totalUsage.delta(from: reportedIncrement)
                            }
                        } else if parentSessionID != nil, isForkedSubagent == false {
                            incrementalUsage = resolvedInheritedUsageBaseline.map {
                                sample.totalUsage.delta(from: $0)
                            } ?? .zero
                        } else {
                            incrementalUsage = sample.totalUsage
                        }
                    }
                } else {
                    incrementalUsage = .zero
                    didSkipForkReplayUsage = true
                }

                let eventTimestamp = sample.timestamp
                    ?? fingerprint.modificationDate.addingTimeInterval(Double(usageEvents.count) / 1_000)
                if incrementalUsage.isZero == false {
                    let eventModel = sample.modelID ?? model
                    let eventTier = sample.serviceTier == .unknown
                        ? currentServiceTier
                        : sample.serviceTier
                    let eventSource: EventSource = if isForkedSubagent {
                        .subagent
                    } else if parentSessionID != nil {
                        .fork
                    } else {
                        .nativeSession
                    }
                    usageEvents.append(
                        UsageEvent(
                            timestamp: eventTimestamp,
                            usage: incrementalUsage,
                            modelID: eventModel,
                            turnID: sample.turnID ?? currentTurnID,
                            serviceTier: eventTier,
                            source: eventSource
                        )
                    )
                    billableUsage = billableUsage + incrementalUsage
                }
                usageHighWater = usageHighWater.map { $0.highWater(with: sample.totalUsage) } ?? sample.totalUsage
            } else if isUsageSampleCandidate {
                didEncounterInvalidUsageSample = true
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
                usage: billableUsage,
                taskLifecycleState: taskLifecycleState,
                parentSessionID: parentSessionID,
                isSubagent: isForkedSubagent,
                inheritedUsageBaseline: resolvedInheritedUsageBaseline
            )
            warning = didEncounterInvalidUsageSample
                ? RecordsSnapshotWarning(
                    sessionFilePath: fileURL.path,
                    kind: .incompleteSessionRecord,
                    message: "Unable to parse one or more token usage events."
                )
                : nil
        } else {
            record = nil
            warning = RecordsSnapshotWarning(
                sessionFilePath: fileURL.path,
                kind: didRead ? .incompleteSessionRecord : .unreadableSessionFile,
                message: didRead
                    ? "Missing required session metadata or model."
                    : "Unable to read session file."
            )
        }

        return ParsedSessionResult(
            cachedRecord: CachedSessionRecord(
                fingerprint: fingerprint,
                record: record,
                usageEvents: usageEvents,
                scanWarning: warning
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
            guard let line else { return }
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

    private func consumeTurnContext(
        in line: String,
        model: inout String?,
        serviceTier: inout ServiceTier
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
            let parsedTier = ServiceTier.parse(
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
        serviceTier: inout ServiceTier
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
            ?? settings?["model_name"] as? String
        {
            model = self.normalizeModel(settingsModel)
        }
        let parsedTier = ServiceTier.parse(
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

    private func forkedTaskIncrementalUsage(
        sample: UsageSample,
        inheritedUsageHighWater: Usage?,
        currentForkUsageHighWater: Usage?
    ) -> Usage {
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
                modelID: self.normalizedModel(
                    payload["model"] as? String ?? payload["model_name"] as? String
                ),
                turnID: payload["turn_id"] as? String
                    ?? payload["turnId"] as? String
                    ?? payload["id"] as? String,
                serviceTier: ServiceTier.parse(payload["service_tier"] as? String)
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
            serviceTier: ServiceTier.parse(
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

    private func isValidJSONLine(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return false
        }
        return true
    }

    private func normalizedModel(_ model: String?) -> String? {
        guard let model else { return nil }
        let normalized = self.normalizeModel(model)
        return normalized.isEmpty ? nil : normalized
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

    private func enumerateLines(in fileURL: URL, handleLine: (String?) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        var buffer = Data()
        var scanOffset = 0
        let chunkSize = 64 * 1024
        let newline = UInt8(ascii: "\n")

        do {
            while let chunk = try handle.read(upToCount: chunkSize), chunk.isEmpty == false {
                buffer.append(chunk)
                while true {
                    let searchStart = buffer.index(
                        buffer.startIndex,
                        offsetBy: min(scanOffset, buffer.count)
                    )
                    guard let newlineIndex = buffer[searchStart...].firstIndex(of: newline) else {
                        scanOffset = buffer.count
                        break
                    }
                    autoreleasepool {
                        self.emitLine(from: buffer[..<newlineIndex], handleLine: handleLine)
                    }
                    let nextIndex = buffer.index(after: newlineIndex)
                    buffer.removeSubrange(buffer.startIndex..<nextIndex)
                    scanOffset = 0
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

    private func emitLine(from bytes: Data.SubSequence, handleLine: (String?) -> Void) {
        if let lineType = self.topLevelType(in: bytes),
           Self.skippedTopLevelLineTypes.contains(lineType) {
            return
        }
        if bytes.isEmpty || (bytes.count == 1 && bytes.first == UInt8(ascii: "\r")) {
            return
        }
        handleLine(self.normalizedLine(from: bytes))
    }

    private func topLevelType(in bytes: Data.SubSequence) -> String? {
        var index = bytes.startIndex
        var depth = 0

        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let tokenStart = bytes.index(after: index)
                var tokenEnd = tokenStart
                var escaped = false

                while tokenEnd < bytes.endIndex {
                    let tokenByte = bytes[tokenEnd]
                    if escaped {
                        escaped = false
                    } else if tokenByte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if tokenByte == UInt8(ascii: "\"") {
                        break
                    }
                    tokenEnd = bytes.index(after: tokenEnd)
                }

                guard tokenEnd < bytes.endIndex else { return nil }
                if depth == 1,
                   bytes[tokenStart..<tokenEnd].elementsEqual(Self.topLevelTypeKey) {
                    var valueStart = bytes.index(after: tokenEnd)
                    while valueStart < bytes.endIndex, Self.isJSONWhitespace(bytes[valueStart]) {
                        valueStart = bytes.index(after: valueStart)
                    }
                    if valueStart < bytes.endIndex, bytes[valueStart] == UInt8(ascii: ":") {
                        valueStart = bytes.index(after: valueStart)
                        while valueStart < bytes.endIndex, Self.isJSONWhitespace(bytes[valueStart]) {
                            valueStart = bytes.index(after: valueStart)
                        }
                        if valueStart < bytes.endIndex, bytes[valueStart] == UInt8(ascii: "\"") {
                            let valueEnd = bytes[valueStart...].dropFirst().firstIndex(of: UInt8(ascii: "\""))
                            if let valueEnd {
                                return String(decoding: bytes[bytes.index(after: valueStart)..<valueEnd], as: UTF8.self)
                            }
                        }
                    }
                }

                index = bytes.index(after: tokenEnd)
                continue
            }

            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
            }
            index = bytes.index(after: index)
        }

        return nil
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
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

        guard persisted.version == self.persistedUsageLedgerVersion || persisted.version == 3 else {
            return PersistedUsageLedger.empty(version: self.persistedUsageLedgerVersion)
        }

        guard persisted.version != self.persistedUsageLedgerVersion else {
            return persisted
        }

        var migrated = persisted
        migrated.version = self.persistedUsageLedgerVersion
        for sessionID in migrated.sessions.keys {
            guard var session = migrated.sessions[sessionID] else { continue }
            session.events = session.events.map { event in
                PersistedLedgerEvent(
                    timestamp: event.timestamp,
                    usage: event.usage,
                    costUSD: event.costUSD,
                    modelID: event.modelID ?? session.model,
                    turnID: event.turnID,
                    serviceTier: event.serviceTier,
                    source: .legacyMigration
                )
            }
            migrated.sessions[sessionID] = session
        }
        _ = self.persistUsageLedger(migrated)
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

    nonisolated(unsafe) private static let ledgerTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
