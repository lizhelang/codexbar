import Foundation

enum LocalCostRefreshStrength: Int, Comparable, Sendable {
    case snapshotOnly
    case incremental
    case rebuildAll

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct LocalCostRefreshProgress: Equatable, Sendable {
    var processedBytes: Int64
    var totalBytes: Int64
    var completedFiles: Int
    var totalFiles: Int

    static let zero = LocalCostRefreshProgress(
        processedBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0
    )

    var fractionCompleted: Double? {
        if self.totalBytes > 0 {
            return min(1, max(0, Double(self.processedBytes) / Double(self.totalBytes)))
        }
        guard self.totalFiles > 0 else { return nil }
        return min(1, max(0, Double(self.completedFiles) / Double(self.totalFiles)))
    }

    func mergedMonotonically(with newer: Self) -> Self {
        LocalCostRefreshProgress(
            processedBytes: max(self.processedBytes, newer.processedBytes),
            totalBytes: max(self.totalBytes, newer.totalBytes),
            completedFiles: max(self.completedFiles, newer.completedFiles),
            totalFiles: max(self.totalFiles, newer.totalFiles)
        )
    }
}

struct LocalCostRefreshOutcome: Equatable, Sendable {
    var summary: LocalCostSummary?
    var isComplete: Bool
    var mayReplaceLastKnownGood: Bool
    var warningCount: Int
    var lastRawSessionScanAt: Date?
    var latestUsageEventAt: Date?
    var progress: LocalCostRefreshProgress
    var errorMessage: String?
}

struct LocalCostRefreshState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case scanning
        case success
        case partial
        case failed(String)
    }

    var phase: Phase
    var activeStrength: LocalCostRefreshStrength?
    var progress: LocalCostRefreshProgress
    var lastRawSessionScanAt: Date?
    var latestUsageEventAt: Date?
    var warningCount: Int

    static let idle = LocalCostRefreshState(
        phase: .idle,
        activeStrength: nil,
        progress: .zero,
        lastRawSessionScanAt: nil,
        latestUsageEventAt: nil,
        warningCount: 0
    )

    var isScanning: Bool {
        self.phase == .scanning
    }
}
