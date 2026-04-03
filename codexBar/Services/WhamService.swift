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
        request.setValue(account.accountId, forHTTPHeaderField: "chatgpt-account-id")
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
        request.setValue(account.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [String: Any],
              let entry = accounts[account.accountId] as? [String: Any],
              let acct = entry["account"] as? [String: Any],
              let name = acct["name"] as? String else { return nil }
        return name
    }

    /// 刷新单个账号的用量和组织名
    func refreshOne(account: TokenAccount, store: TokenStore) async {
        let accountID = account.id
        let didBeginRefresh = await MainActor.run {
            store.beginUsageRefresh(accountID: accountID)
        }
        guard didBeginRefresh else { return }
        defer {
            Task { @MainActor in
                store.endUsageRefresh(accountID: accountID)
            }
        }

        do {
            async let usageResult = self.fetchUsage(account: account)
            async let orgName = self.fetchOrgName(account: account)
            let (result, name) = try await (usageResult, orgName)
            await MainActor.run {
                var updated = account
                updated.planType = result.planType
                updated.primaryUsedPercent = result.primaryUsedPercent
                updated.secondaryUsedPercent = result.secondaryUsedPercent
                updated.primaryResetAt = result.primaryResetAt
                updated.secondaryResetAt = result.secondaryResetAt
                updated.lastChecked = Date()
                if let name { updated.organizationName = name }
                store.addOrUpdate(updated)
            }
        } catch WhamError.forbidden {
            await MainActor.run {
                var updated = account
                updated.isSuspended = true
                store.addOrUpdate(updated)
            }
        } catch WhamError.unauthorized {
            await MainActor.run {
                var updated = account
                updated.tokenExpired = true
                store.addOrUpdate(updated)
            }
        } catch {
            // 静默失败，保留上次数据
        }
    }

    /// 批量刷新 store 中所有账号的用量和组织名
    func refreshAll(store: TokenStore) async {
        await withTaskGroup(of: Void.self) { group in
            for account in store.accounts {
                let accountID = account.id
                group.addTask {
                    let didBeginRefresh = await MainActor.run {
                        store.beginUsageRefresh(accountID: accountID)
                    }
                    guard didBeginRefresh else { return }
                    defer {
                        Task { @MainActor in
                            store.endUsageRefresh(accountID: accountID)
                        }
                    }

                    do {
                        async let usageResult = self.fetchUsage(account: account)
                        async let orgName = self.fetchOrgName(account: account)
                        let (result, name) = try await (usageResult, orgName)
                        await MainActor.run {
                            var updated = account
                            updated.planType = result.planType
                            updated.primaryUsedPercent = result.primaryUsedPercent
                            updated.secondaryUsedPercent = result.secondaryUsedPercent
                            updated.primaryResetAt = result.primaryResetAt
                            updated.secondaryResetAt = result.secondaryResetAt
                            updated.lastChecked = Date()
                            if let name { updated.organizationName = name }
                            store.addOrUpdate(updated)
                        }
                    } catch WhamError.forbidden {
                        await MainActor.run {
                            var updated = account
                            updated.isSuspended = true
                            store.addOrUpdate(updated)
                        }
                    } catch WhamError.unauthorized {
                        await MainActor.run {
                            var updated = account
                            updated.tokenExpired = true
                            store.addOrUpdate(updated)
                        }
                    } catch {
                        // 静默失败，保留上次数据
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func parseUsage(_ json: [String: Any]) -> WhamUsageResult {
        let planType = json["plan_type"] as? String ?? "free"
        var primaryUsedPercent: Double = 0
        var secondaryUsedPercent: Double = 0
        var primaryResetAt: Date? = nil
        var secondaryResetAt: Date? = nil

        if let rateLimit = json["rate_limit"] as? [String: Any] {

            // primary_window = 5h 窗口，used_percent: 0=未用, 100=耗尽
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                primaryUsedPercent = primary["used_percent"] as? Double ?? 0
                if let ts = primary["reset_at"] as? TimeInterval {
                    primaryResetAt = Date(timeIntervalSince1970: ts)
                }
            }

            // secondary_window = 周额度，used_percent: 0=本周未用, 100=耗尽
            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                let used = secondary["used_percent"] as? Double ?? 0
                if used > 0 {
                    secondaryUsedPercent = used
                    if let ts = secondary["reset_at"] as? TimeInterval {
                        secondaryResetAt = Date(timeIntervalSince1970: ts)
                    }
                }
            }
        }

        return WhamUsageResult(
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt
        )
    }
}

struct WhamUsageResult {
    let planType: String
    let primaryUsedPercent: Double
    let secondaryUsedPercent: Double
    let primaryResetAt: Date?
    let secondaryResetAt: Date?
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
