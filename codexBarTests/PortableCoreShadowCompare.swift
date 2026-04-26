import Foundation

enum PortableCoreMismatchSeverity: String, Codable, Equatable {
    case blocker
    case nonBlocker
}

struct PortableCoreMismatch: Codable, Equatable {
    var category: String
    var severity: PortableCoreMismatchSeverity
    var scenarioID: String
    var detail: String
}

struct PortableCoreShadowCompareRecord: Codable, Equatable {
    var scenarioID: String
    var bucket: String
    var mismatches: [PortableCoreMismatch]
    var durationMilliseconds: Double
}

struct PortableCoreShadowCompareSummary: Codable, Equatable {
    var totalSamples: Int
    var distinctScenarioCount: Int
    var blockerCount: Int
    var nonBlockerCount: Int
    var bucketCounts: [String: Int]
    var mismatches: [PortableCoreMismatch]

    static func summarize(_ records: [PortableCoreShadowCompareRecord]) -> PortableCoreShadowCompareSummary {
        let mismatches = records.flatMap(\.mismatches)
        return PortableCoreShadowCompareSummary(
            totalSamples: records.count,
            distinctScenarioCount: Set(records.map(\.scenarioID)).count,
            blockerCount: mismatches.filter { $0.severity == .blocker }.count,
            nonBlockerCount: mismatches.filter { $0.severity == .nonBlocker }.count,
            bucketCounts: Dictionary(records.map { ($0.bucket, 1) }, uniquingKeysWith: +),
            mismatches: mismatches
        )
    }
}

enum PortableCoreShadowCompareService {
    static func compare<Value: Encodable & Equatable>(
        scenarioID: String,
        bucket: String,
        legacy: Value,
        rust: Value,
        blockerCategory: String,
        durationMilliseconds: Double
    ) throws -> PortableCoreShadowCompareRecord {
        let legacyData: Data
        let rustData: Data
        if blockerCategory == "render-codec-output",
           let legacyRender = legacy as? PortableCoreRenderCodecOutput,
           let rustRender = rust as? PortableCoreRenderCodecOutput {
            legacyData = try JSONEncoder.portableCore.encode(normalizedRenderCodecOutput(legacyRender))
            rustData = try JSONEncoder.portableCore.encode(normalizedRenderCodecOutput(rustRender))
        } else if blockerCategory == "canonical-config-account",
                  let legacyCanonical = legacy as? PortableCoreCanonicalizationResult,
                  let rustCanonical = rust as? PortableCoreCanonicalizationResult {
            legacyData = try JSONEncoder.portableCore.encode(
                normalizedCanonicalizationResult(legacyCanonical)
            )
            rustData = try JSONEncoder.portableCore.encode(
                normalizedCanonicalizationResult(rustCanonical)
            )
        } else {
            legacyData = try JSONEncoder.portableCore.encode(legacy)
            rustData = try JSONEncoder.portableCore.encode(rust)
        }
        let mismatches: [PortableCoreMismatch]
        if legacyData == rustData {
            mismatches = []
        } else {
            let legacyText = String(decoding: legacyData, as: UTF8.self)
            let rustText = String(decoding: rustData, as: UTF8.self)
            mismatches = [
                PortableCoreMismatch(
                    category: blockerCategory,
                    severity: .blocker,
                    scenarioID: scenarioID,
                    detail: "Legacy != Rust | legacy=\(legacyText.prefix(300)) | rust=\(rustText.prefix(300))"
                )
            ]
        }
        return PortableCoreShadowCompareRecord(
            scenarioID: scenarioID,
            bucket: bucket,
            mismatches: mismatches,
            durationMilliseconds: durationMilliseconds
        )
    }

    static func enforceRollbackIfNeeded(
        summary: PortableCoreShadowCompareSummary,
        rollbackController: PortableCoreRollbackController = .shared
    ) {
        if summary.blockerCount > 0 {
            rollbackController.disable(reason: "blockerMismatch")
            return
        }
        if summary.nonBlockerCount > 2 {
            rollbackController.disable(reason: "nonBlockerThreshold")
        }
    }

    private static func normalizedRenderCodecOutput(
        _ output: PortableCoreRenderCodecOutput
    ) -> PortableCoreRenderCodecOutput {
        PortableCoreRenderCodecOutput(
            authJSON: normalizeJSON(output.authJSON) ?? output.authJSON,
            configTOML: output.configTOML,
            codecWarnings: output.codecWarnings,
            migrationNotes: output.migrationNotes
        )
    }

    private static func normalizeJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: normalized, as: UTF8.self)
    }

    private static func normalizedCanonicalizationResult(
        _ result: PortableCoreCanonicalizationResult
    ) -> PortableCoreCanonicalizationResult {
        var normalized = result
        normalized.accounts = normalized.accounts.map(roundCanonicalAccountTimestamps)
        normalized.config.providers = normalized.config.providers.map { provider in
            var updated = provider
            if updated.kind != CodexBarProviderKind.openRouter.rawValue {
                updated.selectedModelID = nil
                updated.pinnedModelIDs = []
            }
            updated.accounts = updated.accounts.map(roundProviderAccountTimestamps)
            return updated
        }
        return normalized
    }

    private static func roundCanonicalAccountTimestamps(
        _ account: PortableCoreCanonicalAccountSnapshot
    ) -> PortableCoreCanonicalAccountSnapshot {
        var rounded = account
        rounded.expiresAt = roundTimestamp(rounded.expiresAt)
        rounded.primaryResetAt = roundTimestamp(rounded.primaryResetAt)
        rounded.secondaryResetAt = roundTimestamp(rounded.secondaryResetAt)
        rounded.lastChecked = roundTimestamp(rounded.lastChecked)
        rounded.tokenLastRefreshAt = roundTimestamp(rounded.tokenLastRefreshAt)
        return rounded
    }

    private static func roundProviderAccountTimestamps(
        _ account: PortableCoreCanonicalConfigSnapshot.ProviderAccount
    ) -> PortableCoreCanonicalConfigSnapshot.ProviderAccount {
        var rounded = account
        rounded.expiresAt = roundTimestamp(rounded.expiresAt)
        rounded.primaryResetAt = roundTimestamp(rounded.primaryResetAt)
        rounded.secondaryResetAt = roundTimestamp(rounded.secondaryResetAt)
        rounded.lastChecked = roundTimestamp(rounded.lastChecked)
        rounded.tokenLastRefreshAt = roundTimestamp(rounded.tokenLastRefreshAt)
        return rounded
    }

    private static func roundTimestamp(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return (value * 1_000_000).rounded() / 1_000_000
    }
}
