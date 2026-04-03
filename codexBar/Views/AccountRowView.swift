import SwiftUI

/// One org/account row under an email group
struct AccountRowView: View {
    let account: TokenAccount
    let isActive: Bool
    let now: Date
    let isRefreshing: Bool
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onReauth: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: org name + plan badge + active mark + switch button
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Text(displayName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .accentColor : .primary)
                    .lineLimit(1)

                Text(account.planType.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(planBadgeColor.opacity(0.15))
                    .foregroundColor(planBadgeColor)
                    .cornerRadius(3)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 10))
                }

                Spacer()

                // 删除按钮（NSAlert 二次确认）
                Button {
                    let alert = NSAlert()
                    alert.messageText = L.confirmDelete(displayName)
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L.delete)
                    alert.addButton(withTitle: L.cancel)
                    if alert.runModal() == .alertFirstButtonReturn {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)

                if account.tokenExpired {
                    Button(L.reauth, action: onReauth)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                        .tint(.orange)
                } else if !account.isBanned {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .disabled(isRefreshing)

                    if !isActive {
                        Button(L.switchBtn, action: onActivate)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .font(.system(size: 10, weight: .medium))
                    }
                }
            }

            // Line 2: usage info
            if account.tokenExpired {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(L.tokenExpiredHint)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Spacer()
                }
            } else if account.isBanned {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(L.accountSuspended)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Spacer()
                }
            } else if account.quotaExhausted {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    let label = account.secondaryExhausted ? L.weeklyExhausted : L.primaryExhausted
                    let resetDesc = account.secondaryExhausted ? account.secondaryResetDescription : account.primaryResetDescription
                    Text(resetDesc.isEmpty ? label : "\(label) · \(resetDesc)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Spacer()
                }
            } else {
                HStack(spacing: 6) {
                    Text("5h")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(Int(account.primaryUsedPercent))%")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(usageColor(account.primaryUsedPercent))
                    Text("•")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("7d")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(Int(account.secondaryUsedPercent))%")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(usageColor(account.secondaryUsedPercent))
                    Spacer()
                }
            }

            // Reset countdown
            if !account.isBanned {
                HStack(spacing: 8) {
                    if account.primaryUsedPercent >= 70, !account.primaryResetDescription.isEmpty {
                        Text("5h: " + account.primaryResetDescription)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    if account.secondaryUsedPercent >= 70, !account.secondaryResetDescription.isEmpty {
                        Text("7d: " + account.secondaryResetDescription)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 16)   // indent under email header
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
    }

    private var displayName: String {
        if let org = account.organizationName, !org.isEmpty { return org }
        return String(account.accountId.prefix(8))
    }

    private var statusColor: Color {
        if account.isBanned { return .red }
        if account.quotaExhausted { return .orange }
        if account.primaryUsedPercent >= 80 || account.secondaryUsedPercent >= 80 { return .yellow }
        return .green
    }

    private var planBadgeColor: Color {
        switch account.planType.lowercased() {
        case "team": return .blue
        case "plus": return .purple
        default: return .gray
        }
    }

    private func usageColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }
}
