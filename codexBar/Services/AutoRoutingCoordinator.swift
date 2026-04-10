import Foundation

// Retained for switch-journal compatibility when reading historical records.
enum AutoRoutingSwitchReason: String, Codable {
    case manual
    case startupBestAccount = "startup-best-account"
    case autoUnavailable = "auto-unavailable"
    case autoExhausted = "auto-exhausted"
    case autoThreshold = "auto-threshold"

    var isAutomatic: Bool {
        self != .manual
    }

    var isForced: Bool {
        switch self {
        case .autoUnavailable, .autoExhausted:
            return true
        case .manual, .startupBestAccount, .autoThreshold:
            return false
        }
    }
}
