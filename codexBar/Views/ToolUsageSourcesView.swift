import SwiftUI

struct ToolUsageSourcesView: View {
    let snapshots: [ToolUsageClient: ToolUsageSnapshot]
    let isRefreshing: Bool
    let selectedScope: UsageScope
    let compactTokens: (Int) -> String
    let now: Date
    let onSelect: (ToolUsageClient) -> Void
    let onImportCursor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L.zh ? "软件用量" : "Tool usage")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(L.zh ? "本机／同步" : "Local / sync")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            ForEach(ToolUsageClient.allCases) { client in
                self.row(for: client)
            }
        }
    }

    private func row(for client: ToolUsageClient) -> some View {
        let snapshot = self.snapshots[client]
        let aggregate = UsagePresentation.aggregate(
            codex: .empty,
            external: self.snapshots,
            scope: .client(client),
            period: .last7Days,
            now: self.now,
            calendar: .current
        )
        return HStack(spacing: 6) {
            Button {
                self.onSelect(client)
            } label: {
                HStack(spacing: 7) {
                    Text(self.monogram(for: client))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(self.tint(for: client))
                        .frame(width: 24, height: 24)
                        .background(self.tint(for: client).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Text(self.statusText(for: snapshot))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(snapshot?.statusDetail ?? self.statusText(for: snapshot))
                    }

                    Spacer(minLength: 0)

                    if aggregate.tokens > 0 {
                        Text(self.compactTokens(aggregate.tokens))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(client.displayName)，\(self.statusText(for: snapshot))，\(aggregate.tokens) Token")
            .accessibilityValue(self.selectedScope == .client(client)
                ? (L.zh ? "已选中" : "Selected")
                : (L.zh ? "未选中" : "Not selected"))

            if client == .cursor {
                Button(action: self.onImportCursor) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(L.zh ? "导入 Cursor 用量 CSV" : "Import Cursor usage CSV")
                .accessibilityLabel(L.zh ? "导入 Cursor 用量 CSV" : "Import Cursor usage CSV")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(self.selectedScope == .client(client) ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.045))
        )
    }

    private func statusText(for snapshot: ToolUsageSnapshot?) -> String {
        if snapshot?.client == .cursor,
           self.isRefreshing,
           snapshot?.availability == .needsImport || snapshot?.availability == .noRecords {
            return L.zh ? "正在同步 Cursor" : "Syncing Cursor"
        }
        switch snapshot?.availability {
        case .ready:
            if snapshot?.client == .cursor {
                return snapshot?.evidence == .imported
                    ? (L.zh ? "CSV 已导入 · 近 7 天" : "CSV imported · last 7 days")
                    : (L.zh ? "已自动同步 · 近 7 天" : "Auto-synced · last 7 days")
            }
            return snapshot?.evidence == .imported
                ? (L.zh ? "已导入 · 近 7 天" : "Imported · last 7 days")
                : (L.zh ? "已读取 · 近 7 天" : "Read · last 7 days")
        case .failed:
            if snapshot?.client == .cursor {
                return L.zh ? "同步失败 · 可导入 CSV" : "Sync failed · CSV available"
            }
            return L.zh ? "读取异常 · 保留上次数据" : "Read failed · last data kept"
        case .partial:
            return L.zh ? "部分记录未读取" : "Some records unreadable"
        case .sourceMissing:
            if snapshot?.client == .cursor {
                return L.zh ? "未检测到 Cursor 登录" : "Cursor sign-in not found"
            }
            return L.zh ? "未找到本机记录" : "No local source"
        case .needsImport:
            return L.zh ? "导入用量 CSV" : "Import usage CSV"
        case .noRecords, nil:
            return L.zh ? "尚无记录" : "No records yet"
        }
    }

    private func monogram(for client: ToolUsageClient) -> String {
        switch client {
        case .claudeCode: "CC"
        case .openCode: "OC"
        case .cursor: "C"
        case .deepSeekHarness: "DS"
        }
    }

    private func tint(for client: ToolUsageClient) -> Color {
        switch client {
        case .claudeCode: .orange
        case .openCode: .indigo
        case .cursor: .mint
        case .deepSeekHarness: .cyan
        }
    }
}
