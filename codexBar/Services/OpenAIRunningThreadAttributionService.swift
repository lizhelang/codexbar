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
}

struct OpenAIRunningThreadAttributionService {
    static let shared = OpenAIRunningThreadAttributionService()
    static let defaultRecentActivityWindow = CodexThreadRuntimeStore.defaultRecentActivityWindow

    private static let openAIProviderID = "openai-oauth"

    private let runtimeStore: CodexThreadRuntimeStore
    private let sessionLogStore: SessionLogStore
    private let switchJournalStore: SwitchJournalStore

    init(
        runtimeStore: CodexThreadRuntimeStore = .shared,
        sessionLogStore: SessionLogStore = .shared,
        switchJournalStore: SwitchJournalStore = SwitchJournalStore()
    ) {
        self.runtimeStore = runtimeStore
        self.sessionLogStore = sessionLogStore
        self.switchJournalStore = switchJournalStore
    }

    func load(
        now: Date = Date(),
        recentActivityWindow: TimeInterval = Self.defaultRecentActivityWindow
    ) -> OpenAIRunningThreadAttribution {
        let runtimeSnapshot = self.runtimeStore.loadRunningThreads(
            now: now,
            recentActivityWindow: recentActivityWindow
        )

        if let unavailableReason = runtimeSnapshot.unavailableReason {
            return OpenAIRunningThreadAttribution(
                threads: [],
                summary: .unavailable,
                recentActivityWindow: runtimeSnapshot.recentActivityWindow,
                diagnosticMessage: unavailableReason.diagnosticMessage,
                unavailableReason: unavailableReason
            )
        }

        let activations = self.switchJournalStore.activationHistory()
        let sessionRecordsByID = Dictionary(
            uniqueKeysWithValues: self.sessionLogStore.currentSessionRecords().map { ($0.id, $0) }
        )
        var threads: [OpenAIRunningThreadAttribution.ThreadAttribution] = []
        var runningThreadCounts: [String: Int] = [:]
        var unknownThreadCount = 0

        threads.reserveCapacity(runtimeSnapshot.threads.count)

        for thread in runtimeSnapshot.threads {
            if let sessionRecord = sessionRecordsByID[thread.threadID],
               sessionRecord.taskLifecycleState == .completed,
               sessionRecord.lastActivityAt >= thread.lastRuntimeAt {
                continue
            }

            // Attribute the current run to the provider/account that was active when
            // the latest runtime log landed, not when the thread was originally created.
            let accountID = self.accountID(for: thread.lastRuntimeAt, activations: activations)
            if let accountID {
                runningThreadCounts[accountID, default: 0] += 1
            } else {
                unknownThreadCount += 1
            }

            threads.append(
                OpenAIRunningThreadAttribution.ThreadAttribution(
                    threadID: thread.threadID,
                    source: thread.source,
                    cwd: thread.cwd,
                    title: thread.title,
                    lastRuntimeAt: thread.lastRuntimeAt,
                    accountID: accountID
                )
            )
        }

        return OpenAIRunningThreadAttribution(
            threads: threads,
            summary: .init(
                availability: .available,
                runningThreadCounts: runningThreadCounts,
                unknownThreadCount: unknownThreadCount
            ),
            recentActivityWindow: runtimeSnapshot.recentActivityWindow,
            diagnosticMessage: nil,
            unavailableReason: nil
        )
    }

    private func accountID(
        for lastRuntimeAt: Date,
        activations: [SwitchJournalStore.ActivationRecord]
    ) -> String? {
        guard let activation = activations.last(where: { $0.timestamp <= lastRuntimeAt }),
              activation.providerID == Self.openAIProviderID,
              let accountID = activation.accountID,
              accountID.isEmpty == false else {
            return nil
        }

        return accountID
    }
}
