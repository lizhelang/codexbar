import Foundation

nonisolated enum ToolQuotaStatus: String, Codable, Sendable {
    case loading, ready, notConfigured, unsupported, authenticationRequired, failed
}

nonisolated struct ToolQuotaWindow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Double?
    var used: Double? = nil
    var limit: Double? = nil
    var unit: String? = nil
    var resetsAt: Date? = nil
}

nonisolated struct ToolQuotaBalance: Codable, Equatable, Sendable {
    let amount: Double
    let currency: String
}

/// Account quota is independent from the selected local usage period and never inferred from token counts.
nonisolated struct ToolQuotaSnapshot: Codable, Equatable, Sendable {
    let client: ToolUsageClient
    let status: ToolQuotaStatus
    let providerName: String
    var windows: [ToolQuotaWindow] = []
    var balance: ToolQuotaBalance? = nil
    var refreshedAt: Date? = nil
    let statusDetail: String
}
