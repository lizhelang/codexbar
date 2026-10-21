import CoreFoundation
import Foundation

// Cursor session normalization, desktop discovery and account probing are adapted from
// Javis603/token-monitor (MIT, Copyright (c) 2026 Javis), commit
// 10ae6127088537bd7c9d004d814dcfe8a94c3c87, providers/cursor/{auth,desktopState,probe,selfSync}.js.
// Native transport adds bounded responses, no redirects and isolated cookie storage.
nonisolated protocol CursorAccountServicing: Sendable {
    func probe(sessionCookie: String, now: Date) async throws -> CursorAccountProbe
    func usage(sessionCookie: String, now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot
    func usage(sessionCookie: String, previous: ToolUsageSnapshot?, now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot
}

extension CursorAccountServicing {
    nonisolated func usage(sessionCookie: String, previous: ToolUsageSnapshot?, now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        try await self.usage(sessionCookie: sessionCookie, now: now, calendar: calendar)
    }
}

nonisolated struct CursorPlanInfo: Equatable, Sendable {
    enum IncludedUsagePeriod: String, Equatable, Sendable {
        case weekly
        case monthly
    }

    let isMerged: Bool
    let planName: String?
    let includedUsagePeriod: IncludedUsagePeriod?
    let includedUsageResetsAt: Date?
    let billingCycleEnd: Date?

    init(_ response: [String: Any]) {
        let info = response["planInfo"] as? [String: Any] ?? [:]
        self.isMerged = (CursorAccountService.boolean(response["isMerged"])
            ?? CursorAccountService.boolean(info["isMerged"])) == true
        self.planName = (info["planName"] as? String).flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch info["includedUsagePeriod"] as? String {
        case "INCLUDED_USAGE_PERIOD_WEEKLY":
            self.includedUsagePeriod = .weekly
        case "INCLUDED_USAGE_PERIOD_MONTHLY":
            self.includedUsagePeriod = .monthly
        default:
            self.includedUsagePeriod = nil
        }
        self.includedUsageResetsAt = CursorAccountService.epochMillisDate(info["includedUsageResetsAt"])
            ?? CursorAccountService.date(info["includedUsageResetsAt"])
        self.billingCycleEnd = CursorAccountService.epochMillisDate(info["billingCycleEnd"])
            ?? CursorAccountService.date(info["billingCycleEnd"])
    }
}

nonisolated struct CursorSandUsage: Equatable, Sendable {
    let usedPercent: Double?
    let resetsAt: Date?
    let hasNonZeroIncludedLimit: Bool?
    let isUnified: Bool

    init(_ response: [String: Any]) {
        self.usedPercent = CursorAccountService.number(response["usagePercent"]).map { min(100, max(0, $0)) }
        self.resetsAt = CursorAccountService.date(response["nextResetTimestampUtc"])
            ?? CursorAccountService.epochMillisDate(response["nextResetTimestampUtc"])
        self.hasNonZeroIncludedLimit = CursorAccountService.boolean(response["hasNonZeroIncludedLimit"])
        self.isUnified = CursorAccountService.boolean(response["isUnified"]) == true
    }
}

nonisolated struct CursorPrepaidBilling: Equatable, Sendable {
    let availableUsd: Double?

    init(_ response: [String: Any]) {
        if response["availableCents"] == nil {
            self.availableUsd = 0
        } else if let cents = CursorAccountService.int64(response["availableCents"]) {
            self.availableUsd = max(0, Double(cents)) / 100.0
        } else {
            self.availableUsd = nil
        }
    }
}

nonisolated struct CursorAccountService: CursorAccountServicing {
    private let transport: any CursorUsageHTTPTransport
    private static let responseLimit = 4 * 1024 * 1024
    private static let currentPeriodUsagePath = "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

    init(transport: any CursorUsageHTTPTransport = CursorUsageURLSessionTransport()) {
        self.transport = transport
    }

    func probe(sessionCookie: String, now: Date = Date()) async throws -> CursorAccountProbe {
        let cookie = try Self.normalize(sessionCookie)
        let expectedID = try Self.userID(sessionCookie: cookie)
        let user = try await self.request("/api/auth/me", cookie: cookie)
        guard let userID = Self.canonicalUserID(user["sub"] as? String ?? user["id"] as? String ?? user["userId"] as? String),
              userID == expectedID else { throw CursorAccountError.identityMismatch }
        let summary = try await self.request("/api/usage-summary", cookie: cookie)
        // An empty/error-shaped 200 response is not successful validation.
        guard summary["individualUsage"] is [String: Any] || summary["teamUsage"] is [String: Any]
                || summary["membershipType"] is String || summary["isUnlimited"] is Bool else {
            throw CursorAccountError.invalidResponse
        }

        // Plan info and sand status are best-effort optional probes (5s timeout).
        // Plan info is authoritative for unified (The X Subscription) vs split plans;
        // sand's unified flag only stands in when plan info is unavailable.
        let planInfo = (try? await self.request("/api/dashboard/get-plan-info", cookie: cookie, method: "POST", timeout: 5))
            .map(CursorPlanInfo.init)
        let sand = (try? await self.request("/api/dashboard/get-sand-usage-status", cookie: cookie, method: "POST", timeout: 5))
            .map(CursorSandUsage.init)
        let isUnified = planInfo?.isMerged ?? (sand?.isUnified == true)

        var requestUsage: [String: Any]?
        var prepaid: CursorPrepaidBilling?
        var currentPeriodPercent: Double?

        if isUnified {
            // Only unified plans carry a prepaid balance and weekly/current-period RPC usage.
            prepaid = (try? await self.request("/api/dashboard/get-user-prepaid-billing", cookie: cookie, method: "POST", timeout: 5))
                .map(CursorPrepaidBilling.init)
            currentPeriodPercent = await self.requestCurrentPeriodPercent(cookie: cookie, timeout: 5)
        } else if let subject = Self.safeDisplayText(user["sub"] as? String, cookie: cookie) {
            // Older request-based memberships expose the request allowance separately.
            requestUsage = try? await self.request("/api/usage", cookie: cookie, query: [URLQueryItem(name: "user", value: subject)])
        }

        let quota = ToolQuotaService.parseCursor(
            summary,
            planInfo: planInfo,
            sand: sand,
            prepaid: prepaid,
            currentPeriodPercent: currentPeriodPercent,
            requestUsage: requestUsage,
            now: now
        )
        let planType = Self.formatPlanType(
            membershipType: Self.safeDisplayText(summary["membershipType"] as? String, cookie: cookie),
            planName: Self.safeDisplayText(planInfo?.planName, cookie: cookie),
            isUnified: isUnified
        )
        let identity = CursorAccountIdentity(userID: userID,
            email: Self.safeDisplayText(user["email"] as? String, cookie: cookie),
            name: Self.safeDisplayText(user["name"] as? String, cookie: cookie),
            planType: planType)
        return CursorAccountProbe(identity: identity, quota: quota)
    }

    func usage(sessionCookie: String, now: Date = Date(), calendar: Calendar = .current) async throws -> ToolUsageSnapshot {
        try await self.usage(sessionCookie: sessionCookie, previous: nil, now: now, calendar: calendar)
    }

    func usage(sessionCookie: String, previous: ToolUsageSnapshot?, now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        do {
            let cookie = try Self.normalize(sessionCookie)
            var legacy = try await CursorUsageSyncer(transport: self.transport).sync(sessionCookie: cookie, now: now, calendar: calendar)
            let oldRecords = previous?.usageRecords.filter { !$0.id.hasPrefix("cursor-billing:") } ?? []
            if legacy.usageRecords.isEmpty, !oldRecords.isEmpty {
                legacy = ToolUsageSnapshot(client: .cursor, availability: .partial, evidence: .server,
                    usageRecords: oldRecords, latestUsageAt: oldRecords.map(\.timestamp).max(), refreshedAt: now)
            }
            let usage = try await CursorBillingUsageSyncer(transport: self.transport)
                .sync(sessionCookie: cookie, legacy: legacy, previous: previous, now: now, calendar: calendar)
            return Self.sanitizedUsage(usage, cookie: cookie)
        } catch { throw CursorAccountError.sanitized(error) }
    }

    /// Also applies to imported account usage: textual metadata must never echo a session.
    static func sanitizedUsage(_ usage: ToolUsageSnapshot, cookie: String) -> ToolUsageSnapshot {
        return ToolUsageSnapshot(client: .cursor, availability: usage.availability, evidence: usage.evidence,
                dailyEntries: usage.dailyEntries, usageRecords: usage.usageRecords.map { row in
                    ToolUsageRecord(id: Self.safeDisplayText(row.id, cookie: cookie) ?? "redacted-\(UUID().uuidString)",
                        timestamp: row.timestamp, modelID: Self.safeDisplayText(row.modelID, cookie: cookie),
                        sessionID: Self.safeDisplayText(row.sessionID, cookie: cookie),
                        sessionTitle: Self.safeDisplayText(row.sessionTitle, cookie: cookie),
                        projectPath: Self.safeDisplayText(row.projectPath, cookie: cookie),
                        sessionIsRunning: row.sessionIsRunning, contextWindowTokens: row.contextWindowTokens,
                        contextUsedTokens: row.contextUsedTokens, inputTokens: row.inputTokens, outputTokens: row.outputTokens,
                        cacheReadTokens: row.cacheReadTokens, cacheWriteTokens: row.cacheWriteTokens,
                        totalTokens: row.totalTokens, costUSD: row.costUSD, costEvidence: row.costEvidence, billedCostUSD: row.billedCostUSD)
                }, latestUsageAt: usage.latestUsageAt, refreshedAt: usage.refreshedAt,
                statusDetail: Self.safeDisplayText(usage.statusDetail, cookie: cookie),
                billingHistoryInterval: usage.billingHistoryInterval)
    }

    static func normalize(_ raw: String) throws -> String {
        do { return try CursorDesktopSessionReader.normalizedCookie(raw) }
        catch { throw CursorAccountError.invalidCredential }
    }

    static func userID(sessionCookie: String) throws -> String {
        let cookie = try self.normalize(sessionCookie)
        guard let separator = cookie.range(of: "%3A%3A"),
              let id = self.canonicalUserID(String(cookie[..<separator.lowerBound])),
              id == String(cookie[..<separator.lowerBound]) else { throw CursorAccountError.invalidCredential }
        return id
    }

    static func sessionAccessToken(sessionCookie: String) -> String? {
        let decoded = sessionCookie.removingPercentEncoding ?? sessionCookie
        guard let separator = decoded.range(of: "::") else { return nil }
        let token = decoded[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }),
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            return nil
        }
        return token
    }

    static func formatPlanType(membershipType: String?, planName: String?, isUnified: Bool) -> String? {
        if let raw = membershipType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            switch raw.lowercased() {
            case "pro+", "pro_plus": return "Pro+"
            case "unified_ultra": return "Ultra"
            default: return raw
            }
        }
        if isUnified, let planName = planName?.trimmingCharacters(in: .whitespacesAndNewlines), !planName.isEmpty {
            return planName
        }
        return nil
    }

    static func parseCurrentPeriodUsage(_ response: [String: Any]) -> Double? {
        guard let plan = response["planUsage"] as? [String: Any],
              let value = self.decimal(plan["totalPercentUsed"]) else { return nil }
        return min(100, max(0, value))
    }

    static func canonicalUserID(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 512,
              let range = value.range(of: #"user_[A-Za-z0-9_]+"#, options: .regularExpression) else { return nil }
        return String(value[range])
    }

    static func safeDisplayText(_ raw: String?, cookie: String) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.utf8.count <= 512, value.rangeOfCharacter(from: .controlCharacters) == nil,
              !value.contains(cookie), !value.localizedCaseInsensitiveContains("WorkosCursorSessionToken"),
              !value.contains(cookie.components(separatedBy: "%3A%3A").last ?? cookie) else { return nil }
        return value
    }

    private func request(_ path: String, cookie: String, query: [URLQueryItem] = [], method: String = "GET", timeout: TimeInterval = 15) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "cursor.com"
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CursorAccountError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.httpBody = Data("{}".utf8)
        }
        do {
            let (data, response) = try await self.transport.data(for: request, limit: Self.responseLimit)
            guard data.count <= Self.responseLimit else { throw CursorAccountError.responseTooLarge }
            guard response.url?.scheme == "https", response.url?.host == "cursor.com", response.url?.port == nil,
                  response.url?.path == path else { throw CursorAccountError.invalidResponse }
            if response.statusCode == 401 || response.statusCode == 403 { throw CursorAccountError.authenticationRequired }
            // 会话失效（例如在桌面端退出登录）时 /api/auth/me 返回 204 空响应。
            if path == "/api/auth/me", response.statusCode == 204 || data.isEmpty {
                throw CursorAccountError.authenticationRequired
            }
            guard (200...299).contains(response.statusCode) else { throw CursorAccountError.networkFailure }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CursorAccountError.invalidResponse
            }
            return object
        } catch { throw CursorAccountError.sanitized(error) }
    }

    private func requestCurrentPeriodPercent(cookie: String, timeout: TimeInterval = 5) async -> Double? {
        guard let accessToken = Self.sessionAccessToken(sessionCookie: cookie) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api2.cursor.sh"
        components.path = Self.currentPeriodUsagePath
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        guard let (data, response) = try? await self.transport.data(for: request, limit: Self.responseLimit),
              data.count <= Self.responseLimit,
              response.url?.scheme == "https",
              response.url?.host == "api2.cursor.sh",
              response.url?.port == nil,
              response.url?.path == Self.currentPeriodUsagePath,
              (200...299).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Self.parseCurrentPeriodUsage(object)
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func number(_ input: Any?) -> Double? {
        guard let input = input as? NSNumber, CFGetTypeID(input) != CFBooleanGetTypeID(),
              input.doubleValue.isFinite, input.doubleValue >= 0 else { return nil }
        return input.doubleValue
    }

    static func decimal(_ input: Any?) -> Double? {
        if let input = input as? NSNumber, CFGetTypeID(input) != CFBooleanGetTypeID(), input.doubleValue.isFinite {
            return input.doubleValue
        }
        if let text = (input as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, let value = Double(text), value.isFinite {
            return value
        }
        return nil
    }

    static func int64(_ input: Any?) -> Int64? {
        let maxSafeInteger: Int64 = 9_007_199_254_740_991
        if let number = input as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            guard value.isFinite, value.rounded() == value, abs(value) <= Double(maxSafeInteger) else { return nil }
            return number.int64Value
        }
        if let text = (input as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.range(of: #"^-?\d+$"#, options: .regularExpression) != nil,
           let parsed = Int64(text), abs(parsed) <= maxSafeInteger {
            return parsed
        }
        return nil
    }

    static func epochMillisDate(_ value: Any?) -> Date? {
        let maxDateMillis: Int64 = 8_640_000_000_000_000
        guard let millis = self.int64(value), millis > 0, millis <= maxDateMillis else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000.0)
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
