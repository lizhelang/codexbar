import CoreFoundation
import Foundation

// Cursor session normalization, desktop discovery and account probing are adapted from
// Javis603/token-monitor (MIT, Copyright (c) 2026 Javis), commit
// 10ae6127088537bd7c9d004d814dcfe8a94c3c87, providers/cursor/{auth,desktopState,probe,selfSync}.js.
// Native transport adds bounded responses, no redirects and isolated cookie storage.
nonisolated protocol CursorAccountServicing: Sendable {
    func probe(sessionCookie: String, now: Date) async throws -> CursorAccountProbe
    func usage(sessionCookie: String, now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot
}

nonisolated struct CursorAccountService: CursorAccountServicing {
    private let transport: any CursorUsageHTTPTransport
    private static let responseLimit = 4 * 1024 * 1024

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
        var quota = ToolQuotaService.parseCursor(summary, now: now)

        // Older request-based memberships expose the request allowance separately.
        // Optional endpoint failures never discard the validated main summary.
        if let subject = Self.safeDisplayText(user["sub"] as? String, cookie: cookie),
           let legacy = try? await self.request("/api/usage", cookie: cookie, query: [URLQueryItem(name: "user", value: subject)]),
           let requests = legacy["gpt-4"] as? [String: Any] ?? legacy["gpt4"] as? [String: Any],
           let used = Self.number(requests["numRequestsTotal"] ?? requests["numRequests"]),
           let limit = Self.number(requests["maxRequestUsage"]), limit > 0 {
            // token-monitor prefers an explicit request allowance for legacy plans;
            // the request window and newer monetary/model pools are alternate schemas.
            quota.windows.removeAll { ["autoPercentUsed", "apiPercentUsed", "plan"].contains($0.id) }
            quota.windows.insert(ToolQuotaWindow(id: "requests", label: "套餐请求", usedPercent: min(100, max(0, used / limit * 100)),
                used: used, limit: limit, unit: "次", resetsAt: Self.date(summary["billingCycleEnd"])), at: 0)
        }
        if let sand = try? await self.request("/api/dashboard/get-sand-usage-status", cookie: cookie, method: "POST", timeout: 5),
           let percent = Self.number(sand["usagePercent"]),
           sand["hasNonZeroIncludedLimit"] as? Bool == true || percent > 0 {
            quota.windows.append(ToolQuotaWindow(id: "grokBot", label: "Grok Code", usedPercent: min(100, max(0, percent)),
                resetsAt: Self.date(sand["nextResetTimestampUtc"])))
        }
        if !quota.windows.isEmpty, quota.status != .ready {
            quota = ToolQuotaSnapshot(client: .cursor, status: .ready, providerName: "Cursor", windows: quota.windows,
                refreshedAt: now, statusDetail: "Cursor 账户服务端额度；独立于历史用量")
        }
        let identity = CursorAccountIdentity(userID: userID,
            email: Self.safeDisplayText(user["email"] as? String, cookie: cookie),
            name: Self.safeDisplayText(user["name"] as? String, cookie: cookie),
            planType: Self.safeDisplayText(summary["membershipType"] as? String, cookie: cookie))
        return CursorAccountProbe(identity: identity, quota: quota)
    }

    func usage(sessionCookie: String, now: Date = Date(), calendar: Calendar = .current) async throws -> ToolUsageSnapshot {
        do {
            let cookie = try Self.normalize(sessionCookie)
            let usage = try await CursorUsageSyncer(transport: self.transport).sync(sessionCookie: cookie, now: now, calendar: calendar)
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
                statusDetail: Self.safeDisplayText(usage.statusDetail, cookie: cookie))
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
            guard (200...299).contains(response.statusCode) else { throw CursorAccountError.networkFailure }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CursorAccountError.invalidResponse
            }
            return object
        } catch { throw CursorAccountError.sanitized(error) }
    }

    private static func number(_ input: Any?) -> Double? {
        guard let input = input as? NSNumber, CFGetTypeID(input) != CFBooleanGetTypeID(),
              input.doubleValue.isFinite, input.doubleValue >= 0 else { return nil }
        return input.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
