import SwiftUI

struct CompatibleProviderRowView: View {
    private var mint: Color { MenuSurface.accent }
    private var graphite: Color { MenuSurface.raised }
    let provider: CodexBarProvider
    let isActiveProvider: Bool
    let activeAccountId: String?
    let onActivate: (CodexBarProviderAccount) -> Void
    let onAddAccount: () -> Void
    let onDeleteAccount: (CodexBarProviderAccount) -> Void
    let onDeleteProvider: () -> Void
    let onReviewCompatibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActiveProvider ? self.mint : Color.primary.opacity(0.36))
                    .frame(width: 7, height: 7)

                Text(provider.label)
                    .font(MenuSurface.font(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(isActiveProvider ? self.mint : .white)
                    .lineLimit(1)

                Text(provider.hostLabel)
                    .font(MenuSurface.font(size: 9, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08))
                    .foregroundColor(Color.primary.opacity(0.64))
                    .cornerRadius(3)
                    .lineLimit(1)

                if isActiveProvider {
                    Image(systemName: "checkmark.circle.fill")
                        .font(MenuSurface.font(size: 10))
                        .foregroundColor(self.mint)
                }

                Spacer()

                Button(action: onAddAccount) {
                    Image(systemName: "plus")
                        .font(MenuSurface.font(size: 10))
                }
                .buttonStyle(.borderless)

                Button(action: onDeleteProvider) {
                    Image(systemName: "trash")
                        .font(MenuSurface.font(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            }

            if provider.usesChatCompletionsGateway {
                HStack(spacing: 6) {
                    Text(L.providerChatModeTitle)
                        .font(MenuSurface.font(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(L.providerReviewCompatibility, action: onReviewCompatibility)
                        .buttonStyle(.borderless)
                        .font(MenuSurface.font(size: 10))
                }
                .padding(.leading, 14)
            }

            ForEach(provider.accounts) { account in
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(MenuSurface.font(size: 11, weight: account.id == activeAccountId ? .semibold : .regular, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if account.id == activeAccountId {
                        Image(systemName: "checkmark")
                            .font(MenuSurface.font(size: 9, weight: .semibold))
                            .foregroundColor(self.mint)
                    }

                    Spacer()

                    Text(account.maskedAPIKey)
                        .font(MenuSurface.font(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if account.id != activeAccountId || isActiveProvider == false {
                        Button(L.zh ? "使用" : "Use") {
                            onActivate(account)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(MenuSurface.font(size: 10, weight: .medium))
                        .tint(self.mint)
                    }

                    Button {
                        onDeleteAccount(account)
                    } label: {
                        Image(systemName: "trash")
                            .font(MenuSurface.font(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
                .padding(.leading, 12)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(self.graphite.opacity(isActiveProvider ? 0.96 : 0.78))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActiveProvider ? self.mint.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1))
    }
}
