import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import SQLite3

private let antigravitySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct AntigravityOAuthSession: Equatable, Sendable {
    let state: String
    let codeVerifier: String
    let redirectURI: String
    let authorizationURL: URL
}

protocol AntigravityHTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct AntigravityURLSessionTransport: AntigravityHTTPTransporting {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AntigravityAccountError.quotaRequestFailed("Invalid HTTP response")
        }
        return (data, httpResponse)
    }
}

protocol AntigravityAccountServicing: Sendable {
    func makeAuthorizationSession(port: UInt16) throws -> AntigravityOAuthSession
    func exchangeCallback(callbackInput: String, session: AntigravityOAuthSession) async throws -> AntigravityTokenFile
    func refreshTokenFile(_ tokenFile: AntigravityTokenFile) async throws -> AntigravityTokenFile
    func probeAccount(tokenFile: AntigravityTokenFile, forceRefresh: Bool) async throws -> AntigravityAccountProbeResult
}

struct AntigravityAccountService: AntigravityAccountServicing {
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let userInfoEndpoint = "https://www.googleapis.com/oauth2/v3/userinfo"
    static let loadCodeAssistEndpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    static let retrieveQuotaSummaryEndpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    static let userAgent = "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=arm64; cl=1000335682)"

    static let scopes: [String] = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
        "https://www.googleapis.com/auth/aicode"
    ]

    private let transport: any AntigravityHTTPTransporting
    private let clientConfiguration: AntigravityOAuthClientConfiguration?

    init(transport: any AntigravityHTTPTransporting = AntigravityURLSessionTransport(),
         clientConfiguration: AntigravityOAuthClientConfiguration? = nil) {
        self.transport = transport
        self.clientConfiguration = clientConfiguration
    }

    private func oauthClient() throws -> AntigravityOAuthClientConfiguration {
        if let clientConfiguration { return clientConfiguration }
        return try AntigravityOAuthClientConfiguration.load()
    }

    func makeAuthorizationSession(port: UInt16) throws -> AntigravityOAuthSession {
        let client = try self.oauthClient()
        let codeVerifier = Self.randomBase64URL(byteCount: 32)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.randomBase64URL(byteCount: 24)
        let redirectURI = "http://localhost:\(port)/auth/callback"

        var components = URLComponents(string: Self.authorizationEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizationURL = components?.url else {
            throw AntigravityAccountError.invalidOAuthCallback
        }
        return AntigravityOAuthSession(
            state: state,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            authorizationURL: authorizationURL
        )
    }

    func exchangeCallback(
        callbackInput: String,
        session: AntigravityOAuthSession
    ) async throws -> AntigravityTokenFile {
        let trimmed = callbackInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AntigravityAccountError.invalidOAuthCallback
        }

        let normalizedURLString: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            normalizedURLString = trimmed
        } else if trimmed.hasPrefix("/auth/callback") || trimmed.hasPrefix("?") {
            normalizedURLString = "http://localhost" + (trimmed.hasPrefix("/") ? "" : "/auth/callback") + trimmed
        } else if trimmed.contains("code=") {
            normalizedURLString = "http://localhost/auth/callback?" + trimmed
        } else {
            return try await self.exchangeCode(
                code: trimmed,
                codeVerifier: session.codeVerifier,
                redirectURI: session.redirectURI
            )
        }

        guard let components = URLComponents(string: normalizedURLString),
              let queryItems = components.queryItems else {
            throw AntigravityAccountError.invalidOAuthCallback
        }
        if let callbackState = queryItems.first(where: { $0.name == "state" })?.value,
           !session.state.isEmpty,
           callbackState != session.state {
            throw AntigravityAccountError.stateMismatch
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw AntigravityAccountError.invalidOAuthCallback
        }

        return try await self.exchangeCode(
            code: code,
            codeVerifier: session.codeVerifier,
            redirectURI: session.redirectURI
        )
    }

    func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> AntigravityTokenFile {
        let client = try self.oauthClient()
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw AntigravityAccountError.tokenExchangeFailed("Invalid token endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody([
            ("client_id", client.clientID),
            ("client_secret", client.clientSecret),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI)
        ])

        let (data, response) = try await self.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if payload?["error"] as? String == "invalid_grant" {
                throw AntigravityAccountError.authorizationExpired
            }
            throw AntigravityAccountError.tokenExchangeFailed("HTTP \(response.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw AntigravityAccountError.tokenExchangeFailed("Missing access_token")
        }
        let refreshToken = (json["refresh_token"] as? String) ?? ""
        guard !refreshToken.isEmpty else {
            throw AntigravityAccountError.missingRefreshToken
        }
        let tokenType = (json["token_type"] as? String) ?? "Bearer"
        let expiresIn = (json["expires_in"] as? Double)
            ?? Double((json["expires_in"] as? Int) ?? 3600)
        let idToken = json["id_token"] as? String

        return AntigravityTokenFile(
            token: AntigravityOAuthToken(
                accessToken: accessToken,
                tokenType: tokenType,
                refreshToken: refreshToken,
                expiry: Date().addingTimeInterval(expiresIn)
            ),
            authMethod: "consumer",
            idToken: idToken
        )
    }

    func refreshTokenFile(_ tokenFile: AntigravityTokenFile) async throws -> AntigravityTokenFile {
        let refreshToken = tokenFile.token.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshToken.isEmpty else {
            throw AntigravityAccountError.missingRefreshToken
        }
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw AntigravityAccountError.tokenExchangeFailed("Invalid token endpoint")
        }
        let client = try self.oauthClient()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody([
            ("client_id", client.clientID),
            ("client_secret", client.clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ])

        let (data, response) = try await self.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if payload?["error"] as? String == "invalid_grant" {
                throw AntigravityAccountError.authorizationExpired
            }
            throw AntigravityAccountError.tokenExchangeFailed("HTTP \(response.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw AntigravityAccountError.tokenExchangeFailed("Missing access_token")
        }
        let updatedRefreshToken = (json["refresh_token"] as? String) ?? refreshToken
        let tokenType = (json["token_type"] as? String) ?? tokenFile.token.tokenType
        let expiresIn = (json["expires_in"] as? Double)
            ?? Double((json["expires_in"] as? Int) ?? 3600)
        let updatedIDToken = (json["id_token"] as? String) ?? tokenFile.idToken

        return AntigravityTokenFile(
            token: AntigravityOAuthToken(
                accessToken: accessToken,
                tokenType: tokenType,
                refreshToken: updatedRefreshToken,
                expiry: Date().addingTimeInterval(expiresIn)
            ),
            authMethod: tokenFile.authMethod.isEmpty ? "consumer" : tokenFile.authMethod,
            idToken: updatedIDToken
        )
    }

    func probeAccount(
        tokenFile: AntigravityTokenFile,
        forceRefresh: Bool = false
    ) async throws -> AntigravityAccountProbeResult {
        var activeTokenFile = tokenFile
        var hasRefreshed = false
        if forceRefresh || activeTokenFile.token.isExpired || activeTokenFile.token.accessToken.isEmpty {
            if !activeTokenFile.token.refreshToken.isEmpty {
                activeTokenFile = try await self.refreshTokenFile(activeTokenFile)
                hasRefreshed = true
            }
        }
        guard !activeTokenFile.token.accessToken.isEmpty else {
            throw AntigravityAccountError.missingRefreshToken
        }

        let codeAssist: CodeAssistResult
        let quotaWindows: [AntigravityQuotaWindow]
        do {
            (codeAssist, quotaWindows) = try await self.fetchAccountQuota(accessToken: activeTokenFile.token.accessToken)
        } catch AntigravityAccountError.authorizationExpired {
            guard !hasRefreshed else { throw AntigravityAccountError.authorizationExpired }
            guard !activeTokenFile.token.refreshToken.isEmpty else {
                throw AntigravityAccountError.missingRefreshToken
            }
            activeTokenFile = try await self.refreshTokenFile(activeTokenFile)
            (codeAssist, quotaWindows) = try await self.fetchAccountQuota(accessToken: activeTokenFile.token.accessToken)
        }

        var claims = AntigravityJWTClaims.decode(jwt: activeTokenFile.idToken)
        if claims?.email == nil || claims?.email?.isEmpty == true {
            if let fetched = try? await self.fetchUserInfo(accessToken: activeTokenFile.token.accessToken) {
                claims = AntigravityJWTClaims(
                    subject: claims?.subject ?? fetched.subject,
                    email: fetched.email ?? claims?.email,
                    name: fetched.name ?? claims?.name,
                    picture: fetched.picture ?? claims?.picture
                )
            }
        }

        return AntigravityAccountProbeResult(
            tokenFile: activeTokenFile,
            userID: claims?.subject,
            email: claims?.email ?? "",
            displayName: claims?.name,
            tierID: codeAssist.tierID,
            tierName: codeAssist.tierName,
            cloudAICompanionProject: codeAssist.project,
            quotaWindows: quotaWindows
        )
    }

    private struct CodeAssistResult {
        let tierID: String
        let tierName: String
        let project: String
    }

    private func fetchAccountQuota(accessToken: String) async throws -> (CodeAssistResult, [AntigravityQuotaWindow]) {
        let codeAssist = try await self.fetchCodeAssist(accessToken: accessToken)
        let windows = try await self.fetchQuotaWindows(accessToken: accessToken, project: codeAssist.project)
        return (codeAssist, windows)
    }

    private func fetchCodeAssist(accessToken: String) async throws -> CodeAssistResult {
        guard let url = URL(string: Self.loadCodeAssistEndpoint) else {
            throw AntigravityAccountError.quotaRequestFailed("Invalid loadCodeAssist URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(#"{"metadata":{"ideType":"ANTIGRAVITY","platform":"DARWIN_ARM64","pluginType":"GEMINI"}}"#.utf8)

        let (data, response) = try await self.transport.send(request)
        if response.statusCode == 401 { throw AntigravityAccountError.authorizationExpired }
        guard (200..<300).contains(response.statusCode) else {
            throw AntigravityAccountError.quotaRequestFailed("HTTP \(response.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityAccountError.quotaRequestFailed("Invalid JSON")
        }

        let paidTier = json["paidTier"] as? [String: Any]
        let currentTier = json["currentTier"] as? [String: Any]
        let paidTierID = (paidTier?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let paidTierName = (paidTier?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentTierID = (currentTier?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentTierName = (currentTier?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let tierID = !paidTierID.isEmpty ? paidTierID : (!currentTierID.isEmpty ? currentTierID : "free-tier")
        let tierName = !paidTierName.isEmpty ? paidTierName : (!currentTierName.isEmpty ? currentTierName : "Antigravity")
        let project = ((json["cloudaicompanionProject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "aicode-consumers"

        return CodeAssistResult(tierID: tierID, tierName: tierName, project: project)
    }

    private func fetchQuotaWindows(
        accessToken: String,
        project: String
    ) async throws -> [AntigravityQuotaWindow] {
        guard let url = URL(string: Self.retrieveQuotaSummaryEndpoint) else {
            throw AntigravityAccountError.quotaRequestFailed("Invalid retrieveUserQuotaSummary URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let payload = try JSONSerialization.data(withJSONObject: ["project": project.isEmpty ? "aicode-consumers" : project])
        request.httpBody = payload

        let (data, response) = try await self.transport.send(request)
        if response.statusCode == 401 { throw AntigravityAccountError.authorizationExpired }
        guard (200..<300).contains(response.statusCode) else {
            throw AntigravityAccountError.quotaRequestFailed("HTTP \(response.statusCode)")
        }
        return try Self.parseQuotaSummary(data: data)
    }

    static func parseQuotaSummary(data: Data) throws -> [AntigravityQuotaWindow] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityAccountError.quotaRequestFailed("Invalid quota summary JSON")
        }
        guard let groups = json["groups"] as? [[String: Any]] else {
            throw AntigravityAccountError.quotaRequestFailed("Missing quota groups")
        }
        var windows: [AntigravityQuotaWindow] = []
        var bucketIDs: Set<String> = []
        for group in groups {
            let groupName = (group["displayName"] as? String)
                ?? (group["groupName"] as? String)
                ?? ""
            guard let buckets = group["buckets"] as? [[String: Any]] else {
                throw AntigravityAccountError.quotaRequestFailed("Missing quota buckets")
            }
            for bucket in buckets {
                guard let bucketID = bucket["bucketId"] as? String,
                      !bucketID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      bucketIDs.insert(bucketID).inserted else {
                    throw AntigravityAccountError.quotaRequestFailed("Invalid quota bucket identifier")
                }
                let displayName = (bucket["displayName"] as? String) ?? bucketID
                let windowKind = (bucket["window"] as? String) ?? ""
                let rawRemaining: Double
                if bucket["remainingFraction"] == nil {
                    // Protobuf JSON omits 0.0 for double fields in proto3.
                    rawRemaining = 0.0
                } else if let number = bucket["remainingFraction"] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID() {
                    rawRemaining = number.doubleValue
                } else if let string = bucket["remainingFraction"] as? String, let number = Double(string) {
                    rawRemaining = number
                } else {
                    throw AntigravityAccountError.quotaRequestFailed("Invalid remaining quota fraction")
                }
                guard rawRemaining.isFinite, (0...1).contains(rawRemaining) else {
                    throw AntigravityAccountError.quotaRequestFailed("Invalid remaining quota fraction")
                }
                let resetAt = (bucket["resetTime"] as? String).flatMap(AntigravityOAuthToken.parseISO8601)
                windows.append(
                    AntigravityQuotaWindow(
                        id: bucketID,
                        groupName: groupName,
                        displayName: displayName,
                        windowKind: windowKind,
                        remainingFraction: rawRemaining,
                        resetAt: resetAt
                    )
                )
            }
        }
        guard !windows.isEmpty else {
            throw AntigravityAccountError.quotaRequestFailed("No quota windows returned")
        }
        let preferredOrder: [String: Int] = [
            "gemini-5h": 0,
            "gemini-weekly": 1,
            "3p-5h": 2,
            "3p-weekly": 3,
            "gemini-argon-wtu-weekly": 4
        ]
        return windows.sorted { lhs, rhs in
            let lOrder = preferredOrder[lhs.id] ?? 99
            let rOrder = preferredOrder[rhs.id] ?? 99
            if lOrder != rOrder {
                return lOrder < rOrder
            }
            return lhs.id < rhs.id
        }
    }

    private func fetchUserInfo(accessToken: String) async throws -> AntigravityJWTClaims {
        guard let url = URL(string: Self.userInfoEndpoint) else {
            throw AntigravityAccountError.quotaRequestFailed("Invalid userinfo URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.transport.send(request)
        guard (200..<300).contains(response.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityAccountError.quotaRequestFailed("Failed to read userinfo")
        }
        return AntigravityJWTClaims(
            subject: (json["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            email: (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            name: (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            picture: (json["picture"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncodedBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let query = pairs.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(query.utf8)
    }
}

struct AntigravityLocalCredentialSync: Sendable {
    var standaloneTokenFileURL: URL
    var vscdbURLs: [URL]

    init(
        standaloneTokenFileURL: URL? = nil,
        vscdbURLs: [URL]? = nil
    ) {
        let home = CodexPaths.realHome
        self.standaloneTokenFileURL = standaloneTokenFileURL
            ?? home.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        self.vscdbURLs = vscdbURLs ?? [
            home.appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb"),
            home.appendingPathComponent("Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb")
        ]
    }

    func readLocalTokenFile() -> AntigravityTokenFile? {
        if let data = try? Data(contentsOf: self.standaloneTokenFileURL),
           let tokenFile = try? AntigravityTokenFile.parse(data: data) {
            return tokenFile
        }
        for dbURL in self.vscdbURLs {
            if let token = Self.readTokenFromVscdb(at: dbURL) {
                return AntigravityTokenFile(token: token, authMethod: "consumer", idToken: nil)
            }
        }
        return nil
    }

    func writeLocalTokenFile(_ tokenFile: AntigravityTokenFile) throws {
        let parentDir = self.standaloneTokenFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        _ = chmod(parentDir.path, S_IRWXU)

        let data = try tokenFile.serializedData()
        try data.write(to: self.standaloneTokenFileURL, options: .atomic)
        _ = chmod(self.standaloneTokenFileURL.path, S_IRUSR | S_IWUSR)

        for dbURL in self.vscdbURLs where FileManager.default.fileExists(atPath: dbURL.path) {
            Self.writeTokenToVscdb(tokenFile.token, at: dbURL)
        }
    }

    static func readTokenFromVscdb(at databaseURL: URL) -> AntigravityOAuthToken? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        _ = AntigravityVscdbProtobuf.itemTableKey.withCString { cStr in
            sqlite3_bind_text(statement, 1, cStr, -1, antigravitySQLiteTransient)
        }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let textPtr = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let base64Topic = String(cString: textPtr)
        return AntigravityVscdbProtobuf.decode(base64Topic: base64Topic)
    }

    static func writeTokenToVscdb(_ token: AntigravityOAuthToken, at databaseURL: URL) {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)

        let encodedValue = AntigravityVscdbProtobuf.encode(token: token)
        let sql = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return
        }
        defer { sqlite3_finalize(statement) }

        _ = AntigravityVscdbProtobuf.itemTableKey.withCString { keyCStr in
            sqlite3_bind_text(statement, 1, keyCStr, -1, antigravitySQLiteTransient)
        }
        _ = encodedValue.withCString { valCStr in
            sqlite3_bind_text(statement, 2, valCStr, -1, antigravitySQLiteTransient)
        }
        _ = sqlite3_step(statement)
    }
}
