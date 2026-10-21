import CryptoKit
import Foundation

struct AntigravityOAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var tokenType: String
    var refreshToken: String
    var expiry: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
        case expiry
    }

    init(
        accessToken: String,
        tokenType: String = "Bearer",
        refreshToken: String,
        expiry: Date
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType.isEmpty ? "Bearer" : tokenType
        self.refreshToken = refreshToken
        self.expiry = expiry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.tokenType = (try? container.decode(String.self, forKey: .tokenType)) ?? "Bearer"
        self.refreshToken = (try? container.decode(String.self, forKey: .refreshToken)) ?? ""
        if let expiryString = try? container.decode(String.self, forKey: .expiry),
           let parsedDate = Self.parseISO8601(expiryString) {
            self.expiry = parsedDate
        } else if let timestamp = try? container.decode(Double.self, forKey: .expiry) {
            self.expiry = Date(timeIntervalSince1970: timestamp)
        } else {
            self.expiry = Date.distantPast
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.accessToken, forKey: .accessToken)
        try container.encode(self.tokenType, forKey: .tokenType)
        try container.encode(self.refreshToken, forKey: .refreshToken)
        try container.encode(Self.formatISO8601(self.expiry), forKey: .expiry)
    }

    var isExpired: Bool {
        self.expiry.timeIntervalSinceNow <= 60
    }

    static func parseISO8601(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: trimmed)
    }

    static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

struct AntigravityTokenFile: Codable, Equatable, Sendable {
    var token: AntigravityOAuthToken
    var authMethod: String
    var idToken: String?

    enum CodingKeys: String, CodingKey {
        case token
        case authMethod = "auth_method"
        case idToken = "id_token"
    }

    init(
        token: AntigravityOAuthToken,
        authMethod: String = "consumer",
        idToken: String? = nil
    ) {
        self.token = token
        self.authMethod = authMethod.isEmpty ? "consumer" : authMethod
        self.idToken = idToken
    }

    private struct FlatFallbackPayload: Decodable {
        let accessToken: String?
        let tokenType: String?
        let refreshToken: String?
        let expiry: String?
        let expiresIn: Double?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case expiry
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    static func parse(data: Data) throws -> AntigravityTokenFile {
        let decoder = JSONDecoder()
        if let structured = try? decoder.decode(AntigravityTokenFile.self, from: data),
           !structured.token.accessToken.isEmpty || !structured.token.refreshToken.isEmpty {
            return structured
        }
        let flat = try decoder.decode(FlatFallbackPayload.self, from: data)
        let accessToken = flat.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refreshToken = flat.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty || !refreshToken.isEmpty else {
            throw AntigravityAccountError.invalidTokenPayload
        }
        let expiry: Date
        if let expiryStr = flat.expiry, let parsed = AntigravityOAuthToken.parseISO8601(expiryStr) {
            expiry = parsed
        } else if let expiresIn = flat.expiresIn {
            expiry = Date().addingTimeInterval(expiresIn)
        } else {
            expiry = Date.distantPast
        }
        return AntigravityTokenFile(
            token: AntigravityOAuthToken(
                accessToken: accessToken,
                tokenType: flat.tokenType ?? "Bearer",
                refreshToken: refreshToken,
                expiry: expiry
            ),
            authMethod: "consumer",
            idToken: flat.idToken
        )
    }

    func serializedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct AntigravityJWTClaims: Equatable, Sendable {
    var subject: String?
    var email: String?
    var name: String?
    var picture: String?

    static func decode(jwt: String?) -> AntigravityJWTClaims? {
        guard let jwt = jwt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jwt.isEmpty else {
            return nil
        }
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let payloadData = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return AntigravityJWTClaims(
            subject: (json["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            email: (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            name: (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            picture: (json["picture"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum AntigravityVscdbProtobuf {
    static let sentinelKey = "oauthTokenInfoSentinelKey"
    static let itemTableKey = "antigravityUnifiedStateSync.oauthToken"

    static func encode(token: AntigravityOAuthToken) -> String {
        let expirySeconds = Int64(max(0, token.expiry.timeIntervalSince1970.rounded()))
        var timestampMessage = Data()
        appendVarintField(fieldNumber: 1, value: UInt64(bitPattern: expirySeconds), to: &timestampMessage)

        var tokenInfoMessage = Data()
        appendStringField(fieldNumber: 1, value: token.accessToken, to: &tokenInfoMessage)
        appendStringField(fieldNumber: 2, value: token.tokenType.isEmpty ? "Bearer" : token.tokenType, to: &tokenInfoMessage)
        appendStringField(fieldNumber: 3, value: token.refreshToken, to: &tokenInfoMessage)
        appendBytesField(fieldNumber: 4, value: timestampMessage, to: &tokenInfoMessage)

        let innerBase64 = tokenInfoMessage.base64EncodedString()

        var rowValueMessage = Data()
        appendStringField(fieldNumber: 1, value: innerBase64, to: &rowValueMessage)

        var rowMessage = Data()
        appendStringField(fieldNumber: 1, value: self.sentinelKey, to: &rowMessage)
        appendBytesField(fieldNumber: 2, value: rowValueMessage, to: &rowMessage)

        var topicMessage = Data()
        appendBytesField(fieldNumber: 1, value: rowMessage, to: &topicMessage)

        return topicMessage.base64EncodedString()
    }

    static func decode(base64Topic: String) -> AntigravityOAuthToken? {
        let trimmed = base64Topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let topicData = Data(base64Encoded: trimmed) else { return nil }
        for (field, value) in parseFields(from: topicData) where field == 1 {
            guard case .lengthDelimited(let rowData) = value else { continue }
            var rowKey: String?
            var rowValueData: Data?
            for (rowField, rowVal) in parseFields(from: rowData) {
                if rowField == 1, case .lengthDelimited(let keyData) = rowVal {
                    rowKey = String(data: keyData, encoding: .utf8)
                } else if rowField == 2, case .lengthDelimited(let valData) = rowVal {
                    rowValueData = valData
                }
            }
            guard rowKey == self.sentinelKey, let rowValueData else { continue }
            for (valField, valContent) in parseFields(from: rowValueData) where valField == 1 {
                guard case .lengthDelimited(let innerBase64Data) = valContent,
                      let innerBase64 = String(data: innerBase64Data, encoding: .utf8),
                      let tokenInfoData = Data(base64Encoded: innerBase64) else {
                    continue
                }
                return decodeTokenInfo(from: tokenInfoData)
            }
        }
        return nil
    }

    private static func decodeTokenInfo(from data: Data) -> AntigravityOAuthToken? {
        var accessToken = ""
        var tokenType = "Bearer"
        var refreshToken = ""
        var expirySeconds: Int64 = 0

        for (field, value) in parseFields(from: data) {
            switch (field, value) {
            case (1, .lengthDelimited(let bytes)):
                accessToken = String(data: bytes, encoding: .utf8) ?? ""
            case (2, .lengthDelimited(let bytes)):
                tokenType = String(data: bytes, encoding: .utf8) ?? "Bearer"
            case (3, .lengthDelimited(let bytes)):
                refreshToken = String(data: bytes, encoding: .utf8) ?? ""
            case (4, .lengthDelimited(let timestampBytes)):
                for (tsField, tsVal) in parseFields(from: timestampBytes) where tsField == 1 {
                    if case .varint(let raw) = tsVal {
                        expirySeconds = Int64(bitPattern: raw)
                    }
                }
            default:
                break
            }
        }
        guard !accessToken.isEmpty || !refreshToken.isEmpty else { return nil }
        return AntigravityOAuthToken(
            accessToken: accessToken,
            tokenType: tokenType,
            refreshToken: refreshToken,
            expiry: Date(timeIntervalSince1970: TimeInterval(expirySeconds))
        )
    }

    private enum WireValue {
        case varint(UInt64)
        case lengthDelimited(Data)
    }

    private static func parseFields(from data: Data) -> [(Int, WireValue)] {
        var results: [(Int, WireValue)] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let tag = readVarint(from: data, index: &index) else { break }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            switch wireType {
            case 0:
                guard let val = readVarint(from: data, index: &index) else { return results }
                results.append((fieldNumber, .varint(val)))
            case 2:
                guard let length = readVarint(from: data, index: &index) else { return results }
                let byteCount = Int(length)
                guard byteCount >= 0, data.distance(from: index, to: data.endIndex) >= byteCount else {
                    return results
                }
                let end = data.index(index, offsetBy: byteCount)
                results.append((fieldNumber, .lengthDelimited(Data(data[index..<end]))))
                index = end
            default:
                return results
            }
        }
        return results
    }

    private static func readVarint(from data: Data, index: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var current = value
        while current >= 0x80 {
            data.append(UInt8((current & 0x7F) | 0x80))
            current >>= 7
        }
        data.append(UInt8(current))
    }

    private static func appendVarintField(fieldNumber: Int, value: UInt64, to data: inout Data) {
        appendVarint(UInt64((fieldNumber << 3) | 0), to: &data)
        appendVarint(value, to: &data)
    }

    private static func appendBytesField(fieldNumber: Int, value: Data, to data: inout Data) {
        appendVarint(UInt64((fieldNumber << 3) | 2), to: &data)
        appendVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func appendStringField(fieldNumber: Int, value: String, to data: inout Data) {
        appendBytesField(fieldNumber: fieldNumber, value: Data(value.utf8), to: &data)
    }
}

struct AntigravityQuotaWindow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var groupName: String
    var displayName: String
    var windowKind: String
    var remainingFraction: Double
    var resetAt: Date?

    var remainingPercent: Double {
        min(max((self.remainingFraction * 100).rounded(), 0), 100)
    }

    var usedPercent: Double {
        min(max(((1.0 - self.remainingFraction) * 100).rounded(), 0), 100)
    }

    func displayPercent(mode: CodexBarUsageDisplayMode) -> Double {
        switch mode {
        case .remaining:
            return self.remainingPercent
        case .used:
            return self.usedPercent
        }
    }

    var shortLabel: String {
        switch self.id {
        case "gemini-5h":
            return "Gemini 5h"
        case "gemini-weekly":
            return L.zh ? "Gemini 7天" : "Gemini 7d"
        case "3p-5h":
            return "Claude/GPT 5h"
        case "3p-weekly":
            return L.zh ? "Claude/GPT 7天" : "Claude/GPT 7d"
        case "gemini-argon-wtu-weekly":
            return "Gemini 4 Argon"
        default:
            if !self.groupName.isEmpty, self.displayName.lowercased().contains("limit") {
                return self.groupName
            }
            return self.displayName
        }
    }

    var compactBadgeLabel: String {
        switch self.id {
        case "gemini-5h":
            return "G 5h"
        case "gemini-weekly":
            return "G 7d"
        case "3p-5h":
            return "C/G 5h"
        case "3p-weekly":
            return "C/G 7d"
        case "gemini-argon-wtu-weekly":
            return "Argon"
        default:
            return self.shortLabel
        }
    }

    func resetDescription(now: Date = Date()) -> String {
        guard let resetAt = self.resetAt else { return "—" }
        let seconds = Int(resetAt.timeIntervalSince(now))
        if seconds <= 0 {
            return L.zh ? "即将重置" : "Resetting soon"
        }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }
}

enum AntigravityAccountStatus: String, Codable, Equatable, Sendable {
    case ok
    case reauthRequired
    case error
}

struct AntigravityAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var email: String
    var displayName: String?
    var userID: String?
    var tierID: String
    var tierName: String
    var cloudAICompanionProject: String?
    var quotaWindows: [AntigravityQuotaWindow]
    var status: AntigravityAccountStatus
    var statusMessage: String?
    var addedAt: Date
    var lastUpdatedAt: Date?
    var isActive: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName
        case userID
        case tierID
        case tierName
        case cloudAICompanionProject
        case quotaWindows
        case status
        case statusMessage
        case addedAt
        case lastUpdatedAt
    }

    var planBadgeTitle: String {
        let lowerID = self.tierID.lowercased()
        let lowerName = self.tierName.lowercased()
        if lowerID.contains("ultra") || lowerName.contains("ultra") {
            return "ULTRA"
        }
        if lowerID.contains("pro") || lowerName.contains("pro") {
            return "PRO"
        }
        if lowerID.contains("free") || lowerName == "antigravity" || lowerName.isEmpty {
            return "FREE"
        }
        return self.tierName.uppercased()
    }

    var quotaExhausted: Bool {
        guard !self.quotaWindows.isEmpty else { return false }
        return self.quotaWindows.contains { $0.remainingFraction <= 0.0001 }
    }

    var hasAvailableQuota: Bool {
        let groups = Dictionary(grouping: self.quotaWindows) { window in
            window.groupName.isEmpty ? window.id : window.groupName
        }
        return groups.values.contains { windows in
            windows.allSatisfy { $0.remainingFraction > 0.0001 }
        }
    }

    var primaryDisplayLabel: String {
        let trimmedEmail = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEmail.isEmpty {
            return trimmedEmail
        }
        if let name = self.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return self.id
    }

    static func makeStableID(userID: String?, email: String?, refreshToken: String) -> String {
        if let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty {
            return "ag-\(userID)"
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty {
            return "ag-\(email)"
        }
        let digest = SHA256.hash(data: Data(refreshToken.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "ag-\(hex)"
    }
}

struct AntigravityAccountProbeResult: Equatable, Sendable {
    var tokenFile: AntigravityTokenFile
    var userID: String?
    var email: String
    var displayName: String?
    var tierID: String
    var tierName: String
    var cloudAICompanionProject: String
    var quotaWindows: [AntigravityQuotaWindow]
}

enum AntigravityAccountError: LocalizedError, Equatable {
    case invalidTokenPayload
    case missingRefreshToken
    case oauthClientConfigurationUnavailable
    case invalidOAuthCallback
    case stateMismatch
    case authorizationExpired
    case tokenExchangeFailed(String)
    case quotaRequestFailed(String)
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .invalidTokenPayload:
            return L.zh ? "Antigravity 凭证格式无效。" : "Invalid Antigravity token payload."
        case .missingRefreshToken:
            return L.zh ? "缺少 refresh_token，请重新登录授权。" : "Missing refresh_token; please sign in again."
        case .oauthClientConfigurationUnavailable:
            return L.zh
                ? "未配置 Antigravity OAuth 客户端。请提供本机私有配置（仅当前用户可读）或配套环境变量后重试。"
                : "Antigravity OAuth client configuration is unavailable. Supply a private owner-only configuration or both client environment variables."
        case .invalidOAuthCallback:
            return L.zh ? "无法解析 Google OAuth 回调链接。" : "Could not parse the Google OAuth callback URL."
        case .stateMismatch:
            return L.zh ? "OAuth state 校验不匹配，请重试。" : "OAuth state mismatch; please try again."
        case .authorizationExpired:
            return L.zh ? "Antigravity 授权已失效，请重新登录授权。" : "Antigravity authorization expired; please sign in again."
        case .tokenExchangeFailed(let detail):
            return L.zh ? "Google OAuth 令牌刷新或交换失败：\(detail)" : "Google OAuth token exchange failed: \(detail)"
        case .quotaRequestFailed(let detail):
            return L.zh ? "读取 Antigravity 额度失败：\(detail)" : "Failed to fetch Antigravity quota: \(detail)"
        case .accountNotFound:
            return L.zh ? "找不到对应的 Antigravity 账号。" : "Antigravity account not found."
        }
    }
}
