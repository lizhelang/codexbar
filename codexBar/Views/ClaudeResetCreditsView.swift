import SwiftUI

/// The account owns these offers; the official Usage page performs redemption and confirmation.
@MainActor
struct ClaudeResetCreditsView: View {
    static let usageURL = URL(string: "https://claude.ai/settings/usage")!
    let snapshot: ToolQuotaSnapshot
    var now: Date = Date()

    var body: some View {
        if self.snapshot.client == .claudeCode, let inventory = self.snapshot.resetCredits {
            let grants = inventory.activeGrants(at: self.now)
            let count = inventory.availableCount(at: self.now)
            let singleGrant = inventory.eligible && grants.count == 1 ? grants.first : nil
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(Self.cardTitle(singleGrant))
                        .font(MenuSurface.font(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .help(singleGrant.map { Self.scopeTitle($0.clears) } ?? (L.zh ? "额度重置卡" : "Limit resets"))
                    Text(inventory.eligible && (!inventory.hasMalformedGrants || count > 0)
                         ? (inventory.hasMalformedGrants ? "≥" : "") + (L.zh ? "\(count) 张" : "\(count)") : "—")
                        .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
                        .fixedSize()
                        .accessibilityIdentifier("codexbar.claude.reset-credits.count")
                    if self.snapshot.status != .ready {
                        Text(L.zh ? "上次读取" : "Last seen")
                            .font(MenuSurface.font(size: 9))
                            .foregroundStyle(MenuSurface.muted)
                    }
                    Spacer(minLength: 4)
                    if let singleGrant {
                        self.expiryLabel(singleGrant)
                            .accessibilityIdentifier("codexbar.claude.reset-credits.grant.\(singleGrant.id)")
                    }
                    self.usageLink
                }
                if !inventory.eligible {
                    Text(L.zh ? "请在 Claude 用量页查看重置卡资格" : "Check reset eligibility on Claude's Usage page")
                        .font(MenuSurface.font(size: 9))
                        .foregroundStyle(MenuSurface.muted)
                } else {
                    if singleGrant == nil {
                        ForEach(grants) { grant in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Self.scopeTitle(grant.clears))
                                    .font(MenuSurface.font(size: 9, weight: .medium))
                                if grant.remaining > 1 {
                                    Text(L.zh ? "\(grant.remaining) 张" : "\(grant.remaining)")
                                        .font(MenuSurface.font(size: 9, design: .monospaced))
                                }
                                Spacer(minLength: 4)
                                self.expiryLabel(grant)
                            }
                            .accessibilityIdentifier("codexbar.claude.reset-credits.grant.\(grant.id)")
                            self.redeemabilityNote(grant)
                        }
                    } else if let singleGrant {
                        self.redeemabilityNote(singleGrant)
                    }
                    if inventory.hasMalformedGrants {
                        Text(L.zh ? "部分重置卡数据无法读取" : "Some reset details could not be read")
                            .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                    } else if grants.isEmpty {
                        Text(L.zh ? "暂无可用重置卡" : "No available resets")
                            .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                    }
                }
            }
            .padding(.top, 3)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("codexbar.claude.reset-credits")
        }
    }

    private var usageLink: some View {
        Link(destination: Self.usageURL) {
            Label(L.zh ? "使用" : "Use", systemImage: "arrow.up.right")
        }
        .font(MenuSurface.font(size: 9, weight: .medium))
        .foregroundStyle(MenuSurface.accent)
        .fixedSize()
        .help(L.zh ? "在 Claude 官方用量页确认账号后使用重置卡" : "Confirm your account and use a reset on Claude's Usage page")
        .accessibilityLabel(L.zh ? "前往 Claude 使用重置卡" : "Use limit resets in Claude")
        .accessibilityIdentifier("codexbar.claude.reset-credits.open-usage")
    }

    private func expiryLabel(_ grant: ClaudeResetCreditGrant) -> some View {
        Text(self.expiryText(grant.expiresAt))
            .font(MenuSurface.font(size: 9, design: .monospaced))
            .lineLimit(1)
            .help(self.expiryText(grant.expiresAt))
            .foregroundStyle(grant.expiresAt.map { $0.timeIntervalSince(self.now) <= 3 * 86_400 } == true
                ? Color.orange : MenuSurface.muted)
    }

    @ViewBuilder
    private func redeemabilityNote(_ grant: ClaudeResetCreditGrant) -> some View {
        if grant.usableNow == false {
            Text(L.zh ? "当前暂不可使用，请以 Claude 用量页为准" : "Not redeemable now; check Claude's Usage page")
                .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
        }
    }

    private static func cardTitle(_ grant: ClaudeResetCreditGrant?) -> String {
        guard let grant, !grant.clears.isEmpty else { return L.zh ? "重置卡" : "Limit resets" }
        let windows = ["five_hour": "5h", "seven_day": "7d"]
        let labels = grant.clears.compactMap { windows[$0] }
        guard labels.count == grant.clears.count else { return L.zh ? "重置卡" : "Limit resets" }
        return labels.joined(separator: "/") + (L.zh ? " 重置卡" : " resets")
    }

    private func expiryText(_ expiry: Date?) -> String {
        guard let expiry else { return L.zh ? "未提供到期时间" : "Expiry not provided" }
        let remaining = TokenAccount.compactResetRemaining(until: expiry, now: self.now)
        return L.zh ? "\(remaining)后到期" : "Expires in \(remaining)"
    }

    private static func scopeTitle(_ clears: [String]) -> String {
        let names = ["five_hour": L.zh ? "5 小时额度" : "5-hour limit",
                     "seven_day": L.zh ? "7 天额度" : "Weekly limit"]
        let labels = clears.compactMap { names[$0] }
        guard !labels.isEmpty, labels.count == clears.count else { return L.zh ? "额度重置卡" : "Limit reset" }
        return labels.joined(separator: " / ")
    }
}
