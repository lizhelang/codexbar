import Foundation

struct OpenAILiveSessionAttribution: Equatable {
    struct SessionAttribution: Equatable {
        let sessionID: String
        let startedAt: Date
        let lastActivityAt: Date
        let accountID: String?
    }

    struct LiveSummary: Equatable {
        let inUseSessionCounts: [String: Int]
        let unknownSessionCount: Int

        nonisolated var inUseAccountCount: Int {
            self.inUseSessionCounts.count
        }

        nonisolated var totalInUseSessionCount: Int {
            self.inUseSessionCounts.values.reduce(0, +)
        }

        nonisolated func inUseSessionCount(for accountID: String) -> Int {
            self.inUseSessionCounts[accountID, default: 0]
        }
    }

    nonisolated static let empty = OpenAILiveSessionAttribution(
        sessions: [],
        inUseSessionCounts: [:],
        unknownSessionCount: 0,
        recentActivityWindow: OpenAILiveSessionAttributionService.defaultRecentActivityWindow
    )

    let sessions: [SessionAttribution]
    let inUseSessionCounts: [String: Int]
    let unknownSessionCount: Int
    let recentActivityWindow: TimeInterval

    nonisolated var inUseAccountCount: Int {
        self.inUseSessionCounts.count
    }

    nonisolated var totalInUseSessionCount: Int {
        self.inUseSessionCounts.values.reduce(0, +)
    }

    nonisolated func inUseSessionCount(for accountID: String) -> Int {
        self.inUseSessionCounts[accountID, default: 0]
    }

    nonisolated func liveSummary(now: Date = Date()) -> LiveSummary {
        var inUseSessionCounts: [String: Int] = [:]
        var unknownSessionCount = 0

        for session in self.sessions where max(0, now.timeIntervalSince(session.lastActivityAt)) <= self.recentActivityWindow {
            if let accountID = session.accountID, accountID.isEmpty == false {
                inUseSessionCounts[accountID, default: 0] += 1
            } else {
                unknownSessionCount += 1
            }
        }

        return LiveSummary(
            inUseSessionCounts: inUseSessionCounts,
            unknownSessionCount: unknownSessionCount
        )
    }
}

struct OpenAILiveSessionAttributionService {
    static let shared = OpenAILiveSessionAttributionService()
    static let defaultRecentActivityWindow: TimeInterval = 60 * 60

    private let sessionLogStore: SessionLogStore
    private let switchJournalStore: SwitchJournalStore

    init(
        sessionLogStore: SessionLogStore = .shared,
        switchJournalStore: SwitchJournalStore = SwitchJournalStore()
    ) {
        self.sessionLogStore = sessionLogStore
        self.switchJournalStore = switchJournalStore
    }

    func load(
        now: Date = Date(),
        recentActivityWindow: TimeInterval = Self.defaultRecentActivityWindow
    ) -> OpenAILiveSessionAttribution {
        let liveSessions = self.sessionLogStore.currentSessionRecords()
            .filter { max(0, now.timeIntervalSince($0.lastActivityAt)) <= recentActivityWindow }
            .sorted { $0.startedAt < $1.startedAt }
        let activations = self.switchJournalStore.activationHistory()

        let rustResult =
            (try? RustPortableCoreAdapter.shared.attributeLiveSessions(
            PortableCoreLiveSessionAttributionRequest(
                now: now.timeIntervalSince1970,
                recentActivityWindowSeconds: recentActivityWindow,
                sessions: liveSessions.map(PortableCoreLiveSessionInput.legacy(from:)),
                activations: activations.map(PortableCoreActivationRecord.legacy(from:))
            ),
            buildIfNeeded: false
        )) ?? PortableCoreLiveSessionAttributionResult.failClosed(
            recentActivityWindowSeconds: recentActivityWindow
        )
        return rustResult.liveSessionAttribution()
    }
}
