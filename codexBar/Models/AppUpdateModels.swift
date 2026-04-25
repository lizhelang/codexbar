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
