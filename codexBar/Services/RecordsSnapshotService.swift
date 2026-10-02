import Foundation

enum RecordsRefreshMode: Equatable, Sendable {
    case incremental
    case rebuildAll
}

enum RecordsSnapshotWarningKind: String, Codable, Equatable, Sendable {
    case unreadableSessionFile
    case incompleteSessionRecord
    /// The token events are readable, but the rollout did not record their model.
    case missingModel
}

struct RecordsSnapshotWarning: Codable, Equatable, Identifiable, Sendable {
    let sessionFilePath: String
    let kind: RecordsSnapshotWarningKind
    let message: String

    var id: String {
        "\(self.kind.rawValue)|\(self.sessionFilePath)|\(self.message)"
    }
}

struct HistoricalModelRecord: Codable, Equatable, Identifiable, Sendable {
    let modelID: String
    let sessionCount: Int
    let lastSeenAt: Date

    var id: String { self.modelID }
}

struct HistoricalSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let sessionID: String
    let modelID: String
    let startedAt: Date
    let lastActivityAt: Date
    let isArchived: Bool
    let totalTokens: Int
    var title: String? = nil
    var projectPath: String? = nil

    var id: String { self.sessionID }
}

struct RecordsSourceSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let refreshMode: RecordsRefreshMode
    let sessions: [HistoricalSessionRecord]
    let warnings: [RecordsSnapshotWarning]
}

struct RecordsSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let refreshMode: RecordsRefreshMode
    let models: [HistoricalModelRecord]
    let sessions: [HistoricalSessionRecord]
    let warnings: [RecordsSnapshotWarning]
}

protocol RecordsSourceSnapshotLoading: Sendable {
    func loadRecordsSourceSnapshot(refreshMode: RecordsRefreshMode) async throws -> RecordsSourceSnapshot
}

/// Optional fast path with a strict no-log-scan contract. It must never fall back to a refresh.
protocol RecordsCachedSourceSnapshotLoading: Sendable {
    func loadCachedRecordsSourceSnapshot() async throws -> RecordsSourceSnapshot
}

protocol RecordsSnapshotServing: Sendable {
    func loadCurrent() async throws -> RecordsSnapshot
    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot
}

enum RecordsSnapshotServiceError: LocalizedError, Equatable {
    case cachedSnapshotUnavailable
    case requestSuperseded
    case timedOut(timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .cachedSnapshotUnavailable:
            return "The records source does not provide a cached snapshot."
        case .requestSuperseded:
            return "Records request was superseded by a newer request."
        case .timedOut(let timeout):
            let seconds = String(format: "%.1f", timeout)
            return "Records refresh timed out after \(seconds) seconds."
        }
    }
}

nonisolated struct RecordsSnapshotService: RecordsSnapshotServing {
    private let sourceLoader: any RecordsSourceSnapshotLoading
    private let requestCoordinator: RecordsSnapshotRequestCoordinator
    private let displayMetadataLoader: @Sendable () -> [String: CodexSessionDisplayMetadata]

    init(
        sourceLoader: any RecordsSourceSnapshotLoading = SessionLogStore.shared,
        requestCoordinator: RecordsSnapshotRequestCoordinator = RecordsSnapshotRequestCoordinator(),
        displayMetadataLoader: @escaping @Sendable () -> [String: CodexSessionDisplayMetadata] = {
            CodexSessionMetadataStore().load()
        }
    ) {
        self.sourceLoader = sourceLoader
        self.requestCoordinator = requestCoordinator
        self.displayMetadataLoader = displayMetadataLoader
    }

    /// Menu presentation uses the last scan result plus read-only SQLite display metadata.
    /// An empty cache stays empty; loading this method never enumerates or parses rollout files.
    @concurrent
    func loadCached() async throws -> RecordsSnapshot {
        guard let cachedLoader = self.sourceLoader as? any RecordsCachedSourceSnapshotLoading else {
            throw RecordsSnapshotServiceError.cachedSnapshotUnavailable
        }
        let source = try await cachedLoader.loadCachedRecordsSourceSnapshot()
        try Task.checkCancellation()
        return self.makeSnapshot(from: source)
    }

    func loadCurrent() async throws -> RecordsSnapshot {
        try await self.requestCoordinator.runRequest(
            refreshMode: .incremental,
            timeout: nil,
            sourceLoader: self.sourceLoader,
            makeSnapshot: { self.makeSnapshot(from: $0) }
        )
    }

    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot {
        try await self.requestCoordinator.runRequest(
            refreshMode: .rebuildAll,
            timeout: max(0, timeout),
            sourceLoader: self.sourceLoader,
            makeSnapshot: { self.makeSnapshot(from: $0) }
        )
    }

    private func makeSnapshot(from sourceSnapshot: RecordsSourceSnapshot) -> RecordsSnapshot {
        // Enrich display fields only. Missing optional state databases must not
        // affect rollout usage, dates, model attribution, or scan warnings.
        let metadata = self.displayMetadataLoader()
        let sessions = sourceSnapshot.sessions.map { source in
            var record = source
            if let display = metadata[source.sessionID] {
                record.title = display.title ?? source.title
                record.projectPath = display.projectPath ?? source.projectPath
            }
            return record
        }
        return RecordsSnapshot(
            generatedAt: sourceSnapshot.generatedAt,
            refreshMode: sourceSnapshot.refreshMode,
            models: Self.models(from: sourceSnapshot.sessions),
            sessions: sessions.sorted(by: Self.shouldSortSessionsBefore),
            warnings: sourceSnapshot.warnings.sorted(by: Self.shouldSortWarningsBefore)
        )
    }

    private static func models(from sessions: [HistoricalSessionRecord]) -> [HistoricalModelRecord] {
        let groupedSessions = Dictionary(
            grouping: sessions.filter { $0.modelID != SessionLogStore.unknownModelID },
            by: \.modelID
        )
        return groupedSessions.map { modelID, groupedRecords in
            HistoricalModelRecord(
                modelID: modelID,
                sessionCount: groupedRecords.count,
                lastSeenAt: groupedRecords.map(\.lastActivityAt).max() ?? .distantPast
            )
        }
        .sorted(by: Self.shouldSortModelsBefore)
    }

    private static func shouldSortSessionsBefore(
        _ lhs: HistoricalSessionRecord,
        _ rhs: HistoricalSessionRecord
    ) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.sessionID < rhs.sessionID
    }

    private static func shouldSortModelsBefore(
        _ lhs: HistoricalModelRecord,
        _ rhs: HistoricalModelRecord
    ) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt {
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        if lhs.sessionCount != rhs.sessionCount {
            return lhs.sessionCount > rhs.sessionCount
        }
        return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
    }

    private static func shouldSortWarningsBefore(
        _ lhs: RecordsSnapshotWarning,
        _ rhs: RecordsSnapshotWarning
    ) -> Bool {
        if lhs.sessionFilePath != rhs.sessionFilePath {
            return lhs.sessionFilePath < rhs.sessionFilePath
        }
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.message < rhs.message
    }
}

actor RecordsSnapshotRequestCoordinator: Sendable {
    private var latestRequestID: UInt64 = 0
    private var activeRequestID: UInt64?
    private var activeTask: Task<RecordsSnapshot, Error>?

    func runRequest(
        refreshMode: RecordsRefreshMode,
        timeout: TimeInterval?,
        sourceLoader: any RecordsSourceSnapshotLoading,
        makeSnapshot: @escaping @Sendable (RecordsSourceSnapshot) -> RecordsSnapshot
    ) async throws -> RecordsSnapshot {
        self.latestRequestID &+= 1
        let requestID = self.latestRequestID

        self.activeTask?.cancel()

        let task = Task<RecordsSnapshot, Error> {
            let sourceSnapshot = try await sourceLoader.loadRecordsSourceSnapshot(refreshMode: refreshMode)
            return makeSnapshot(sourceSnapshot)
        }

        self.activeRequestID = requestID
        self.activeTask = task

        do {
            let snapshot = try await self.resolve(task, timeout: timeout)
            guard self.activeRequestID == requestID else {
                throw RecordsSnapshotServiceError.requestSuperseded
            }
            self.clearActiveRequest(ifMatching: requestID)
            return snapshot
        } catch {
            if error is CancellationError {
                if self.activeRequestID == requestID {
                    self.clearActiveRequest(ifMatching: requestID)
                }
                throw RecordsSnapshotServiceError.requestSuperseded
            }

            if self.activeRequestID == requestID {
                self.clearActiveRequest(ifMatching: requestID)
            }
            throw error
        }
    }

    private func clearActiveRequest(ifMatching requestID: UInt64) {
        guard self.activeRequestID == requestID else { return }
        self.activeRequestID = nil
        self.activeTask = nil
    }

    private func resolve(
        _ task: Task<RecordsSnapshot, Error>,
        timeout: TimeInterval?
    ) async throws -> RecordsSnapshot {
        guard let timeout else {
            return try await task.value
        }

        let clampedTimeout = max(0, timeout)
        return try await withThrowingTaskGroup(of: Result<RecordsSnapshot, Error>.self) { group in
            group.addTask {
                do {
                    return .success(try await task.value)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                if clampedTimeout > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
                }
                return .failure(RecordsSnapshotServiceError.timedOut(timeout: clampedTimeout))
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw RecordsSnapshotServiceError.requestSuperseded
            }

            switch first {
            case .success(let snapshot):
                return snapshot
            case .failure(let error):
                if case RecordsSnapshotServiceError.timedOut = error {
                    task.cancel()
                }
                throw error
            }
        }
    }
}
