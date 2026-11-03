import Foundation

/// 解析“桌面端当前账号”，不更换登录，也不按邮箱猜测相同账号。
enum CodexQuotaResumeAccountResolution: Equatable {
    case resolved(accountID: String)
    case unavailable(reason: String)

    var accountID: String? {
        if case let .resolved(accountID) = self { return accountID }
        return nil
    }

    var failureReason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }

    static func resolve(
        mode: CodexBarOpenAIAccountUsageMode,
        isOpenAIProvider: Bool,
        activeAccount: TokenAccount?,
        authRemoteAccountID: String?,
        authAccessToken: String?
    ) -> Self {
        guard mode == .switchAccount else {
            return .unavailable(reason: "当前使用聚合网关，暂不支持自动续跑。请先切换为手动切换模式。")
        }
        guard isOpenAIProvider else {
            return .unavailable(reason: "当前连接不是 OpenAI 登录账号，暂不支持自动续跑。")
        }
        guard let account = activeAccount else {
            return .unavailable(reason: "尚未识别到当前账号，请先在 Codexbar 中选择已登录的 OpenAI 账号。")
        }
        guard !account.isSuspended, !account.tokenExpired else {
            return .unavailable(reason: "当前账号不可用，请先检查登录状态。")
        }
        guard let authRemoteAccountID, !authRemoteAccountID.isEmpty else {
            return .unavailable(reason: "暂时无法读取 Codex 的登录身份，请确认桌面端已登录。")
        }
        guard account.remoteAccountId == authRemoteAccountID else {
            return .unavailable(reason: "Codexbar 当前账号与 Codex 登录身份不一致，请先同步账号。")
        }
        // account_id 只标识工作区。同一团队中的不同用户不能共用续跑授权。
        guard let authAccessToken else {
            return .unavailable(reason: "暂时无法确认 Codex 的登录用户，请检查桌面端登录。")
        }
        let selectedClaims = AccountBuilder.authClaims(fromAccessToken: account.accessToken)
        let desktopClaims = AccountBuilder.authClaims(fromAccessToken: authAccessToken)
        guard self.claim(selectedClaims, "chatgpt_account_id") == account.remoteAccountId,
              self.claim(desktopClaims, "chatgpt_account_id") == authRemoteAccountID else {
            return .unavailable(reason: "登录令牌与所选工作区不一致，已停止自动续跑。")
        }
        let identityPairs = [
            (self.claim(selectedClaims, "chatgpt_account_user_id"), self.claim(desktopClaims, "chatgpt_account_user_id")),
            (AccountBuilder.chatGPTUserID(fromAuthClaims: selectedClaims), AccountBuilder.chatGPTUserID(fromAuthClaims: desktopClaims)),
        ]
        var matchedUser = false
        for (selected, desktop) in identityPairs {
            guard let selected, let desktop else { continue }
            guard selected == desktop else {
                return .unavailable(reason: "Codexbar 当前账号与 Codex 登录用户不一致，请先同步账号。")
            }
            matchedUser = true
        }
        guard matchedUser else {
            return .unavailable(reason: "登录信息缺少可核对的用户身份，已停止自动续跑。")
        }
        return .resolved(accountID: account.id)
    }

    private static func claim(_ claims: [String: Any], _ key: String) -> String? {
        guard let value = claims[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
