import Foundation

protocol OpenAIAggregateGatewayLeaseStoring {
    func loadProcessIDs() -> Set<pid_t>
    func saveProcessIDs(_ processIDs: Set<pid_t>)
    func clear()
}

struct OpenAIAggregateRouteRecord: Codable, Equatable {
    let timestamp: Date
    let threadID: String
    let accountID: String
}

protocol OpenAIAggregateRouteJournalStoring {
    func recordRoute(threadID: String, accountID: String, timestamp: Date)
    func routeHistory() -> [OpenAIAggregateRouteRecord]
}

private struct OpenAIAggregateGatewayLeaseSnapshot: Codable, Equatable {
    var aggregateLeaseProcessIDs: [Int32]
    var updatedAt: Date
}

final class OpenAIAggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoring {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = CodexPaths.openAIGatewayStateURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func loadProcessIDs() -> Set<pid_t> {
        guard let data = try? Data(contentsOf: self.fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(OpenAIAggregateGatewayLeaseSnapshot.self, from: data) else {
            return []
        }
        return Set(snapshot.aggregateLeaseProcessIDs.map { pid_t($0) })
    }

    func saveProcessIDs(_ processIDs: Set<pid_t>) {
        guard processIDs.isEmpty == false else {
            self.clear()
            return
        }

        try? CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = OpenAIAggregateGatewayLeaseSnapshot(
            aggregateLeaseProcessIDs: processIDs.map { Int32($0) }.sorted(),
            updatedAt: Date()
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.fileURL)
    }

    func clear() {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return }
        try? self.fileManager.removeItem(at: self.fileURL)
    }
}

private struct OpenAIAggregateRouteJournalSnapshot: Codable, Equatable {
    var routes: [OpenAIAggregateRouteRecord]
    var updatedAt: Date
}

final class OpenAIAggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "lzl.codexbar.openai-gateway.route-journal")

    init(
        fileURL: URL = CodexPaths.openAIGatewayRouteJournalURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func recordRoute(threadID: String, accountID: String, timestamp: Date = Date()) {
        guard threadID.isEmpty == false, accountID.isEmpty == false else { return }

        self.queue.sync {
            var snapshot = self.loadSnapshot()
            if let last = snapshot.routes.last(where: { $0.threadID == threadID }),
               last.accountID == accountID {
                return
            }

            snapshot.routes.append(
                OpenAIAggregateRouteRecord(
                    timestamp: timestamp,
                    threadID: threadID,
                    accountID: accountID
                )
            )
            snapshot.updatedAt = timestamp
            self.pruneRoutes(in: &snapshot, referenceDate: timestamp)
            self.saveSnapshot(snapshot)
        }
    }

    func routeHistory() -> [OpenAIAggregateRouteRecord] {
        self.queue.sync {
            self.loadSnapshot().routes.sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                if lhs.threadID != rhs.threadID {
                    return lhs.threadID < rhs.threadID
                }
                return lhs.accountID < rhs.accountID
            }
        }
    }

    private func loadSnapshot() -> OpenAIAggregateRouteJournalSnapshot {
        guard let data = try? Data(contentsOf: self.fileURL) else {
            return OpenAIAggregateRouteJournalSnapshot(routes: [], updatedAt: .distantPast)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(OpenAIAggregateRouteJournalSnapshot.self, from: data))
            ?? OpenAIAggregateRouteJournalSnapshot(routes: [], updatedAt: .distantPast)
    }

    private func saveSnapshot(_ snapshot: OpenAIAggregateRouteJournalSnapshot) {
        if snapshot.routes.isEmpty {
            if self.fileManager.fileExists(atPath: self.fileURL.path) {
                try? self.fileManager.removeItem(at: self.fileURL)
            }
            return
        }

        try? CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.fileURL)
    }

    private func pruneRoutes(
        in snapshot: inout OpenAIAggregateRouteJournalSnapshot,
        referenceDate: Date
    ) {
        let cutoff = referenceDate.addingTimeInterval(-(60 * 60 * 24))
        snapshot.routes = snapshot.routes.filter { $0.timestamp >= cutoff }

        let maxEntries = 512
        guard snapshot.routes.count > maxEntries else { return }
        snapshot.routes = Array(snapshot.routes.suffix(maxEntries))
    }
}
