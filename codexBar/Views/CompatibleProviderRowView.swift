import SwiftUI

struct CompatibleProviderRowView: View {
    let provider: CodexBarProvider
    let isActiveProvider: Bool
    let activeAccountId: String?
    let onActivate: (CodexBarProviderAccount) -> Void
    let onAddAccount: () -> Void
    let onDeleteAccount: (CodexBarProviderAccount) -> Void
    let onDeleteProvider: () -> Void
    let onReviewCompatibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActiveProvider ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)

                Text(provider.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActiveProvider ? .accentColor : .primary)

                Text(provider.hostLabel)
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundColor(.secondary)
                    .cornerRadius(3)

                if isActiveProvider {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }

                Spacer()

                Button(action: onAddAccount) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)

                Button(action: onDeleteProvider) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            }

            if provider.usesChatCompletionsGateway {
                HStack(spacing: 6) {
                    Text(L.providerChatModeTitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(L.providerReviewCompatibility, action: onReviewCompatibility)
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                }
                .padding(.leading, 14)
            }

            ForEach(provider.accounts) { account in
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(.system(size: 11, weight: account.id == activeAccountId ? .semibold : .regular))

                    if account.id == activeAccountId {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }

                    Spacer()

                    Text(account.maskedAPIKey)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if account.id != activeAccountId || isActiveProvider == false {
                        Button("Use") {
                            onActivate(account)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                    }

                    Button {
                        onDeleteAccount(account)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActiveProvider ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
        )
    }
}
