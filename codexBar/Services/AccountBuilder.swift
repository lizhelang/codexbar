import Foundation

/// 从 OAuth tokens 解析账号信息，构建 TokenAccount
struct AccountBuilder {
    static func build(from tokens: OAuthTokens) -> TokenAccount {
        let claims = decodeJWT(tokens.accessToken)
        let authClaims = self.authClaims(fromAccessToken: tokens.accessToken)

        let accountId = self.localAccountID(fromAuthClaims: authClaims)
        let openAIAccountId = self.openAIAccountID(fromAuthClaims: authClaims)
        let planType = authClaims["chatgpt_plan_type"] as? String ?? "free"

        // 从 id_token 取 email
        let idClaims = decodeJWT(tokens.idToken)
        let email = idClaims["email"] as? String ?? ""

        // Codex/OpenAI 的身份态同时依赖 access token 和 id token，任一接近过期都应触发刷新。
        let tokenExp = claims["exp"] as? Double
        let tokenExpiresAt = tokenExp.map { Date(timeIntervalSince1970: $0) }

        let idTokenClaims = decodeJWT(tokens.idToken)
        let idTokenExp = idTokenClaims["exp"] as? Double
        let idTokenExpiresAt = idTokenExp.map { Date(timeIntervalSince1970: $0) }

        let idAuthClaims = idClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        var subscriptionActiveUntil: Date? = nil
        if let untilStr = idAuthClaims["chatgpt_subscription_active_until"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            subscriptionActiveUntil = formatter.date(from: untilStr)
                ?? ISO8601DateFormatter().date(from: untilStr)
        }

        return TokenAccount(
            email: email,
            accountId: accountId,
            openAIAccountId: openAIAccountId,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            expiresAt: self.earliest(tokenExpiresAt, idTokenExpiresAt) ?? subscriptionActiveUntil,
            oauthClientID: tokens.oauthClientID ?? (claims["client_id"] as? String),
            planType: planType,
            tokenLastRefreshAt: tokens.tokenLastRefreshAt
        )
    }

    private static func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return min(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    static func authClaims(fromAccessToken accessToken: String) -> [String: Any] {
        let claims = decodeJWT(accessToken)
        return claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
    }

    static func localAccountID(fromAccessToken accessToken: String) -> String {
        self.localAccountID(fromAuthClaims: self.authClaims(fromAccessToken: accessToken))
    }

    static func localAccountID(fromAuthClaims authClaims: [String: Any]) -> String {
        (authClaims["chatgpt_account_user_id"] as? String)
            ?? (authClaims["chatgpt_account_id"] as? String)
            ?? ""
    }

    static func openAIAccountID(fromAccessToken accessToken: String) -> String {
        self.openAIAccountID(fromAuthClaims: self.authClaims(fromAccessToken: accessToken))
    }

    static func openAIAccountID(fromAuthClaims authClaims: [String: Any]) -> String {
        (authClaims["chatgpt_account_id"] as? String)
            ?? self.localAccountID(fromAuthClaims: authClaims)
    }

    /// 解码 JWT payload（不验签）
    static func decodeJWT(_ token: String) -> [String: Any] {
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return [:] }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
}
