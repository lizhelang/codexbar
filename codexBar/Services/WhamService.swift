import Foundation

class WhamService {
    static let shared = WhamService()
    private init() {}

    private let baseURL = "https://chatgpt.com/backend-api/wham/usage"

    /// 查询单个账号的 wham usage
    func fetchUsage(account: TokenAccount) async throws -> WhamUsageResult {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WhamError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw WhamError.unauthorized
        case 402: throw WhamError.forbidden  // deactivated_workspace
        case 403: throw WhamError.forbidden
        default: throw WhamError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhamError.parseError
        }
        return parseUsage(json)
    }

    /// 查询账号所属组织名称
    func fetchOrgName(account: TokenAccount) async -> String? {
        let urlStr = "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27?timezone_offset_min=-480"
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [String: Any],
              let entry = accounts[account.remoteAccountId] as? [String: Any],
              let acct = entry["account"] as? [String: Any],
              let name = acct["name"] as? String else { return nil }
        return name
    }

    /// 刷新单个账号的用量和组织名
    @discardableResult
    func refreshOne(
        account: TokenAccount,
        store: TokenStore,
        usageFetcher: ((TokenAccount) async throws -> WhamUsageResult)? = nil,
        orgNameFetcher: ((TokenAccount) async -> String?)? = nil,
        oauthRefresh: ((TokenAccount) async -> OpenAIOAuthRefreshOutcome)? = nil
    ) async -> WhamRefreshOutcome {
        let accountID = account.id
        let didBeginRefresh = await MainActor.run {
            store.beginUsageRefresh(accountID: accountID)
        }
        guard didBeginRefresh else { return .skipped }
        defer {
            Task { @MainActor in
                store.endUsageRefresh(accountID: accountID)
            }
        }

        return await self.performRefresh(
            account: account,
            store: store,
            usageFetcher: usageFetcher ?? self.fetchUsage(account:),
            orgNameFetcher: orgNameFetcher ?? self.fetchOrgName(account:),
            oauthRefresh: oauthRefresh ?? { account in
                await OpenAIOAuthRefreshService.shared.refreshNow(account: account, force: true)
            },
            allowUnauthorizedRecovery: true
        )
    }

    /// 批量刷新 store 中所有账号的用量和组织名
    func refreshAll(
        store: TokenStore,
        usageFetcher: ((TokenAccount) async throws -> WhamUsageResult)? = nil,
        orgNameFetcher: ((TokenAccount) async -> String?)? = nil,
        oauthRefresh: ((TokenAccount) async -> OpenAIOAuthRefreshOutcome)? = nil
    ) async -> [WhamRefreshOutcome] {
        await withTaskGroup(of: WhamRefreshOutcome.self, returning: [WhamRefreshOutcome].self) { group in
            for account in store.accounts {
                let accountID = account.id
                group.addTask {
                    let didBeginRefresh = await MainActor.run {
                        store.beginUsageRefresh(accountID: accountID)
                    }
                    guard didBeginRefresh else { return .skipped }
                    defer {
                        Task { @MainActor in
                            store.endUsageRefresh(accountID: accountID)
                        }
                    }

                    return await self.performRefresh(
                        account: account,
                        store: store,
                        usageFetcher: usageFetcher ?? self.fetchUsage(account:),
                        orgNameFetcher: orgNameFetcher ?? self.fetchOrgName(account:),
                        oauthRefresh: oauthRefresh ?? { account in
                            await OpenAIOAuthRefreshService.shared.refreshNow(account: account, force: true)
                        },
                        allowUnauthorizedRecovery: true
                    )
                }
            }

            var outcomes: [WhamRefreshOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    // MARK: - Private

    private func performRefresh(
        account: TokenAccount,
        store: TokenStore,
        usageFetcher: @escaping (TokenAccount) async throws -> WhamUsageResult,
        orgNameFetcher: @escaping (TokenAccount) async -> String?,
        oauthRefresh: @escaping (TokenAccount) async -> OpenAIOAuthRefreshOutcome,
        allowUnauthorizedRecovery: Bool
    ) async -> WhamRefreshOutcome {
        do {
            async let usageResult = usageFetcher(account)
            async let orgName = orgNameFetcher(account)
            let (result, name) = try await (usageResult, orgName)
            await MainActor.run {
                var updated = account
                updated.planType = result.planType
                updated.primaryUsedPercent = result.primaryUsedPercent
                updated.secondaryUsedPercent = result.secondaryUsedPercent
                updated.primaryResetAt = result.primaryResetAt
                updated.secondaryResetAt = result.secondaryResetAt
                updated.primaryLimitWindowSeconds = result.primaryLimitWindowSeconds
                updated.secondaryLimitWindowSeconds = result.secondaryLimitWindowSeconds
                updated.lastChecked = Date()
                updated.tokenExpired = false
                if let name { updated.organizationName = name }
                store.addOrUpdate(updated)
            }
            return .updated
        } catch WhamError.forbidden {
            await MainActor.run {
                var updated = account
                updated.isSuspended = true
                store.addOrUpdate(updated)
            }
            return .forbidden(WhamError.forbidden.errorDescription ?? "Forbidden")
        } catch WhamError.unauthorized where allowUnauthorizedRecovery {
            switch await oauthRefresh(account) {
            case .refreshed(let refreshedAccount):
                return await self.performRefresh(
                    account: refreshedAccount,
                    store: store,
                    usageFetcher: usageFetcher,
                    orgNameFetcher: orgNameFetcher,
                    oauthRefresh: oauthRefresh,
                    allowUnauthorizedRecovery: false
                )
            case .terminalFailure:
                await MainActor.run {
                    var updated = account
                    updated.tokenExpired = true
                    store.addOrUpdate(updated)
                }
                return .unauthorized(WhamError.unauthorized.errorDescription ?? "Unauthorized")
            case .transientFailure(let message):
                return .failed(message)
            case .skipped:
                return .failed(WhamError.unauthorized.errorDescription ?? "Unauthorized")
            }
        } catch WhamError.unauthorized {
            return .failed(WhamError.unauthorized.errorDescription ?? "Unauthorized")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func parseUsage(_ json: [String: Any]) -> WhamUsageResult {
        let planType = json["plan_type"] as? String ?? "free"
        var primaryUsedPercent: Double = 0
        var secondaryUsedPercent: Double = 0
        var primaryResetAt: Date? = nil
        var secondaryResetAt: Date? = nil
        var primaryLimitWindowSeconds: Int? = nil
        var secondaryLimitWindowSeconds: Int? = nil

        if let rateLimit = json["rate_limit"] as? [String: Any] {
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                primaryUsedPercent = primary["used_percent"] as? Double ?? 0
                if let seconds = primary["limit_window_seconds"] as? Int {
                    primaryLimitWindowSeconds = seconds
                } else if let seconds = primary["limit_window_seconds"] as? Double {
                    primaryLimitWindowSeconds = Int(seconds)
                }
                if let ts = primary["reset_at"] as? TimeInterval {
                    primaryResetAt = Date(timeIntervalSince1970: ts)
                }
            }

            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                secondaryUsedPercent = secondary["used_percent"] as? Double ?? 0
                if let seconds = secondary["limit_window_seconds"] as? Int {
                    secondaryLimitWindowSeconds = seconds
                } else if let seconds = secondary["limit_window_seconds"] as? Double {
                    secondaryLimitWindowSeconds = Int(seconds)
                }
                if let ts = secondary["reset_at"] as? TimeInterval {
                    secondaryResetAt = Date(timeIntervalSince1970: ts)
                }
            }
        }

        return WhamUsageResult(
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            primaryLimitWindowSeconds: primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: secondaryLimitWindowSeconds
        )
    }
}

struct WhamUsageResult {
    let planType: String
    let primaryUsedPercent: Double
    let secondaryUsedPercent: Double
    let primaryResetAt: Date?
    let secondaryResetAt: Date?
    let primaryLimitWindowSeconds: Int?
    let secondaryLimitWindowSeconds: Int?
}

enum WhamRefreshOutcome: Equatable {
    case updated
    case unauthorized(String)
    case forbidden(String)
    case failed(String)
    case skipped

    var errorMessage: String? {
        switch self {
        case .unauthorized(let message), .forbidden(let message), .failed(let message):
            return message
        case .updated, .skipped:
            return nil
        }
    }
}

enum WhamError: LocalizedError {
    case invalidResponse, unauthorized, forbidden, parseError
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无效响应"
        case .unauthorized: return "Token 已过期"
        case .forbidden: return "账号被封禁"
        case .parseError: return "解析失败"
        case .httpError(let code): return "HTTP \(code)"
        }
    }
}
