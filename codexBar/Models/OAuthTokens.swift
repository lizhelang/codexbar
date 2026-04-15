import Foundation

struct OAuthTokens {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let oauthClientID: String?
    let tokenLastRefreshAt: Date?

    init(
        accessToken: String,
        refreshToken: String,
        idToken: String,
        oauthClientID: String? = nil,
        tokenLastRefreshAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.oauthClientID = oauthClientID
        self.tokenLastRefreshAt = tokenLastRefreshAt
    }
}
