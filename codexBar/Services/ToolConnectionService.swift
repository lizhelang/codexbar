import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

/// Native adaptation of Javis603/token-monitor (MIT), commit 10ae6127088537bd7c9d004d814dcfe8a94c3c87:
/// providers/claude/limits.js, opencode/{goApi,web,profiles}.js, deepseek/limits.js.
/// Fixed hosts, bounded bodies, no redirects and opaque errors retain Codexbar's credential boundary.
nonisolated struct ToolConnectionService: ToolConnectionServicing {
    private let transport: any CursorUsageHTTPTransport
    private let home: URL
    private let environment: [String: String]
    private let keychainReader: @Sendable () -> Data?
    private let quotaService: ToolQuotaService
    private static let workspaceServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let subscriptionServerID = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"

    init(transport: any CursorUsageHTTPTransport = CursorUsageURLSessionTransport(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         keychainReader: @escaping @Sendable () -> Data? = Self.readClaudeKeychain) {
        self.transport = transport
        self.home = home
        self.environment = environment
        self.keychainReader = keychainReader
        self.quotaService = ToolQuotaService(transport: transport, home: home, environment: environment, readsSystemKeychain: false)
    }

    static func fingerprint(_ credential: ManagedToolCredential) -> String {
        let data = Data([credential.apiKey ?? "", credential.cookie ?? "", credential.oauthToken ?? ""].joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func secret(_ raw: String?) throws -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 32 * 1024, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !value.contains(" ") else { throw ToolConnectionError.invalidCredential }
        return value
    }

    static func claudeCookie(_ raw: String) throws -> String {
        guard let secret = try Self.secret(raw) else { throw ToolConnectionError.invalidCredential }
        let key = secret.hasPrefix("sessionKey=") ? String(secret.dropFirst("sessionKey=".count)) : secret
        guard key.hasPrefix("sk-ant-"), key.count > 7,
              key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw ToolConnectionError.invalidCredential }
        return "sessionKey=\(key)"
    }

    static func openCodeCookie(_ raw: String?) throws -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.utf8.count <= 32 * 1024, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ToolConnectionError.invalidCredential
        }
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if !text.contains("=") { text = "auth=\(text)" }
        let parts = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.allSatisfy({ part in
            guard let separator = part.firstIndex(of: "=") else { return false }
            return part[..<separator].range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
                && !part[part.index(after: separator)...].isEmpty
                && !part[part.index(after: separator)...].contains(where: { $0.isWhitespace })
        }) else { throw ToolConnectionError.invalidCredential }
        return parts.joined(separator: "; ")
    }

    static func organizationID(_ raw: String?) throws -> String? {
        guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        guard id.count <= 128, id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ToolConnectionError.invalidOrganization
        }
        return id
    }

    func discover(client: ToolUsageClient, preferences: ApplicationPreferences) async throws -> [DiscoveredToolConnection] {
        let credential: ManagedToolCredential
        let source: String
        switch client {
        case .claudeCode:
            if let raw = self.environment["CLAUDE_WEB_COOKIE"], !raw.isEmpty {
                credential = ManagedToolCredential(cookie: try Self.claudeCookie(raw)); source = "环境变量 · Claude Web"
            } else {
                let root = preferences.dataDirectory(for: client.rawValue)
                    ?? self.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                    ?? self.home.appendingPathComponent(".claude")
                let settings = Self.readJSON(root.appendingPathComponent("settings.json"))
                let env = settings?["env"] as? [String: Any] ?? [:]
                guard ToolQuotaService.isOfficialBaseURL(self.environment["ANTHROPIC_BASE_URL"] ?? env["ANTHROPIC_BASE_URL"] as? String,
                    hosts: ["api.anthropic.com"]) else { return [] }
                if let token = try Self.secret(self.environment["CLAUDE_CODE_OAUTH_TOKEN"]) {
                    credential = ManagedToolCredential(oauthToken: token); source = "环境变量 · Claude Code OAuth"
                } else if let token = try Self.oauthToken(Self.readJSON(root.appendingPathComponent(".credentials.json"))) {
                    credential = ManagedToolCredential(oauthToken: token); source = "登录文件 · Claude Code OAuth"
                } else if root.standardizedFileURL == self.home.appendingPathComponent(".claude").standardizedFileURL,
                          let data = self.keychainReader(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let token = try Self.oauthToken(object) {
                    credential = ManagedToolCredential(oauthToken: token); source = "系统钥匙串 · Claude Code OAuth"
                } else { return [] }
            }
        case .openCode:
            var results: [DiscoveredToolConnection] = []
            if let token = try? self.quotaService.discoveredOpenCodeGoAPIKey(preferences: preferences), !token.isEmpty {
                let credential = ManagedToolCredential(apiKey: token)
                let fingerprint = Self.fingerprint(credential)
                let profile = ManagedToolConnection(id: "openCode.auto.\(fingerprint.prefix(20))", client: .openCode,
                    label: "OpenCode Go", source: "自动识别 · OpenCode Go", hasAPIKey: true, isAutomatic: true, credentialFingerprint: fingerprint)
                results.append(DiscoveredToolConnection(profile: profile, credential: credential))
            }
            if let token = try? self.quotaService.discoveredOpenCodeDeepSeekAPIKey(preferences: preferences), !token.isEmpty {
                let credential = ManagedToolCredential(apiKey: token)
                let fingerprint = Self.fingerprint(credential)
                let profile = ManagedToolConnection(id: "openCode.deepseek.\(fingerprint.prefix(20))", client: .openCode,
                    label: "DeepSeek 接入服务", source: "OpenCode 已配置 · DeepSeek 官方 API", hasAPIKey: true,
                    isAutomatic: true, credentialFingerprint: fingerprint, providerKind: .deepSeekAPI)
                results.append(DiscoveredToolConnection(profile: profile, credential: credential))
            }
            return results
        case .deepSeekHarness:
            // DSH can put a relay key in DEEPSEEK_API_KEY: preserve positive official endpoint binding.
            let root = preferences.dataDirectory(for: client.rawValue)
                ?? self.environment["DSH_HOME"].map { URL(fileURLWithPath: $0) } ?? self.home.appendingPathComponent(".dsh")
            var results: [DiscoveredToolConnection] = []
            if let credential = try self.dshOfficialCredential(root: root) {
                results.append(DiscoveredToolConnection(profile: ManagedToolConnection(id: client.rawValue, client: client,
                    label: "DeepSeek API", source: "已绑定官方地址 · DeepSeek API 实时余额", hasAPIKey: true, isAutomatic: true,
                    credentialFingerprint: Self.fingerprint(credential), providerKind: .dshOfficialAPI,
                    sourceRoot: root.standardizedFileURL.path), credential: credential))
            }
            results.append(contentsOf: Self.dshSnapshotSources(root: root).map {
                DiscoveredToolConnection(profile: $0.profile, credential: ManagedToolCredential())
            })
            return results
        case .cursor: return []
        }
        let fingerprint = Self.fingerprint(credential)
        let id = client == .openCode ? "openCode.auto.\(fingerprint.prefix(20))" : client.rawValue
        let profile = ManagedToolConnection(id: id, client: client, label: client == .openCode ? "OpenCode Go" : client.displayName,
            source: source, hasAPIKey: credential.apiKey != nil, hasCookie: credential.cookie != nil,
            isAutomatic: true, credentialFingerprint: fingerprint)
        return [DiscoveredToolConnection(profile: profile, credential: credential)]
    }

    func organizations(sessionKey: String) async throws -> [ClaudeOrganization] {
        try await self.organizationLookup(sessionKey: sessionKey).organizations
    }

    func organizationLookup(sessionKey: String) async throws -> ClaudeOrganizationResult {
        let cookie = try Self.claudeCookie(sessionKey)
        let (data, response) = try await self.request("https://claude.ai/api/organizations", cookie: cookie)
        return ClaudeOrganizationResult(organizations: try Self.parseOrganizations(data), renewedCookie: Self.renewedClaudeCookie(response))
    }

    static func parseOrganizations(_ data: Data) throws -> [ClaudeOrganization] {
        let root = try JSONSerialization.jsonObject(with: data)
        let object = root as? [String: Any]
        let entries = root as? [[String: Any]] ?? object?["organizations"] as? [[String: Any]] ?? object?["data"] as? [[String: Any]] ?? []
        let candidates = entries.filter { (try? Self.organizationID(($0["uuid"] ?? $0["id"] ?? $0["organization_uuid"]) as? String)) != nil }
        let chat = candidates.filter { ($0["capabilities"] as? [String] ?? []).contains("chat") }
        let nonAPI = candidates.filter { Set($0["capabilities"] as? [String] ?? []) != ["api"] }
        let eligible = !chat.isEmpty ? chat : !nonAPI.isEmpty ? nonAPI : candidates
        var seen = Set<String>()
        return eligible.compactMap { entry in
            guard let id = try? Self.organizationID((entry["uuid"] ?? entry["id"] ?? entry["organization_uuid"]) as? String), seen.insert(id).inserted else { return nil }
            let capabilities = entry["capabilities"] as? [String] ?? []
            let plan = capabilities.contains("claude_max") ? "Max" : capabilities.contains("claude_pro") ? "Pro" : ""
            return ClaudeOrganization(id: id, name: Self.label((entry["name"] ?? entry["display_name"]) as? String) ?? "Claude 组织", plan: plan)
        }
    }

    func query(profile: ManagedToolConnection, credential: ManagedToolCredential, now: Date) async throws -> ManagedToolQuotaResult {
        if profile.providerKind == .dshSnapshot {
            guard profile.client == .deepSeekHarness, let path = profile.sourceRoot,
                  let source = Self.dshSnapshotSources(root: URL(fileURLWithPath: path)).first(where: { $0.profile.id == profile.id })
            else { throw ToolConnectionError.invalidResponse }
            return ManagedToolQuotaResult(snapshot: source.snapshot)
        }
        if profile.providerKind == .deepSeekAPI {
            guard profile.client == .openCode, let key = try Self.secret(credential.apiKey) else { throw ToolConnectionError.invalidCredential }
            return ManagedToolQuotaResult(snapshot: await self.quotaService.fetchDeepSeek(apiKey: key, client: .openCode, now: now))
        }
        if profile.providerKind == .dshOfficialAPI && profile.isAutomatic {
            guard profile.client == .deepSeekHarness, let path = profile.sourceRoot,
                  let current = try self.dshOfficialCredential(root: URL(fileURLWithPath: path)), current == credential,
                  profile.credentialFingerprint == Self.fingerprint(current) else { throw ToolConnectionError.unsupported }
        }
        switch profile.client {
        case .claudeCode:
            if let raw = credential.cookie {
                var cookie = try Self.claudeCookie(raw)
                let initialCookie = cookie
                let (data, response) = try await self.request("https://claude.ai/api/organizations", cookie: cookie)
                cookie = Self.renewedClaudeCookie(response) ?? cookie
                let organizations = try Self.parseOrganizations(data)
                let id: String
                if let selected = try Self.organizationID(profile.organizationID) {
                    guard organizations.contains(where: { $0.id == selected }) else { throw ToolConnectionError.invalidOrganization }
                    id = selected
                } else {
                    guard organizations.count == 1 else { throw ToolConnectionError.organizationSelectionRequired }
                    id = organizations[0].id
                }
                let (usage, usageResponse) = try await self.request("https://claude.ai/api/organizations/\(id)/usage?cedar_ember=1", cookie: cookie)
                cookie = Self.renewedClaudeCookie(usageResponse) ?? cookie
                guard let object = try JSONSerialization.jsonObject(with: usage) as? [String: Any] else { throw ToolConnectionError.invalidResponse }
                let (accountData, accountResponse) = try await self.request("https://claude.ai/api/account", cookie: cookie)
                cookie = Self.renewedClaudeCookie(accountResponse) ?? cookie
                guard let account = try JSONSerialization.jsonObject(with: accountData) as? [String: Any],
                      let accountID = Self.label((account["uuid"] ?? account["id"] ?? account["account_uuid"]) as? String) else {
                    throw ToolConnectionError.invalidResponse
                }
                let organization = organizations.first { $0.id == id }!
                let name = Self.label((account["email_address"] ?? account["email"]) as? String) ?? organization.name
                return ManagedToolQuotaResult(snapshot: ToolQuotaService.parseClaude(object, now: now), renewedCookie: cookie == initialCookie ? nil : cookie,
                    displayLabel: name, organizationID: id, accountIdentity: "account:\(accountID):organization:\(id)")
            }
            guard let token = try Self.secret(credential.oauthToken) else { throw ToolConnectionError.invalidCredential }
            let snapshot = await self.quotaService.fetchClaude(accessToken: token, now: now)
            guard snapshot.status == .ready else { return ManagedToolQuotaResult(snapshot: snapshot) }
            let (data, _) = try await self.request("https://api.anthropic.com/api/oauth/profile", headers: ["Authorization": "Bearer \(token)"])
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ToolConnectionError.invalidResponse }
            let account = object["account"] as? [String: Any] ?? object
            let organization = object["organization"] as? [String: Any] ?? [:]
            guard let accountID = Self.label((account["uuid"] ?? account["id"] ?? object["account_uuid"]) as? String),
                  let organizationID = Self.label((organization["uuid"] ?? organization["id"] ?? object["organization_uuid"]) as? String) else {
                throw ToolConnectionError.invalidResponse
            }
            return ManagedToolQuotaResult(snapshot: snapshot,
                displayLabel: Self.label((account["email_address"] ?? account["email"]) as? String),
                organizationID: organizationID, accountIdentity: "account:\(accountID):organization:\(organizationID)")
        case .openCode:
            var api: ToolQuotaSnapshot?
            if let key = try Self.secret(credential.apiKey) { api = await self.quotaService.fetchOpenCodeGo(apiKey: key, now: now) }
            if let cookie = try Self.openCodeCookie(credential.cookie) {
                do {
                    let web = try await self.openCodeWeb(cookie: cookie, now: now)
                    let windows = api?.status == .ready ? api!.windows : web.windows
                    if !windows.isEmpty || web.balance != nil {
                        let webFailed = web.status == .failed || web.status == .authenticationRequired
                        let detail = webFailed ? web.statusDetail + (api?.status == .ready ? "；仍显示 API Key 已读取的额度" : "")
                            : "此账号的服务端额度与余额；本地历史用量仍单独展示"
                        return ManagedToolQuotaResult(snapshot: ToolQuotaSnapshot(client: .openCode, status: webFailed ? web.status : .ready,
                            providerName: "OpenCode Go / Zen", windows: windows, balance: web.balance, refreshedAt: now,
                            statusDetail: detail))
                    }
                    if let api, api.status != .ready && api.status != .unsupported { return ManagedToolQuotaResult(snapshot: api) }
                    return ManagedToolQuotaResult(snapshot: web)
                } catch {
                    let failure = Self.opaque(error)
                    if let api, api.status == .ready {
                        let authenticationRequired = failure == .authenticationRequired
                        return ManagedToolQuotaResult(snapshot: ToolQuotaSnapshot(client: .openCode,
                            status: authenticationRequired ? .authenticationRequired : .failed,
                            providerName: api.providerName, windows: api.windows, balance: api.balance, refreshedAt: api.refreshedAt,
                            statusDetail: (authenticationRequired ? "OpenCode 网站 Cookie 已过期或未获授权" : "OpenCode 网站额度或余额读取失败")
                                + "；仍显示 API Key 已读取的额度"))
                    }
                    throw failure
                }
            }
            guard let api else { throw ToolConnectionError.invalidCredential }
            return ManagedToolQuotaResult(snapshot: api)
        case .deepSeekHarness:
            guard let key = try Self.secret(credential.apiKey) else { throw ToolConnectionError.invalidCredential }
            return ManagedToolQuotaResult(snapshot: await self.quotaService.fetchDeepSeek(apiKey: key, now: now))
        case .cursor: throw ToolConnectionError.unsupported
        }
    }

    private func openCodeWeb(cookie: String, now: Date) async throws -> ToolQuotaSnapshot {
        var (data, _) = try await self.server(Self.workspaceServerID, args: [], cookie: cookie, post: false)
        var ids = Self.workspaceIDs(String(decoding: data, as: UTF8.self))
        if ids.isEmpty {
            (data, _) = try await self.server(Self.workspaceServerID, args: [], cookie: cookie, post: true)
            ids = Self.workspaceIDs(String(decoding: data, as: UTF8.self))
        }
        guard let workspace = ids.first else { throw ToolConnectionError.invalidResponse }
        // The read-only Go page is supplemental: Zen can still succeed if this workspace has no Go plan.
        var windows: [ToolQuotaWindow] = []
        if let page = try? await self.request("https://opencode.ai/workspace/\(workspace)/go", cookie: cookie,
            headers: ["Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"]) {
            let parsed = Self.parseOpenCodeWeb(String(decoding: page.0, as: UTF8.self), now: now).windows
            if parsed.contains(where: { $0.id == "rolling" }) && parsed.contains(where: { $0.id == "weekly" }) { windows = parsed }
        }
        do {
            let (subscription, _) = try await self.server(Self.subscriptionServerID, args: [workspace], cookie: cookie, post: false)
            let text = String(decoding: subscription, as: UTF8.self)
            var zen = Self.parseOpenCodeWeb(text, now: now)
            if zen.windows.isEmpty && zen.balance == nil && text.trimmingCharacters(in: .whitespacesAndNewlines) != "null" {
                let (fallback, _) = try await self.server(Self.subscriptionServerID, args: [workspace], cookie: cookie, post: true)
                let fallbackText = String(decoding: fallback, as: UTF8.self)
                zen = Self.parseOpenCodeWeb(fallbackText, now: now)
                guard !zen.windows.isEmpty || zen.balance != nil || fallbackText.trimmingCharacters(in: .whitespacesAndNewlines) == "null" else {
                    throw ToolConnectionError.invalidResponse
                }
            }
            if windows.isEmpty { windows = zen.windows }
            return ToolQuotaSnapshot(client: .openCode, status: windows.isEmpty && zen.balance == nil ? .unsupported : .ready,
                providerName: "OpenCode Go / Zen", windows: windows, balance: zen.balance, refreshedAt: now,
                statusDetail: windows.isEmpty && zen.balance == nil ? "此账号没有可显示的 Go / Zen 订阅数据" : "OpenCode 网站服务端额度与余额")
        } catch {
            let failure = Self.opaque(error)
            guard !windows.isEmpty else { throw failure }
            let authenticationRequired = failure == .authenticationRequired
            return ToolQuotaSnapshot(client: .openCode, status: authenticationRequired ? .authenticationRequired : .failed,
                providerName: "OpenCode Go / Zen", windows: windows, refreshedAt: now,
                statusDetail: (authenticationRequired ? "OpenCode 网站 Zen 余额读取未获授权" : "OpenCode 网站 Zen 余额读取失败")
                    + "；仍显示已读取的 Go 额度")
        }
    }

    private func server(_ id: String, args: [String], cookie: String, post: Bool) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: "https://opencode.ai/_server")!
        if !post {
            components.queryItems = [URLQueryItem(name: "id", value: id)]
            if !args.isEmpty { components.queryItems?.append(URLQueryItem(name: "args", value: String(decoding: try JSONEncoder().encode(args), as: UTF8.self))) }
        }
        return try await self.request(components.url!.absoluteString, cookie: cookie, method: post ? "POST" : "GET",
            body: post ? try JSONEncoder().encode(args) : nil,
            headers: ["X-Server-Id": id, "X-Server-Instance": "server-fn:\(UUID().uuidString)",
                      "Origin": "https://opencode.ai", "Referer": args.first.map { "https://opencode.ai/workspace/\($0)/billing" } ?? "https://opencode.ai",
                      "Accept": "text/javascript, application/json;q=0.9, */*;q=0.8"])
    }

    private func request(_ endpoint: String, cookie: String = "", method: String = "GET", body: Data? = nil,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpMethod = method; request.httpBody = body
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let result = try await self.transport.data(for: request, limit: 2 * 1024 * 1024)
            guard result.1.url?.host == url.host, result.1.url?.scheme == "https", result.0.count <= 2 * 1024 * 1024 else { throw ToolConnectionError.invalidResponse }
            if result.1.statusCode == 401 || result.1.statusCode == 403 {
                let text = String(decoding: result.0, as: UTF8.self).lowercased()
                if text.contains("cf-chl-") || text.contains("just a moment") { throw ToolConnectionError.networkFailure }
                throw ToolConnectionError.authenticationRequired
            }
            guard (200...299).contains(result.1.statusCode) else { throw ToolConnectionError.networkFailure }
            if url.host == "opencode.ai" {
                let text = String(decoding: result.0, as: UTF8.self).lowercased()
                if text.contains("auth/authorize") || text.contains("not associated with an account") || text.contains("sign in") { throw ToolConnectionError.authenticationRequired }
            }
            return result
        } catch { throw Self.opaque(error) }
    }

    static func parseOpenCodeWeb(_ text: String, now: Date) -> (windows: [ToolQuotaWindow], balance: ToolQuotaBalance?) {
        if let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
            let windows = [("rolling", "rolling", "滚动窗口"), ("weekly", "weekly", "本周"), ("monthly", "monthly", "本月")].compactMap { key, id, label -> ToolQuotaWindow? in
                guard let object = Self.findObject(root, keyword: key) else { return nil }
                let fields = ["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "used_percent", "utilization", "utilizationPercent", "utilization_percent", "usage"]
                let percentage: Double?
                if let reported = fields.lazy.compactMap({ Self.number(object[$0]) }).first {
                    percentage = reported <= 1 ? reported * 100 : reported
                } else if let used = Self.number(object["used"] ?? object["consumed"]),
                   let limit = Self.number(object["limit"] ?? object["total"] ?? object["quota"] ?? object["max"] ?? object["cap"]), limit > 0 {
                    percentage = used / limit * 100
                } else { percentage = nil }
                guard let percent = percentage, percent.isFinite, percent >= 0 else { return nil }
                let resetFields = ["resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec", "resetsInSec", "resetsInSeconds", "resetIn", "resetSec"]
                let seconds = resetFields.lazy.compactMap { Self.number(object[$0]) }.first
                let absolute = ["resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "next_reset", "renewAt", "renew_at"].lazy.compactMap { Self.date(object[$0]) }.first
                let reset = seconds.flatMap { $0 >= 0 && $0 <= 366 * 86400 ? now.addingTimeInterval($0) : nil } ?? absolute
                return ToolQuotaWindow(id: id, label: label, usedPercent: min(100, percent), resetsAt: reset)
            }
            let balance = Self.findBalance(root).map { ToolQuotaBalance(amount: $0, currency: "USD") }
            if !windows.isEmpty || balance != nil { return (windows, balance) }
        }
        // The upstream _server protocol is JavaScript, not always JSON. Bound regex to one window object.
        var windows: [ToolQuotaWindow] = []
        for (key, id, label) in [("rolling", "rolling", "滚动窗口"), ("weekly", "weekly", "本周"), ("monthly", "monthly", "本月")] {
            let expression = #"(?i)"# + key + #"(?:Usage)?[\"']?\s*[:=]\s*\{([^}]{0,4096})\}"#
            if let body = Self.capture(expression, text: text),
               let percentage = Self.capture(#"(?:usagePercent|usedPercent|percentUsed|percent|utilization)[\"']?\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)"#, text: body).flatMap(Double.init), percentage.isFinite {
                let seconds = Self.capture(#"(?:resetInSec|resetInSeconds|resetSeconds)[\"']?\s*[:=]\s*([0-9]+)"#, text: body).flatMap(Double.init)
                windows.append(ToolQuotaWindow(id: id, label: label, usedPercent: min(100, max(0, percentage)),
                    resetsAt: seconds.flatMap { $0.isFinite && $0 <= 366 * 86400 ? now.addingTimeInterval($0) : nil }))
            }
        }
        let amount = Self.capture(#"(?i)(?:balanceUSD|currentBalanceUSD|currentBalance|zenBalance|balanceUsd)[\"']?\s*[:=]\s*[\"']?(-?[0-9]+(?:\.[0-9]+)?)"#, text: text).flatMap(Double.init)
        return (windows, amount.flatMap { $0.isFinite ? ToolQuotaBalance(amount: $0, currency: "USD") : nil })
    }

    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { result = value.doubleValue }
        else if let value = value as? String { result = Double(value) } else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    private static func date(_ value: Any?) -> Date? {
        if let number = Self.number(value), number > 1e9 { return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
        guard let value = value as? String else { return nil }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func findObject(_ root: Any, keyword: String, depth: Int = 0) -> [String: Any]? {
        guard depth <= 4 else { return nil }
        if let object = root as? [String: Any] {
            for (key, value) in object where key.lowercased().contains(keyword) {
                if let value = value as? [String: Any] { return value }
            }
            for value in object.values { if let found = Self.findObject(value, keyword: keyword, depth: depth + 1) { return found } }
        } else if let array = root as? [Any] {
            for value in array { if let found = Self.findObject(value, keyword: keyword, depth: depth + 1) { return found } }
        }
        return nil
    }
    private static func findBalance(_ root: Any, depth: Int = 0) -> Double? {
        guard depth <= 4 else { return nil }
        if let object = root as? [String: Any] {
            for key in ["balanceUSD", "balanceUsd", "currentBalance", "zenBalance", "currentBalanceUSD"] {
                if let amount = Self.number(object[key]) { return amount }
            }
            for value in object.values { if let found = Self.findBalance(value, depth: depth + 1) { return found } }
        } else if let array = root as? [Any] {
            for value in array { if let found = Self.findBalance(value, depth: depth + 1) { return found } }
        }
        return nil
    }

    static func workspaceIDs(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[\"'](wrk_[A-Za-z0-9_-]+)[\"']"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let id = String(text[range]); return seen.insert(id).inserted ? id : nil
        }
    }

    private static func capture(_ pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func renewedClaudeCookie(_ response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie"),
              let value = Self.capture(#"(?:^|[,;]\s*)sessionKey=([^;,\s]+)"#, text: raw) else { return nil }
        return try? Self.claudeCookie(value)
    }

    private static func oauthToken(_ object: [String: Any]?) throws -> String? {
        let oauth = object?["claudeAiOauth"] as? [String: Any] ?? object?["oauth"] as? [String: Any] ?? object
        return try Self.secret(oauth?["accessToken"] as? String)
    }

    /// The older `deepseek` and newer `deepseek-official` adapters can save the same source twice.
    /// Only their exact credential identity is an account boundary; matching amounts/times are not.
    private static func dshSnapshotSources(root: URL) -> [(profile: ManagedToolConnection, snapshot: ToolQuotaSnapshot)] {
        let providers = Self.readJSON(root.appendingPathComponent("dsh-usage/provider-snapshots.json"))?["providers"] as? [String: [String: Any]] ?? [:]
        var groups: [String: (providerID: String, entry: [String: Any], snapshot: ToolQuotaSnapshot, isDeepSeek: Bool)] = [:]
        for (id, entry) in providers.sorted(by: { $0.key < $1.key }) {
            guard let snapshot = ToolQuotaService.parseDeepSeekSnapshot(["providers": [id: entry]]) else { continue }
            let provider = ((entry["provider"] as? String) ?? id).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isDeepSeek = ["deepseek", "deepseek-official"].contains(provider)
            let identity = (entry["credential"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Without a credential identity, aliases remain separate instead of guessing ownership.
            let group = isDeepSeek && identity != nil ? "deepseek\u{0}\(Self.digest(identity!))" : "provider\u{0}\(id)"
            if let existing = groups[group], (existing.snapshot.refreshedAt ?? .distantPast) >= (snapshot.refreshedAt ?? .distantPast) { continue }
            groups[group] = (id, entry, snapshot, isDeepSeek)
        }
        return groups.sorted(by: { $0.key < $1.key }).map { group, candidate in
            let digest = Self.digest(root.standardizedFileURL.path + "\u{0}" + group)
            let label = candidate.isDeepSeek ? "DeepSeek" : Self.label(candidate.entry["displayName"] as? String) ?? candidate.providerID
            let profile = ManagedToolConnection(id: "deepSeekHarness.snapshot.\(digest.prefix(20))", client: .deepSeekHarness,
                label: label, source: "DSH 保存的余额快照 · 需在 DSH 更新", isAutomatic: true,
                credentialFingerprint: digest, accountIdentity: "dsh-source:\(digest)", providerKind: .dshSnapshot,
                sourceRoot: root.standardizedFileURL.path, providerID: candidate.providerID)
            return (profile, candidate.snapshot)
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func dshOfficialCredential(root: URL) throws -> ManagedToolCredential? {
        let fileEnvironment = Self.dshEnvironment(root: root)
        let binding = self.environment["DEEPSEEK_BASE_URL"] ?? self.environment["DEEPSEEK_API_BASE"]
            ?? fileEnvironment["DEEPSEEK_BASE_URL"] ?? fileEnvironment["DEEPSEEK_API_BASE"]
        guard binding != nil, ToolQuotaService.isOfficialBaseURL(binding, hosts: ["api.deepseek.com"]),
              let key = try Self.secret(self.environment["DEEPSEEK_API_KEY"] ?? self.environment["DEEPSEEK_KEY"]
                ?? Self.dshCredentialReference("DEEPSEEK_API_KEY", root: root)
                ?? fileEnvironment["DEEPSEEK_API_KEY"] ?? fileEnvironment["DEEPSEEK_KEY"]) else { return nil }
        return ManagedToolCredential(apiKey: key)
    }

    /// Read only the ordinary scalar `refs` mapping written by dsh-credentials-local.
    /// Anchors, tags, multiline values and inline maps are intentionally unsupported.
    private static func dshCredentialReference(_ reference: String, root: URL) -> String? {
        guard let text = Self.ownerPrivateText(root.appendingPathComponent(".credentials.yaml")) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        let rootReferences = lines.filter { line in
            guard line.first?.isWhitespace != true, let colon = line.firstIndex(of: ":") else { return false }
            return Self.yamlScalar(String(line[..<colon])) == "refs"
        }
        guard rootReferences.count == 1 else { return nil }
        var insideRefs = false
        var result: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") {
                if insideRefs { break }
                insideRefs = trimmed == "refs:"
                continue
            }
            guard insideRefs, line.hasPrefix("  "), !line.hasPrefix("   "),
                  let colon = trimmed.firstIndex(of: ":"), String(trimmed[..<colon]) == reference else { continue }
            // A duplicate key is ambiguous even if both scalars happen to match.
            guard result == nil, let scalar = Self.yamlScalar(String(trimmed[trimmed.index(after: colon)...])),
                  let secret = try? Self.secret(scalar) else { return nil }
            result = secret
        }
        return result
    }

    /// DSH honors its home `.env`; do not execute shell interpolation or read unrelated variables.
    private static func dshEnvironment(root: URL) -> [String: String] {
        guard let text = Self.ownerPrivateText(root.appendingPathComponent(".env")) else { return [:] }
        let names = Set(["DEEPSEEK_BASE_URL", "DEEPSEEK_API_BASE", "DEEPSEEK_API_KEY", "DEEPSEEK_KEY"])
        var values: [String: String] = [:]
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("export ") { trimmed = String(trimmed.dropFirst(7)) }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            guard names.contains(key) else { continue }
            // An ambiguous endpoint/key must never authorize automatic credential disclosure.
            guard seen.insert(key).inserted else { return [:] }
            guard
                  let value = Self.yamlScalar(String(trimmed[trimmed.index(after: equals)...])),
                  !value.contains("$") else { continue }
            values[key] = value
        }
        return values
    }

    private static func yamlScalar(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            guard let data = value.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { return nil }
            return decoded
        }
        if value.hasPrefix("'") {
            guard value.count >= 2, value.hasSuffix("'") else { return nil }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }),
              !["{", "[", "&", "*", "!", "|", ">", "#"].contains(where: { value.hasPrefix($0) }) else { return nil }
        return value
    }

    private static func ownerPrivateText(_ url: URL) -> String? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func readClaudeKeychain() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func opaque(_ error: Error) -> ToolConnectionError { error as? ToolConnectionError ?? .networkFailure }
    private static func label(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.count <= 200, !value.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        return value
    }
}
