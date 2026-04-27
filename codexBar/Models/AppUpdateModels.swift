import Foundation

enum UpdateCheckTrigger: Equatable {
    case automaticStartup
    case automaticDaily
    case manual
    case userInitiatedInstall
}

enum UpdateArtifactArchitecture: String, Codable, Equatable {
    case arm64
    case x86_64
    case universal
}

enum UpdateArtifactFormat: String, Codable, Equatable {
    case dmg
    case zip
}

enum UpdateDeliveryMode: String, Codable, Equatable {
    case automatic
    case guidedDownload
}

struct AppUpdateFeed: Codable, Equatable {
    var schemaVersion: Int
    var channel: String
    var release: AppUpdateRelease
}

struct AppUpdateRelease: Codable, Equatable {
    var version: String
    var publishedAt: Date?
    var summary: String?
    var releaseNotesURL: URL
    var downloadPageURL: URL
    var deliveryMode: UpdateDeliveryMode
    var minimumAutomaticUpdateVersion: String?
    var artifacts: [AppUpdateArtifact]
}

struct AppUpdateArtifact: Codable, Equatable, Identifiable {
    var architecture: UpdateArtifactArchitecture
    var format: UpdateArtifactFormat
    var downloadURL: URL
    var sha256: String?

    var id: String {
        "\(self.architecture.rawValue)-\(self.format.rawValue)-\(self.downloadURL.absoluteString)"
    }
}

struct GitHubReleaseIndexEntry: Decodable, Equatable {
    var tagName: String
    var name: String?
    var body: String?
    var htmlURL: URL
    var draft: Bool
    var prerelease: Bool
    var publishedAt: Date?
    var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }

    nonisolated var normalizedVersion: String {
        let trimmed = self.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("v") else { return trimmed }
        return String(trimmed.dropFirst())
    }

    nonisolated var installableArtifacts: [AppUpdateArtifact] {
        self.assets.compactMap(AppUpdateArtifact.init(gitHubReleaseAsset:))
    }

    nonisolated func asAppUpdateRelease() -> AppUpdateRelease? {
        guard self.draft == false, self.prerelease == false else { return nil }

        let artifacts = self.installableArtifacts
        guard artifacts.isEmpty == false else { return nil }

        return AppUpdateRelease(
            version: self.normalizedVersion,
            publishedAt: self.publishedAt,
            summary: Self.firstNonEmpty(self.body, fallback: self.name),
            releaseNotesURL: self.htmlURL,
            downloadPageURL: self.htmlURL,
            deliveryMode: .guidedDownload,
            minimumAutomaticUpdateVersion: nil,
            artifacts: artifacts
        )
    }

    private nonisolated static func firstNonEmpty(_ primary: String?, fallback: String?) -> String? {
        let primaryTrimmed = primary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let primaryTrimmed, primaryTrimmed.isEmpty == false {
            return primaryTrimmed
        }

        let fallbackTrimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallbackTrimmed, fallbackTrimmed.isEmpty == false {
            return fallbackTrimmed
        }

        return nil
    }
}

struct GitHubReleaseAsset: Decodable, Equatable {
    var name: String
    var browserDownloadURL: URL
    var digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

enum GitHubReleaseAdapter {
    nonisolated static func firstInstallableStableRelease(
        from releases: [GitHubReleaseIndexEntry]
    ) -> AppUpdateRelease? {
        releases.lazy.compactMap { $0.asAppUpdateRelease() }.first
    }
}

extension AppUpdateArtifact {
    nonisolated init?(gitHubReleaseAsset asset: GitHubReleaseAsset) {
        guard let format = Self.inferFormat(from: asset.name) else { return nil }

        self.init(
            architecture: Self.inferArchitecture(from: asset.name),
            format: format,
            downloadURL: asset.browserDownloadURL,
            sha256: Self.normalizeDigest(asset.digest)
        )
    }

    private nonisolated static func inferFormat(from filename: String) -> UpdateArtifactFormat? {
        let normalized = filename.lowercased()
        if normalized.hasSuffix(".dmg") {
            return .dmg
        }
        if normalized.hasSuffix(".zip") {
            return .zip
        }
        return nil
    }

    private nonisolated static func inferArchitecture(from filename: String) -> UpdateArtifactArchitecture {
        let normalized = filename.lowercased()

        if normalized.contains("intel")
            || normalized.contains("x86_64")
            || normalized.contains("x64") {
            return .x86_64
        }

        if normalized.contains("arm64")
            || normalized.contains("apple-silicon")
            || normalized.contains("aarch64") {
            return .arm64
        }

        return .universal
    }

    private nonisolated static func normalizeDigest(_ digest: String?) -> String? {
        guard let trimmed = digest?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }

        guard trimmed.hasPrefix("sha256:") else {
            return nil
        }

        return String(trimmed.dropFirst("sha256:".count))
    }
}

struct AppSemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let rawValue: String
    private let components: [Int]

    init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let normalized = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let numericPrefix = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? normalized
        let parts = numericPrefix.split(separator: ".").compactMap { Int($0) }
        guard parts.isEmpty == false else { return nil }

        self.rawValue = trimmed
        self.components = parts
    }

    var description: String {
        self.rawValue
    }

    static func < (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

enum UpdateInstallLocation: String, Equatable {
    case applications
    case userApplications
    case other
}

enum AppUpdateBlocker: Equatable {
    case guidedDownloadOnlyRelease
    case bootstrapRequired(currentVersion: String, minimumAutomaticVersion: String)
    case automaticUpdaterUnavailable
    case missingTrustedSignature(summary: String)
    case failingGatekeeperAssessment(summary: String)
    case unsupportedInstallLocation(UpdateInstallLocation)

    var localizedDescription: String {
        switch self {
        case .guidedDownloadOnlyRelease:
            return L.updateBlockerGuidedDownloadOnlyRelease
        case let .bootstrapRequired(currentVersion, minimumAutomaticVersion):
            return L.updateBlockerBootstrapRequired(
                currentVersion,
                minimumAutomaticVersion
            )
        case .automaticUpdaterUnavailable:
            return L.updateBlockerAutomaticUpdaterUnavailable
        case let .missingTrustedSignature(summary):
            return L.updateBlockerMissingTrustedSignature(summary)
        case let .failingGatekeeperAssessment(summary):
            return L.updateBlockerGatekeeperAssessment(summary)
        case let .unsupportedInstallLocation(location):
            return L.updateBlockerUnsupportedInstallLocation(location.displayName)
        }
    }
}

struct AppUpdateAvailability: Equatable {
    var currentVersion: String
    var release: AppUpdateRelease
    var selectedArtifact: AppUpdateArtifact
    var blockers: [AppUpdateBlocker]

    var isAutomaticUpdateAllowed: Bool {
        self.blockers.isEmpty && self.release.deliveryMode == .automatic
    }
}

enum UpdateCoordinatorState: Equatable {
    case idle
    case checking(UpdateCheckTrigger)
    case upToDate(currentVersion: String, checkedVersion: String)
    case updateAvailable(AppUpdateAvailability)
    case executing(AppUpdateAvailability)
    case failed(String)
}

extension UpdateInstallLocation {
    var displayName: String {
        switch self {
        case .applications:
            return "/Applications"
        case .userApplications:
            return "~/Applications"
        case .other:
            return L.updateInstallLocationOther
        }
    }
}
