import Foundation

/// Account identities never include the session cookie. Credentials have a separate secure file.
nonisolated struct CursorManagedAccount: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case desktop, manual }

    let id: String
    let userID: String
    var email: String?
    var name: String?
    var planType: String?
    var alias: String
    var source: Source
    var isPaused: Bool
    let createdAt: Date
    var updatedAt: Date

    var isDesktop: Bool { self.source == .desktop }
    var displayName: String {
        if !self.alias.isEmpty { return self.alias }
        return self.email ?? self.name ?? self.userID
    }
}

nonisolated struct CursorAccountIdentity: Equatable, Sendable {
    let userID: String
    var email: String? = nil
    var name: String? = nil
    var planType: String? = nil
}

nonisolated struct CursorAccountProbe: Equatable, Sendable {
    let identity: CursorAccountIdentity
    let quota: ToolQuotaSnapshot
}

nonisolated struct CursorAccountState: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case idle, refreshing, ready, authenticationRequired, failed, paused }

    var quota: ToolQuotaSnapshot? = nil
    var usage: ToolUsageSnapshot? = nil
    var status: Status = .idle
    var statusDetail: String? = nil
    var refreshedAt: Date? = nil
}

/// These errors deliberately exclude HTTP bodies, transport errors and credential values.
nonisolated enum CursorAccountError: Error, Equatable, LocalizedError {
    case invalidCredential, authenticationRequired, identityMismatch, invalidResponse
    case networkFailure, responseTooLarge, storageFailure, accountNotFound
    case desktopAccountCannotBeRemoved, operationSuperseded, invalidAlias, paused

    var errorDescription: String? { self.statusDetail }
    var statusDetail: String {
        switch self {
        case .invalidCredential: "Cursor 登录凭据格式无效，请粘贴完整 Cookie 或登录令牌"
        case .authenticationRequired: "Cursor 登录已过期或未获授权，请更新该账号的登录凭据"
        case .identityMismatch: "登录凭据与查询返回的 Cursor 账号不一致，未保存"
        case .invalidResponse: "Cursor 账号接口返回格式已变化，保留上次读取的数据"
        case .networkFailure: "Cursor 账号接口暂时不可用，保留上次读取的数据"
        case .responseTooLarge: "Cursor 账号响应超过大小限制，保留上次读取的数据"
        case .storageFailure: "Cursor 账号数据保存或读取失败"
        case .accountNotFound: "未找到该 Cursor 账号"
        case .desktopAccountCannotBeRemoved: "桌面自动识别的账号可以暂停；退出登录请在 Cursor 中操作"
        case .operationSuperseded: "账号已修改，本次查询结果已忽略"
        case .invalidAlias: "账号别名过长或包含登录凭据，请使用简短名称"
        case .paused: "Cursor 账号采集已暂停"
        }
    }

    static func sanitized(_ error: any Error) -> Self {
        if let error = error as? Self { return error }
        switch error as? CursorUsageSyncError {
        case .invalidDesktopSession: return .invalidCredential
        case .sessionExpired: return .authenticationRequired
        case .invalidResponse: return .invalidResponse
        case .responseTooLarge: return .responseTooLarge
        default: return .networkFailure
        }
    }
}
