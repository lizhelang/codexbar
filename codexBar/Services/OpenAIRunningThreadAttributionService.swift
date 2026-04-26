import Foundation

struct OpenAIRunningThreadAttribution: Equatable {
    struct ThreadAttribution: Equatable {
        let threadID: String
        let source: String
        let cwd: String
        let title: String
        let lastRuntimeAt: Date
        let accountID: String?
    }

    struct Summary: Equatable {
        enum Availability: Equatable {
            case available
            case unavailable
        }

        static let empty = Summary(
            availability: .available,
            runningThreadCounts: [:],
            unknownThreadCount: 0
        )

        static let unavailable = Summary(
            availability: .unavailable,
            runningThreadCounts: [:],
            unknownThreadCount: 0
        )

        let availability: Availability
        let runningThreadCounts: [String: Int]
        let unknownThreadCount: Int

        var isUnavailable: Bool {
            self.availability == .unavailable
        }

        var runningAccountCount: Int {
            self.runningThreadCounts.count
        }

        var attributedRunningThreadCount: Int {
            self.runningThreadCounts.values.reduce(0, +)
        }

        var totalRunningThreadCount: Int {
            self.attributedRunningThreadCount + self.unknownThreadCount
        }

        func runningThreadCount(for accountID: String) -> Int {
            self.runningThreadCounts[accountID, default: 0]
        }
    }

    static let empty = OpenAIRunningThreadAttribution(
        threads: [],
        summary: .empty,
        recentActivityWindow: CodexThreadRuntimeStore.defaultRecentActivityWindow,
        diagnosticMessage: nil,
        unavailableReason: nil
    )

    let threads: [ThreadAttribution]
    let summary: Summary
    let recentActivityWindow: TimeInterval
    let diagnosticMessage: String?
    let unavailableReason: CodexThreadRuntimeStore.UnavailableReason?

    var activeThreadIDs: Set<String> {
        Set(self.threads.map(\.threadID))
    }
}

struct OpenAIRunningThreadAttributionService {
    static let shared = OpenAIRunningThreadAttributionService()
    static let defaultRecentActivityWindow = CodexThreadRuntimeStore.defaultRecentActivityWindow

    private let runtimeStore: CodexThreadRuntimeStore
    private let sessionLogStore: SessionLogStore
    private let switchJournalStore: SwitchJournalStore
    private let aggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring

    init(
        runtimeStore: CodexThreadRuntimeStore = .shared,
        sessionLogStore: SessionLogStore = .shared,
        switchJournalStore: SwitchJournalStore = SwitchJournalStore(),
        aggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore()
    ) {
        self.runtimeStore = runtimeStore
        self.sessionLogStore = sessionLogStore
        self.switchJournalStore = switchJournalStore
        self.aggregateRouteJournalStore = aggregateRouteJournalStore
    }

    nonisolated func load(
        now: Date = Date(),
        recentActivityWindow: TimeInterval = Self.defaultRecentActivityWindow
    ) -> OpenAIRunningThreadAttribution {
        let runtimeSnapshot = self.runtimeStore.loadRunningThreads(
            now: now,
            recentActivityWindow: recentActivityWindow
        )

        let activations = self.switchJournalStore.activationHistory()
        let aggregateRouteHistory = self.aggregateRouteJournalStore.routeHistory()
        let sessionRecords = self.sessionLogStore.sessionLifecycleRecords()
        let rustResult =
            (try? RustPortableCoreAdapter.shared.attributeRunningThreads(
            PortableCoreRunningThreadAttributionRequest(
                recentActivityWindowSeconds: runtimeSnapshot.recentActivityWindow,
                unavailableReason: runtimeSnapshot.unavailableReason?.diagnosticMessage,
                threads: runtimeSnapshot.threads.map(PortableCoreRuntimeThreadInput.legacy(from:)),
                completedSessions: sessionRecords.map(PortableCoreSessionLifecycleInput.legacy(from:)),
                aggregateRoutes: aggregateRouteHistory.map(PortableCoreAggregateRouteRecordInput.legacy(from:)),
                activations: activations.map(PortableCoreActivationRecord.legacy(from:))
            ),
            buildIfNeeded: false
        )) ?? PortableCoreRunningThreadAttributionResult.failClosed(
            recentActivityWindowSeconds: runtimeSnapshot.recentActivityWindow
        )
        return rustResult.runningThreadAttribution()
    }
}
