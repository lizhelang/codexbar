import Foundation

/// Credential-free connection metadata. Claude and DSH have one connection; OpenCode has profiles.
nonisolated struct ManagedToolConnection: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let client: ToolUsageClient
    var label: String
    var source: String
    var isEnabled = true
    var hasAPIKey = false
    var hasCookie = false
    var organizationID: String? = nil
    var updatedAt: Date = Date()
    var isAutomatic = false
    /// A one-way identity boundary invalidates caches when the source credential changes.
    var credentialFingerprint: String? = nil
    var accountIdentity: String? = nil
    var providerKind: ManagedToolProviderKind = .primary
    var sourceRoot: String? = nil
    var providerID: String? = nil

    var sourceDescription: String { self.source }
    /// Automatic DSH sources can be hidden without altering the original DSH data.
    var canHideAutomaticSource: Bool { self.isAutomatic && self.client == .deepSeekHarness }
    var canRemove: Bool { !self.isAutomatic || self.canHideAutomaticSource }
}

nonisolated enum ManagedToolProviderKind: String, Codable, Sendable {
    case primary, deepSeekAPI, dshSnapshot, dshOfficialAPI
}

nonisolated enum ManagedToolCredentialKind: String, Sendable {
    case apiKey, cookie
}

nonisolated struct ClaudeOrganization: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    var plan: String = ""
}

/// Errors are deliberately opaque: transport errors and server bodies may contain credentials.
nonisolated enum ToolConnectionError: Error, LocalizedError, Equatable {
    case invalidCredential, invalidOrganization, organizationSelectionRequired
    case authenticationRequired, unsupported, networkFailure, invalidResponse, storageFailure
    case duplicateCredential, missingProfile, sameAccountConfirmationRequired

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "凭据格式无效，请重新粘贴。"
        case .invalidOrganization: "所选 Claude 组织不可用，请重新查询组织列表。"
        case .organizationSelectionRequired: "请选择要查询额度的 Claude 组织。"
        case .authenticationRequired: "登录或凭据已过期，请重新登录并更新凭据。"
        case .unsupported: "该服务未返回支持的额度或余额。"
        case .networkFailure: "额度服务暂时不可用，请稍后重试。"
        case .invalidResponse: "服务返回格式已变化，请稍后重试。"
        case .storageFailure: "无法保存连接，请检查本地存储权限。"
        case .duplicateCredential: "此凭据已经属于另一个 OpenCode 账号。"
        case .missingProfile: "连接已移除，请重新选择。"
        case .sameAccountConfirmationRequired: "请确认 API Key 与网站 Cookie 属于同一个 OpenCode 账号。"
        }
    }
}

/// Only the separate private credential file can encode this structure.
nonisolated struct ManagedToolCredential: Codable, Equatable, Sendable {
    var apiKey: String? = nil
    var cookie: String? = nil
    var oauthToken: String? = nil
}

nonisolated struct DiscoveredToolConnection: Sendable {
    var profile: ManagedToolConnection
    var credential: ManagedToolCredential
}

nonisolated struct ManagedToolQuotaResult: Sendable {
    var snapshot: ToolQuotaSnapshot
    var renewedCookie: String? = nil
    var displayLabel: String? = nil
    var organizationID: String? = nil
    var accountIdentity: String? = nil
}

nonisolated struct ClaudeOrganizationResult: Sendable {
    var organizations: [ClaudeOrganization]
    var renewedCookie: String? = nil
}

nonisolated protocol ToolConnectionServicing: Sendable {
    func discover(client: ToolUsageClient, preferences: ApplicationPreferences) async throws -> [DiscoveredToolConnection]
    func organizations(sessionKey: String) async throws -> [ClaudeOrganization]
    func organizationLookup(sessionKey: String) async throws -> ClaudeOrganizationResult
    func query(profile: ManagedToolConnection, credential: ManagedToolCredential, now: Date) async throws -> ManagedToolQuotaResult
}

extension ToolConnectionServicing {
    nonisolated func organizationLookup(sessionKey: String) async throws -> ClaudeOrganizationResult {
        ClaudeOrganizationResult(organizations: try await self.organizations(sessionKey: sessionKey))
    }
}
