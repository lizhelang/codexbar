import AppKit
import SwiftUI

struct ResetCreditItemRow: View {
    let item: RateLimitResetCreditItem
    let now: Date
    let onUse: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.accountLabel)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(RateLimitResetCreditPresentation.relativeExpiry(item.expiresAt, now: self.now))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundColor(
                        item.remaining(now: self.now) <= RateLimitResetCreditPolicy.badgeHorizon
                            ? .orange
                            : .secondary
                    )
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(L.resetCreditUse, action: self.onUse)
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
        }
        .frame(height: 34, alignment: .leading)
    }
}

struct ResetCreditsPanelView: View {
    static let panelWidth: CGFloat = 280

    private static let maxVisibleRows = 8
    private static let rowHeight: CGFloat = 38
    private static let headerHeight: CGFloat = 36
    private static let verticalPadding: CGFloat = 24

    let items: [RateLimitResetCreditItem]
    let now: Date
    let onUse: (RateLimitResetCreditItem) -> Void

    static func panelHeight(itemCount: Int) -> CGFloat {
        let visible = min(max(itemCount, 1), self.maxVisibleRows)
        return self.headerHeight + CGFloat(visible) * self.rowHeight + self.verticalPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L.resetCreditsSectionTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(L.resetCreditCount(self.items.count))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }

            if self.items.count > Self.maxVisibleRows {
                ScrollView(showsIndicators: false) {
                    self.itemList
                }
            } else {
                self.itemList
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(
            width: Self.panelWidth,
            height: Self.panelHeight(itemCount: self.items.count),
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var itemList: some View {
        VStack(spacing: 4) {
            ForEach(self.items) { item in
                ResetCreditItemRow(item: item, now: self.now) {
                    self.onUse(item)
                }
            }
        }
    }
}
