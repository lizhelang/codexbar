import CoreFoundation
import Foundation
import Security

nonisolated protocol ToolQuotaFetching: Sendable {
    func fetch(client: ToolUsageClient, preferences: ApplicationPreferences, now: Date) async -> ToolQuotaSnapshot
}

/// Only reads existing client credentials. Fixed HTTPS endpoints, ephemeral cookies,
/// no redirects, no credential persistence and bounded response bodies.
nonisolated struct ToolQuotaService: ToolQuotaFetching {
    private let transport: any CursorUsageHTTPTransport
    private let home: URL
    private let environment: [String: String]
    private let readsSystemKeychain: Bool

    init(transport: any CursorUsageHTTPTransport = CursorUsageURLSessionTransport(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         readsSystemKeychain: Bool = true) {
        self.transport = transport
        self.home = home
        self.environment = environment
        self.readsSystemKeychain = readsSystemKeychain
    }

    func fetch(client: ToolUsageClient, preferences: ApplicationPreferences, now: Date) async -> ToolQuotaSnapshot {
        do {
            switch client {
            case .claudeCode:
                let root = preferences.dataDirectory(for: client.rawValue)
                    ?? self.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                    ?? self.home.appendingPathComponent(".claude")
                let settings = Self.json(root.appendingPathComponent("settings.json"))
                let configuredEnvironment = settings?["env"] as? [String: Any] ?? [:]
                let baseURL = self.environment["ANTHROPIC_BASE_URL"] ?? configuredEnvironment["ANTHROPIC_BASE_URL"] as? String
                guard Self.isOfficialBaseURL(baseURL, hosts: ["api.anthropic.com"]) else {
                    return Self.status(client, .unsupported, "Claude Code 接入服务", now,
                        "当前 Claude Code 使用自定义接入服务，Claude 官方订阅额度不适用于该服务")
                }
                let token = self.environment["CLAUDE_CODE_OAUTH_TOKEN"]
                    ?? Self.claudeAccessToken(Self.json(root.appendingPathComponent(".credentials.json")))
                    ?? (self.readsSystemKeychain && root.standardizedFileURL == self.home.appendingPathComponent(".claude").standardizedFileURL
                        ? Self.claudeAccessToken(Self.claudeKeychain()) : nil)
                guard let token = Self.secret(token) else {
                    return Self.status(client, .notConfigured, "Claude", now, "未读取到 Claude Code OAuth 登录；API Key 不含订阅额度，请先在 Claude Code 登录")
                }
                let object = try await self.get("https://api.anthropic.com/api/oauth/usage", token: token,
                    headers: ["anthropic-beta": "oauth-2025-04-20"], now: now)
                return Self.parseClaude(object, now: now)
            case .cursor:
                let root = preferences.dataDirectory(for: client.rawValue)
                let cookie = try CursorDesktopSessionReader(databaseURL: root?.appendingPathComponent("state.vscdb")).sessionCookie()
                let object = try await self.get("https://cursor.com/api/usage-summary", headers: [
                    "Cookie": "WorkosCursorSessionToken=\(cookie)", "Referer": "https://cursor.com/dashboard"
                ], now: now)
                return Self.parseCursor(object, now: now)
            case .openCode:
                return try await self.openCode(preferences: preferences, now: now)
            case .deepSeekHarness:
                return try await self.deepSeek(preferences: preferences, now: now)
            }
        } catch QuotaError.invalidConfiguration {
            return Self.status(client, .unsupported, client.displayName, now, "接入服务配置暂时无法读取；请检查原应用配置，当前未发送账户凭据")
        } catch QuotaError.noSubscription {
            return Self.status(client, .unsupported, client.displayName, now, "当前账户没有 OpenCode Go 订阅；本地用量仍可查看")
        } catch QuotaError.authentication {
            return Self.status(client, .authenticationRequired, client.displayName, now, "登录已过期或额度读取未获授权，请在原应用重新登录")
        } catch let error as CursorUsageSyncError where error == .noDesktopSession || error == .invalidDesktopSession {
            return Self.status(client, .notConfigured, client.displayName, now, "未读取到已登录的 Cursor，请先在 Cursor 登录")
        } catch QuotaError.rateLimited {
            return Self.status(client, .failed, client.displayName, now, "额度接口暂时限流，稍后自动重试")
        } catch {
            return Self.status(client, .failed, client.displayName, now, "额度接口暂时不可用或返回格式变化；本地用量统计仍可使用")
        }
    }

    /// Explicit credentials are scoped to the named official service. Never infer a binding from an arbitrary key.
    func fetchClaude(accessToken: String, now: Date) async -> ToolQuotaSnapshot {
        await self.explicitQuota(client: .claudeCode, now: now) {
            let object = try await self.get("https://api.anthropic.com/api/oauth/usage?cedar_ember=1", token: accessToken,
                headers: ["anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-cli/2.1.280 (external, cli)"], now: now)
            return Self.parseClaude(object, now: now)
        }
    }

    func fetchOpenCodeGo(apiKey: String, now: Date) async -> ToolQuotaSnapshot {
        await self.explicitQuota(client: .openCode, now: now) {
            let object = try await self.get("https://opencode.ai/zen/go/v1/usage", token: apiKey, now: now)
            let snapshot = Self.parseOpenCodeGo(object, now: now)
            // Token Monitor's Go parser treats a missing rolling/weekly window as a shape change.
            guard snapshot.windows.contains(where: { $0.id == "rolling" }),
                  snapshot.windows.contains(where: { $0.id == "weekly" }) else { throw QuotaError.invalidResponse }
            return snapshot
        }
    }

    func fetchDeepSeek(apiKey: String, client: ToolUsageClient = .deepSeekHarness, now: Date) async -> ToolQuotaSnapshot {
        await self.explicitQuota(client: client, now: now) {
            let object = try await self.get("https://api.deepseek.com/user/balance", token: apiKey, now: now)
            guard let balance = Self.deepSeekBalance(object) else { throw QuotaError.invalidResponse }
            return ToolQuotaSnapshot(client: client, status: .ready, providerName: "DeepSeek API",
                balance: balance, refreshedAt: now, statusDetail: "官方 API 余额；按量付费，不提供订阅百分比")
        }
    }

    /// Discovery applies the same configuration binding checks as the legacy single-client reader.
    func discoveredOpenCodeGoAPIKey(preferences: ApplicationPreferences) throws -> String? {
        let configuration = try self.openCodeProviderConfiguration()
        guard self.isOfficialOpenCodeProvider("opencode-go", configuration: configuration, hosts: ["opencode.ai"]) else { return nil }
        if let explicit = Self.secret(self.environment["TOKEN_MONITOR_OPENCODE_API_KEY"]) { return explicit }
        let root = preferences.dataDirectory(for: "openCode")
            ?? self.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("opencode") }
            ?? self.home.appendingPathComponent(".local/share/opencode")
        let object: [String: Any]
        if let inline = self.environment["OPENCODE_AUTH_CONTENT"], !inline.isEmpty {
            guard inline.utf8.count <= 2 * 1024 * 1024, let data = inline.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.invalidConfiguration }
            object = parsed
        } else { object = Self.json(root.appendingPathComponent("auth.json")) ?? [:] }
        guard let go = object["opencode-go"] as? [String: Any], go["type"] as? String == "api" else { return nil }
        return Self.secret(go["key"] as? String)
    }

    func discoveredOpenCodeDeepSeekAPIKey(preferences: ApplicationPreferences) throws -> String? {
        let configuration = try self.openCodeProviderConfiguration()
        guard self.isOfficialOpenCodeProvider("deepseek", configuration: configuration, hosts: ["api.deepseek.com"]) else { return nil }
        let root = preferences.dataDirectory(for: "openCode")
            ?? self.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("opencode") }
            ?? self.home.appendingPathComponent(".local/share/opencode")
        let document: [String: Any]
        if let inline = self.environment["OPENCODE_AUTH_CONTENT"], !inline.isEmpty {
            guard inline.utf8.count <= 2 * 1024 * 1024, let data = inline.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.invalidConfiguration }
            document = object
        } else { document = Self.json(root.appendingPathComponent("auth.json")) ?? [:] }
        guard let auth = document["deepseek"] as? [String: Any], auth["type"] as? String == "api" else { return nil }
        return Self.secret(auth["key"] as? String)
    }

    private func explicitQuota(client: ToolUsageClient, now: Date,
        query: () async throws -> ToolQuotaSnapshot) async -> ToolQuotaSnapshot {
        do { return try await query() }
        catch QuotaError.authentication {
            return Self.status(client, .authenticationRequired, client.displayName, now, "凭据已过期，请更新连接")
        } catch QuotaError.noSubscription {
            return Self.status(client, .unsupported, "OpenCode Go", now, "当前账户没有 OpenCode Go 订阅")
        } catch { return Self.status(client, .failed, client.displayName, now, "额度接口暂时不可用或返回格式变化") }
    }

    private func openCode(preferences: ApplicationPreferences, now: Date) async throws -> ToolQuotaSnapshot {
        let root = preferences.dataDirectory(for: "openCode")
            ?? self.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("opencode") }
            ?? self.home.appendingPathComponent(".local/share/opencode")
        let providerConfiguration = try self.openCodeProviderConfiguration()
        let auth: [String: Any]
        if let inline = self.environment["OPENCODE_AUTH_CONTENT"], let data = inline.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            auth = object
        } else { auth = Self.json(root.appendingPathComponent("auth.json")) ?? [:] }
        var windows: [ToolQuotaWindow] = []
        var balance: ToolQuotaBalance?
        var providers: [String] = []
        var failedProviders: [String] = []
        var authenticationRequiredProviders: [String] = []
        var unavailableProviders: [String] = []
        var customProviders: [String] = []
        if let go = auth["opencode-go"] as? [String: Any], go["type"] as? String == "api",
           let key = Self.secret(go["key"] as? String) {
            if !self.isOfficialOpenCodeProvider("opencode-go", configuration: providerConfiguration, hosts: ["opencode.ai"]) {
                customProviders.append("OpenCode Go 自定义接入服务")
            } else {
                do {
                    let result = try await self.get("https://opencode.ai/zen/go/v1/usage", token: key, now: now)
                    let snapshot = Self.parseOpenCodeGo(result, now: now)
                    windows.append(contentsOf: snapshot.windows.map { window in
                        ToolQuotaWindow(id: "go.\(window.id)", label: "Go · \(window.label)",
                            usedPercent: window.usedPercent, resetsAt: window.resetsAt)
                    })
                    if !snapshot.windows.isEmpty { providers.append("OpenCode Go") }
                    else { unavailableProviders.append(snapshot.statusDetail) }
                } catch QuotaError.noSubscription {
                    unavailableProviders.append("当前账户没有 OpenCode Go 订阅")
                } catch {
                    failedProviders.append("OpenCode Go 登录/额度读取失败")
                }
            }
        }
        if let deepseek = auth["deepseek"] as? [String: Any], deepseek["type"] as? String == "api",
           let key = Self.secret(deepseek["key"] as? String) {
            if !self.isOfficialOpenCodeProvider("deepseek", configuration: providerConfiguration, hosts: ["api.deepseek.com"]) {
                customProviders.append("DeepSeek 自定义接入服务")
            } else { do {
                let response = try await self.get("https://api.deepseek.com/user/balance", token: key, now: now)
                balance = Self.deepSeekBalance(response)
                if balance != nil { providers.append("DeepSeek") }
            } catch { failedProviders.append("DeepSeek 余额读取失败") } }
        }
        let ignoredProviders = auth.keys.filter { $0 == "openai" }
        let unsupportedProviders = auth.keys.filter { !["openai", "deepseek", "opencode-go"].contains($0) }.sorted()
        let details = failedProviders + authenticationRequiredProviders + unavailableProviders
            + (customProviders.isEmpty ? [] : ["自定义接入地址未提供已支持的额度接口：" + customProviders.joined(separator: "、")])
            + (ignoredProviders.isEmpty ? [] : ["已忽略 OpenCode 中的 OpenAI 登录；OpenCode 额度只读取 OpenCode Go 和 OpenCode 自己配置的接入服务"])
            + (unsupportedProviders.isEmpty ? [] : ["其他接入服务未返回统一额度：" + unsupportedProviders.joined(separator: "、")])
        if !windows.isEmpty || balance != nil {
            return ToolQuotaSnapshot(client: .openCode, status: .ready, providerName: providers.joined(separator: " · "),
                windows: windows, balance: balance, refreshedAt: now,
                statusDetail: (["来自 OpenCode 自己的 OpenCode Go / 接入服务；不读取 OpenAI 账号额度"] + details).joined(separator: "；"))
        }
        let status: ToolQuotaStatus = auth.isEmpty ? .notConfigured
            : !failedProviders.isEmpty ? .failed
            : !authenticationRequiredProviders.isEmpty ? .authenticationRequired : .unsupported
        return Self.status(.openCode, status,
            "OpenCode 接入服务", now, details.isEmpty ? "未发现 OpenCode Go 或支持额度查询的接入服务登录" : details.joined(separator: "；"))
    }

    private func deepSeek(preferences: ApplicationPreferences, now: Date) async throws -> ToolQuotaSnapshot {
        // DSH permits third-party keys under DEEPSEEK_API_KEY. The variable name
        // alone is never sufficient evidence to send a credential to DeepSeek.
        let explicitBaseURL = self.environment["DEEPSEEK_BASE_URL"] ?? self.environment["DEEPSEEK_API_BASE"]
        if explicitBaseURL != nil,
           Self.isOfficialBaseURL(explicitBaseURL, hosts: ["api.deepseek.com"]),
           let key = Self.secret(self.environment["DEEPSEEK_API_KEY"] ?? self.environment["DEEPSEEK_KEY"]) {
            let response = try await self.get("https://api.deepseek.com/user/balance", token: key, now: now)
            guard let balance = Self.deepSeekBalance(response) else { throw QuotaError.invalidResponse }
            return ToolQuotaSnapshot(client: .deepSeekHarness, status: .ready, providerName: "DeepSeek API",
                balance: balance, refreshedAt: now, statusDetail: "官方 API 余额；按量付费，不提供订阅百分比")
        }
        let root = preferences.dataDirectory(for: "deepSeekHarness")
            ?? self.environment["DSH_HOME"].map { URL(fileURLWithPath: $0) }
            ?? self.home.appendingPathComponent(".dsh")
        if let cached = Self.parseDeepSeekSnapshot(Self.json(root.appendingPathComponent("dsh-usage/provider-snapshots.json")) ?? [:]) {
            return cached
        }
        return Self.status(.deepSeekHarness, .notConfigured, "DSH 接入服务", now,
            "未读取到 DSH 保存的余额；请在 DSH 刷新接入服务余额。自定义服务的密钥不会发送到 DeepSeek 官方")
    }

    static func parseDeepSeekSnapshot(_ document: [String: Any]) -> ToolQuotaSnapshot? {
        let providers = document["providers"] as? [String: [String: Any]] ?? [:]
        let candidates = providers.map { ($0.key, $0.value) }.compactMap { id, entry -> (ToolQuotaBalance, Date, String)? in
            guard let raw = entry["balance"] as? [String: Any],
                  let amount = Self.finiteNumber(raw["totalBalance"]),
                  let currency = raw["currency"] as? String,
                  currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
                  let millis = Self.finiteNumber(raw["updatedAt"] ?? entry["updatedAt"]), millis >= 0 else { return nil }
            let label = (entry["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return (ToolQuotaBalance(amount: amount, currency: currency), Date(timeIntervalSince1970: millis / 1000), label)
        }.sorted { $0.1 > $1.1 }
        guard let cached = candidates.first else { return nil }
        return ToolQuotaSnapshot(client: .deepSeekHarness, status: .ready, providerName: "DSH · \(cached.2)",
            balance: cached.0, refreshedAt: cached.1,
            statusDetail: "DSH 保存的余额快照；这里刷新只重新读取文件，原始余额更新时间保持不变。请在 DSH 更新余额，或在管理中连接 DeepSeek 官方 API Key 以实时查询。")
    }

    /// Provider IDs can be overridden to use a different endpoint. Inspect all
    /// global configuration layers before using their auth.json credentials.
    private func openCodeProviderConfiguration() throws -> [[String: Any]] {
        let root = self.environment["OPENCODE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? self.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("opencode") }
            ?? self.home.appendingPathComponent(".config/opencode")
        var paths = [root.appendingPathComponent("opencode.json"), root.appendingPathComponent("opencode.jsonc")]
        if let path = self.environment["OPENCODE_CONFIG"] { paths.append(URL(fileURLWithPath: path)) }
        var documents: [[String: Any]] = []
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            guard let document = Self.json(path, json5: true) else { throw QuotaError.invalidConfiguration }
            documents.append(document["provider"] as? [String: Any] ?? [:])
        }
        if let inline = self.environment["OPENCODE_CONFIG_CONTENT"] {
            guard inline.utf8.count <= 2 * 1024 * 1024, let data = inline.data(using: .utf8),
                  let document = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
            else { throw QuotaError.invalidConfiguration }
            documents.append(document["provider"] as? [String: Any] ?? [:])
        }
        return documents
    }

    private func isOfficialOpenCodeProvider(_ providerID: String, configuration: [[String: Any]], hosts: Set<String>) -> Bool {
        let environmentNames: [String]
        switch providerID {
        case "deepseek": environmentNames = ["DEEPSEEK_BASE_URL", "DEEPSEEK_API_BASE"]
        case "openai": environmentNames = ["OPENAI_BASE_URL", "OPENAI_API_BASE"]
        case "opencode-go": environmentNames = ["OPENCODE_BASE_URL"]
        default: return false
        }
        var explicitlyBound = false
        for name in environmentNames {
            if !Self.isOfficialBaseURL(self.environment[name], hosts: hosts) { return false }
            if self.environment[name] != nil { explicitlyBound = true }
        }
        for providers in configuration {
            guard let entry = providers[providerID] as? [String: Any] else { continue }
            let options = entry["options"] as? [String: Any] ?? [:]
            for key in ["baseURL", "baseUrl", "base_url"] {
                guard let raw = options[key] else { continue }
                guard let value = raw as? String,
                      Self.isOfficialBaseURL(self.resolveEnvironment(value), hosts: hosts) else { return false }
                explicitlyBound = true
            }
        }
        // API keys can also originate from a project-level provider override.
        // OAuth and Go credentials have service-specific types; generic DeepSeek
        // API keys require a positive endpoint binding, never just their ID.
        return providerID != "deepseek" || explicitlyBound
    }

    private func resolveEnvironment(_ value: String) -> String {
        guard value.hasPrefix("{env:"), value.hasSuffix("}") else { return value }
        return self.environment[String(value.dropFirst(5).dropLast())] ?? ""
    }

    static func isOfficialBaseURL(_ raw: String?, hosts: Set<String>) -> Bool {
        guard let raw else { return true }
        guard let url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), hosts.contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    private func get(_ endpoint: String, token: String? = nil, headers: [String: String] = [:], now: Date) async throws -> [String: Any] {
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codexbar/1 usage-monitor", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await self.transport.data(for: request, limit: 2 * 1024 * 1024)
        guard response.url?.host == url.host, response.url?.scheme == "https" else { throw QuotaError.invalidResponse }
        if response.statusCode == 403,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (object["error"] as? [String: Any])?["type"] as? String == "EntitlementError" {
            throw QuotaError.noSubscription
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw QuotaError.authentication }
        if response.statusCode == 429 { throw QuotaError.rateLimited }
        guard (200...299).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.invalidResponse }
        return object
    }

    static func parseClaude(_ object: [String: Any], now: Date) -> ToolQuotaSnapshot {
        let names = [("five_hour", "5 小时"), ("seven_day", "7 天"), ("seven_day_sonnet", "Sonnet · 7 天"), ("seven_day_opus", "Opus · 7 天")]
        var windows = names.compactMap { key, label -> ToolQuotaWindow? in
            let alias = key == "five_hour" ? "fiveHour" : key == "seven_day" ? "sevenDay" : key
            guard let value = (object[key] ?? object[alias]) as? [String: Any],
                  let percent = Self.percent(value["usedPercent"] ?? value["used_percent"] ?? value["utilization"] ?? value["percent"]) else { return nil }
            return ToolQuotaWindow(id: key, label: label, usedPercent: percent, resetsAt: Self.date(value["resets_at"] ?? value["resetsAt"]))
        }
        // Token Monitor's credits mapping: spend and extra_usage are aliases for one money pool.
        let spend = object["spend"] as? [String: Any] ?? [:]
        let extra = (object["extra_usage"] ?? object["extraUsage"]) as? [String: Any] ?? [:]
        if Self.boolean(spend["enabled"]) == true || Self.boolean(extra["is_enabled"] ?? extra["isEnabled"]) == true {
            let spendUsed = Self.claudeMoney(spend["used"])
            let spendLimit = Self.claudeMoney(spend["limit"])
            let places = Self.number(extra["decimal_places"] ?? extra["decimalPlaces"]).flatMap { $0 <= 9 && $0.rounded() == $0 ? $0 : nil } ?? 2
            let used = spendUsed?.amount ?? Self.number(extra["used_credits"]).map { $0 / pow(10, places) }
            let limit = spendLimit?.amount ?? Self.number(extra["monthly_limit"]).map { $0 / pow(10, places) }
            let currency = spendUsed?.currency ?? (extra["currency"] as? String ?? "USD").uppercased()
            if let used, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil {
                windows.append(ToolQuotaWindow(id: "usageCredits", label: "额外用量", usedPercent: Self.ratio(used, limit),
                    used: used, limit: limit, unit: currency))
            }
        }
        if let limits = object["limits"] as? [[String: Any]],
           let fable = limits.first(where: { entry in
               entry["kind"] as? String == "weekly_scoped"
                   && (((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String)?.lowercased() == "fable"
           }), let percent = Self.percent(fable["usedPercent"] ?? fable["used_percent"] ?? fable["utilization"] ?? fable["percent"]) {
            windows.append(ToolQuotaWindow(id: "fableWeekly", label: "Fable · 7 天", usedPercent: percent,
                resetsAt: Self.date(fable["resets_at"] ?? fable["resetsAt"])))
        }
        let grants = (object["cedar_ember"] as? [String: Any])?["grants"] as? [[String: Any]] ?? []
        let active = grants.filter { grant in
            guard let left = Self.number(grant["resets_left"]), left > 0 else { return false }
            return Self.date(grant["ends_at"]).map { $0 > now } ?? true
        }
        let resetCount = active.reduce(0.0) { $0 + floor(Self.number($1["resets_left"]) ?? 0) }
        let resetSummary = resetCount > 0 && resetCount < Double(Int.max)
            ? "；\(Int(resetCount)) 张可用重置卡" + (active.compactMap { Self.date($0["ends_at"]) }.min().map { "，最早到期 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            : ""
        return ToolQuotaSnapshot(client: .claudeCode, status: windows.isEmpty ? .unsupported : .ready,
            providerName: "Claude", windows: windows, refreshedAt: now,
            statusDetail: (windows.isEmpty ? "Claude 未返回订阅额度窗口" : "Claude 账户服务端额度") + resetSummary)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func claudeMoney(_ value: Any?) -> ToolQuotaBalance? {
        guard let object = value as? [String: Any], let minor = Self.number(object["amount_minor"] ?? object["amountMinor"]) else { return nil }
        let exponent = Self.number(object["exponent"]).flatMap { $0 <= 9 && $0.rounded() == $0 ? $0 : nil } ?? 2
        let currency = (object["currency"] as? String ?? "USD").uppercased()
        guard currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return nil }
        return ToolQuotaBalance(amount: minor / pow(10, exponent), currency: currency)
    }

    static func parseCursor(_ object: [String: Any], now: Date) -> ToolQuotaSnapshot {
        let individual = object["individualUsage"] as? [String: Any] ?? [:]
        let plan = individual["plan"] as? [String: Any] ?? [:]
        let reset = Self.date(object["billingCycleEnd"])
        var windows: [ToolQuotaWindow] = []
        for (key, name) in [("autoPercentUsed", "Cursor 模型"), ("apiPercentUsed", "其他模型")] {
            if let percentage = Self.percent(plan[key]) { windows.append(ToolQuotaWindow(id: key, label: name, usedPercent: percentage, resetsAt: reset)) }
        }
        if windows.isEmpty {
            let overall = individual["overall"] as? [String: Any] ?? [:]
            let amount = Self.number(plan["used"]) ?? Self.number(overall["used"])
            let limit = Self.number(plan["limit"]) ?? Self.number(overall["limit"])
            let percentage = Self.percent(plan["totalPercentUsed"]) ?? Self.ratio(amount, limit)
            if percentage != nil || amount != nil {
                windows.append(ToolQuotaWindow(id: "plan", label: "套餐用量", usedPercent: percentage,
                    used: amount.map { $0 / 100 }, limit: limit.map { $0 / 100 }, unit: "USD", resetsAt: reset))
            }
        }
        let onDemand = individual["onDemand"] as? [String: Any] ?? [:]
        if let amount = Self.number(onDemand["used"]), amount > 0 {
            let limit = Self.number(onDemand["limit"])
            windows.append(ToolQuotaWindow(id: "onDemand", label: "额外用量", usedPercent: Self.ratio(amount, limit),
                used: amount / 100, limit: limit.map { $0 / 100 }, unit: "USD", resetsAt: reset))
        }
        let team = object["teamUsage"] as? [String: Any] ?? [:]
        for (key, label) in [("pooled", "团队共享用量"), ("onDemand", "团队额外用量")] {
            let value = team[key] as? [String: Any] ?? [:]
            guard let amount = Self.number(value["used"]) else { continue }
            let limit = Self.number(value["limit"])
            windows.append(ToolQuotaWindow(id: "team.\(key)", label: label, usedPercent: Self.ratio(amount, limit),
                used: amount / 100, limit: limit.map { $0 / 100 }, unit: "USD", resetsAt: reset))
        }
        return ToolQuotaSnapshot(client: .cursor, status: windows.isEmpty ? .unsupported : .ready,
            providerName: "Cursor", windows: windows, refreshedAt: now,
            statusDetail: windows.isEmpty ? "Cursor 账户未返回可显示的套餐额度" : "Cursor 账户服务端额度；独立于历史用量")
    }

    static func parseOpenCodeGo(_ object: [String: Any], now: Date) -> ToolQuotaSnapshot {
        let usage = object["usage"] as? [String: [String: Any]] ?? [:]
        let windows = [("rolling", "滚动窗口"), ("weekly", "本周"), ("monthly", "本月")].compactMap { key, label -> ToolQuotaWindow? in
            guard let value = usage[key],
                  let percent = Self.percent(value["percent"]) ?? (value["status"] as? String == "rate-limited" ? 100 : nil) else { return nil }
            return ToolQuotaWindow(id: key, label: label, usedPercent: percent, resetsAt: Self.date(value["resetsAt"]))
        }
        return ToolQuotaSnapshot(client: .openCode, status: windows.isEmpty ? .unsupported : .ready,
            providerName: "OpenCode Go", windows: windows, refreshedAt: now,
            statusDetail: windows.isEmpty ? "OpenCode Go 未返回额度窗口" : "OpenCode Go 官方订阅额度")
    }

    static func openAIWindows(_ object: [String: Any]) -> [ToolQuotaWindow] {
        var windows: [ToolQuotaWindow] = []
        for (group, prefix) in [("rate_limit", "OpenAI"), ("code_review_rate_limit", "代码审查")] {
            let rate = object[group] as? [String: Any] ?? [:]
            for key in ["primary_window", "secondary_window"] {
                guard let value = rate[key] as? [String: Any], let percentage = Self.percent(value["used_percent"]) else { continue }
                let seconds = Self.number(value["limit_window_seconds"]).flatMap { $0 > 0 && $0 <= 366 * 86400 ? $0 : nil }
                let label = seconds.map { $0 >= 86400 ? "\(Int($0 / 86400)) 天" : "\(Int($0 / 3600)) 小时" } ?? "用量"
                windows.append(ToolQuotaWindow(id: "\(group).\(key)", label: "\(prefix) · \(label)", usedPercent: percentage,
                    resetsAt: Self.number(value["reset_at"]).map { Date(timeIntervalSince1970: $0) }))
            }
        }
        return windows
    }

    static func deepSeekBalance(_ object: [String: Any]) -> ToolQuotaBalance? {
        let rows = object["balance_infos"] as? [[String: Any]] ?? []
        let balances = rows.compactMap { value -> ToolQuotaBalance? in
            guard let amount = Self.finiteNumber(value["total_balance"]), let currency = value["currency"] as? String,
                  ["USD", "CNY"].contains(currency) else { return nil }
            return ToolQuotaBalance(amount: amount, currency: currency)
        }
        // Token Monitor selects one funded currency; amounts in different currencies are never added.
        return balances.filter { $0.amount > 0 }.sorted {
            $0.amount == $1.amount ? $0.currency == "USD" && $1.currency != "USD" : $0.amount > $1.amount
        }.first ?? balances.first(where: { $0.currency == "USD" }) ?? balances.first
    }

    private static func status(_ client: ToolUsageClient, _ status: ToolQuotaStatus, _ provider: String, _ now: Date, _ detail: String) -> ToolQuotaSnapshot {
        ToolQuotaSnapshot(client: client, status: status, providerName: provider, refreshedAt: now, statusDetail: detail)
    }
    private static func json(_ url: URL, json5: Bool = false) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: json5 ? [.json5Allowed] : []) as? [String: Any]
    }
    private static func claudeAccessToken(_ object: [String: Any]?) -> String? {
        let oauth = object?["claudeAiOauth"] as? [String: Any] ?? object?["oauth"] as? [String: Any] ?? object
        return oauth?["accessToken"] as? String
    }
    private static func claudeKeychain() -> [String: Any]? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private static func secret(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.utf8.count <= 32 * 1024, !value.contains("\n"), !value.contains("\r") else { return nil }
        return value
    }
    private static func number(_ value: Any?) -> Double? {
        self.finiteNumber(value).flatMap { $0 >= 0 ? $0 : nil }
    }
    private static func finiteNumber(_ value: Any?) -> Double? {
        let result: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { result = value.doubleValue }
        else if let value = value as? String { result = Double(value) } else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    private static func percent(_ value: Any?) -> Double? { self.number(value).map { min(100, $0) } }
    private static func ratio(_ used: Double?, _ limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }; return min(100, used / limit * 100)
    }
    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private enum QuotaError: Error { case authentication, rateLimited, invalidResponse, invalidConfiguration, noSubscription }
}
