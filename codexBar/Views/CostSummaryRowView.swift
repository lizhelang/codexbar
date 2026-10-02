import SwiftUI

struct CostSummaryRowView: View {
    let summary: LocalCostSummary
    let externalUsage: [ToolUsageClient: ToolUsageSnapshot]
    var refreshState: LocalCostRefreshState = .idle
    @Binding var scope: UsageScope
    @Binding var period: UsagePeriod
    @Binding var metric: UsageMetric
    let currency: (Double) -> String
    let compactTokens: (Int) -> String
    let onShowDetails: () -> Void
    var now: Date = Date()
    var calendar: Calendar = .current

    private var aggregate: UsageAggregate {
        UsagePresentation.aggregate(
            codex: self.summary,
            external: self.externalUsage,
            scope: self.scope,
            period: self.period,
            now: self.now,
            calendar: self.calendar
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(L.zh ? "用量" : "Usage")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                RouteSelectionMenu(
                    title: self.scope.title,
                    accessibilityLabel: L.zh ? "工具范围" : "Tool scope",
                    items: UsageScope.allCases.map { option in
                        RouteSelectionMenuItem(id: option.id, title: option.title, isSelected: self.scope == option) {
                            self.scope = option
                        }
                    }
                )
                .fixedSize()
                Button(action: self.onShowDetails) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help(L.zh ? "查看用量详情" : "Show usage details")
                .accessibilityLabel(L.zh ? "查看用量详情" : "Show usage details")
            }

            HStack(spacing: 7) {
                Picker(L.zh ? "时间范围" : "Period", selection: self.$period) {
                    ForEach(UsagePeriod.primaryCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)

                RouteSelectionMenu(
                    title: UsagePeriod.additionalCases.contains(self.period) ? self.period.title : (L.zh ? "更多" : "More"),
                    accessibilityLabel: L.zh ? "更多时间范围" : "More periods",
                    items: UsagePeriod.additionalCases.map { option in
                        RouteSelectionMenuItem(id: option.rawValue, title: option.title, isSelected: self.period == option) {
                            self.period = option
                        }
                    }
                )
                .fixedSize()

                Picker(L.zh ? "指标" : "Metric", selection: self.$metric) {
                    ForEach(UsageMetric.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.metricText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(self.metricCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let statusText = self.statusText {
                HStack(spacing: 6) {
                    if self.scope == .codex && self.refreshState.isScanning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(statusText)
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundColor(self.statusColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var metricText: String {
        switch self.metric {
        case .tokens:
            return self.compactTokens(self.aggregate.tokens)
        case .cost:
            if self.aggregate.costIsComplete == false && self.aggregate.knownCostUSD == 0 {
                return "—"
            }
            let prefix = self.aggregate.costIsComplete ? "" : "≥"
            return prefix + self.currency(self.aggregate.knownCostUSD)
        }
    }

    private var metricCaption: String {
        switch self.metric {
        case .tokens:
            return L.zh ? "Token" : "tokens"
        case .cost:
            return self.aggregate.costIsComplete
                ? (L.zh ? "估算／来源报告" : "estimated / reported")
                : (L.zh ? "部分来源费用未知" : "partial cost")
        }
    }

    private var statusText: String? {
        switch self.scope {
        case .codex:
            return LocalCostSummaryPresentation.statusText(for: self.refreshState)
        case .client(let client):
            let snapshot = self.externalUsage[client]
            switch snapshot?.availability {
            case .ready:
                if let refreshedAt = snapshot?.refreshedAt {
                    return (L.zh ? "已更新 " : "Updated ") + refreshedAt.formatted(date: .omitted, time: .shortened)
                }
                return nil
            case .failed:
                return snapshot?.statusDetail ?? (L.zh ? "读取失败" : "Read failed")
            case .partial:
                return snapshot?.statusDetail ?? (L.zh ? "部分记录未读取" : "Some records unreadable")
            case .needsImport:
                return L.zh ? "请导入 Cursor 用量 CSV" : "Import a Cursor usage CSV"
            case .sourceMissing:
                return L.zh ? "本机未找到数据源" : "Source not found on this Mac"
            case .noRecords, nil:
                return L.zh ? "尚无用量记录" : "No usage records yet"
            }
        case .all:
            let unavailableCount = ToolUsageClient.allCases.filter {
                self.externalUsage[$0]?.availability != .ready
            }.count
            if unavailableCount > 0 {
                return L.zh
                    ? "已读取来源合计 · \(unavailableCount) 个来源未就绪"
                    : "Available sources · \(unavailableCount) not ready"
            }
            return self.aggregate.costIsComplete
                ? (L.zh ? "已读取来源的合计" : "Total from available sources")
                : (L.zh ? "已读取来源合计 · 部分费用未知" : "Available sources · partial cost")
        }
    }

    private var statusColor: Color {
        if case .client(let client) = self.scope,
           self.externalUsage[client]?.availability == .failed
            || self.externalUsage[client]?.availability == .partial {
            return .orange
        }
        if self.scope == .codex,
           case .failed = self.refreshState.phase {
            return .orange
        }
        return .secondary
    }
}

struct CostDetailsPanelView: View {
    static let panelWidth: CGFloat = 272

    static func panelHeight(hasHistory: Bool) -> CGFloat {
        hasHistory ? 356 : 204
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let costUSD: Double
        let totalTokens: Int
        let costIsComplete: Bool
    }

    private struct MiniBarChart: View {
        let points: [Point]
        let metric: UsageMetric
        @Binding var selectedID: String?

        private let minBarHeight: CGFloat = 6
        private let barSpacing: CGFloat = 4

        var body: some View {
            GeometryReader { geometry in
                let maxValue = max(points.map { self.value(for: $0) }.max() ?? 0, 0.01)
                let slotWidth = geometry.size.width / CGFloat(Swift.max(points.count, 1))

                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(points) { point in
                        let isSelected = selectedID == point.id
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.68))
                            .frame(maxWidth: .infinity)
                        .frame(height: self.barHeight(for: point, totalHeight: geometry.size.height, maxValue: maxValue))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard points.isEmpty == false,
                              location.x >= 0,
                              location.x <= geometry.size.width else {
                            selectedID = nil
                            return
                        }

                        let index = min(max(Int(location.x / max(slotWidth, 1)), 0), points.count - 1)
                        selectedID = points[index].id
                    case .ended:
                        selectedID = nil
                    }
                }
            }
            .frame(height: 128)
        }

        private func value(for point: Point) -> Double {
            self.metric == .tokens ? Double(point.totalTokens) : point.costUSD
        }

        private func barHeight(for point: Point, totalHeight: CGFloat, maxValue: Double) -> CGFloat {
            guard totalHeight > 0, self.value(for: point) > 0 else { return 0 }
            let usableHeight = max(totalHeight - 4, minBarHeight)
            let value = self.value(for: point)
            let ratio = value > 0 ? CGFloat(value / maxValue) : 0
            return max(minBarHeight, usableHeight * ratio)
        }
    }

    let summary: LocalCostSummary
    let externalUsage: [ToolUsageClient: ToolUsageSnapshot]
    var refreshState: LocalCostRefreshState = .idle
    let scope: UsageScope
    let period: UsagePeriod
    let metric: UsageMetric
    let currency: (Double) -> String
    let compactTokens: (Int) -> String
    let shortDay: (Date) -> String
    var now: Date = Date()
    var calendar: Calendar = .current

    @State private var selectedID: String?

    private var aggregate: UsageAggregate {
        UsagePresentation.aggregate(
            codex: self.summary,
            external: self.externalUsage,
            scope: self.scope,
            period: self.period,
            now: self.now,
            calendar: self.calendar
        )
    }

    private var points: [Point] {
        UsagePresentation.chartEntries(
            aggregate: self.aggregate,
            period: self.period,
            now: self.now,
            calendar: self.calendar
        )
            .map { entry in
                Point(
                    id: String(entry.date.timeIntervalSince1970),
                    date: entry.date,
                    costUSD: entry.knownCostUSD,
                    totalTokens: entry.tokens,
                    costIsComplete: entry.costIsComplete
                )
            }
    }

    private var selectedPoint: Point? {
        guard let selectedID else { return nil }
        return points.first(where: { $0.id == selectedID })
    }

    private var hasChartValues: Bool {
        switch self.metric {
        case .tokens: points.contains { $0.totalTokens > 0 }
        case .cost: points.contains { $0.costUSD > 0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(self.scope.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(self.period.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            metricRow(title: L.zh ? "Token" : "Tokens", value: "\(compactTokens(self.aggregate.tokens)) tokens")
            metricRow(
                title: self.aggregate.costIsComplete
                    ? (L.zh ? "费用" : "Cost")
                    : (L.zh ? "已知费用下限" : "Known cost lower bound"),
                value: self.aggregate.costIsComplete || self.aggregate.knownCostUSD > 0
                    ? (self.aggregate.costIsComplete ? "" : "≥") + currency(self.aggregate.knownCostUSD)
                    : "—"
            )

            if self.scope == .codex,
               let statusText = LocalCostSummaryPresentation.statusText(for: self.refreshState) {
                HStack(spacing: 6) {
                    if self.refreshState.isScanning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(statusText)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Divider()

            if self.hasChartValues == false {
                Text(self.emptyChartText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                MiniBarChart(points: points, metric: self.metric, selectedID: $selectedID)

                HStack {
                    if let first = points.first {
                        Text(shortDay(first.date))
                    }

                    Spacer()

                    if let last = points.last {
                        Text(shortDay(last.date))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    Text(primaryDetailText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: 16, alignment: .leading)
                    Text(secondaryDetailText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: 16, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(
            width: Self.panelWidth,
            height: Self.panelHeight(hasHistory: self.hasChartValues),
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

    private func metricRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func primaryDetailText() -> String {
        if let point = selectedPoint {
            switch self.metric {
            case .tokens:
                return "\(shortDay(point.date)) · \(compactTokens(point.totalTokens)) tokens"
            case .cost:
                guard point.costIsComplete || point.costUSD > 0 else {
                    return "\(shortDay(point.date)) · —"
                }
                return "\(shortDay(point.date)) · \(point.costIsComplete ? "" : "≥")\(currency(point.costUSD))"
            }
        }
        return self.period == .allTime
            ? (L.zh ? "全部累计 · 图示最近 30 天" : "All-time total · chart shows last 30d")
            : (L.zh ? "每日趋势" : "Daily trend")
    }

    private func secondaryDetailText() -> String {
        if let point = selectedPoint {
            return self.metric == .tokens
                ? (point.costIsComplete
                    ? currency(point.costUSD)
                    : (L.zh ? "部分费用未知" : "Partial cost unknown"))
                : "\(compactTokens(point.totalTokens)) tokens"
        }
        return self.aggregate.costIsComplete
            ? (L.zh ? "悬停柱形查看每日数据" : "Hover bars for daily details")
            : (L.zh ? "部分来源未提供完整费用" : "Some costs are unavailable")
    }

    private var emptyChartText: String {
        if self.period == .allTime && self.aggregate.tokens > 0 {
            return L.zh ? "已计入历史总量；最近 30 天无可显示数据" : "Included above; nothing to chart in the last 30d"
        }
        if self.metric == .cost && self.aggregate.tokens > 0 {
            return L.zh ? "本期间无可显示的费用" : "No chartable cost for this period"
        }
        return L.zh ? "暂无用量记录" : "No usage history"
    }
}

enum LocalCostSummaryPresentation {
    static func shouldDisplayUnknown(summary: LocalCostSummary) -> Bool {
        summary.updatedAt == nil && summary.dailyEntries.isEmpty && summary.lifetimeTokens == 0
    }

    static func statusText(for state: LocalCostRefreshState) -> String? {
        switch state.phase {
        case .idle:
            return nil
        case .scanning:
            if let fraction = state.progress.fractionCompleted {
                return "Scanning local records… \(Int((fraction * 100).rounded(.down)))%"
            }
            return "Scanning local records…"
        case .success:
            guard let lastRawSessionScanAt = state.lastRawSessionScanAt else { return "Cost history updated" }
            return "Scanned \(lastRawSessionScanAt.formatted(date: .omitted, time: .shortened))"
        case .partial:
            return state.warningCount > 0
                ? "Updated with \(state.warningCount) warning\(state.warningCount == 1 ? "" : "s")"
                : "History catch-up is still running"
        case .failed(let message):
            return "Cost update failed: \(message)"
        }
    }
}

enum LocalCostChartSeries {
    nonisolated(unsafe) private static let idFormatter = ISO8601DateFormatter()

    static func entries(
        summary: LocalCostSummary,
        now: Date,
        calendar: Calendar
    ) -> [DailyCostEntry] {
        guard summary.dailyEntries.isEmpty == false else { return [] }

        let today = calendar.startOfDay(for: now)
        var byDay: [Date: DailyCostEntry] = [:]
        for entry in summary.dailyEntries {
            let day = calendar.startOfDay(for: entry.date)
            let existing = byDay[day]
            byDay[day] = DailyCostEntry(
                id: Self.idFormatter.string(from: day),
                date: day,
                costUSD: (existing?.costUSD ?? 0) + entry.costUSD,
                totalTokens: (existing?.totalTokens ?? 0) + entry.totalTokens
            )
        }

        return (0..<30).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - 29, to: today) else {
                return nil
            }
            if let entry = byDay[day] {
                return DailyCostEntry(
                    id: Self.idFormatter.string(from: day),
                    date: day,
                    costUSD: entry.costUSD,
                    totalTokens: entry.totalTokens
                )
            }
            return DailyCostEntry(
                id: Self.idFormatter.string(from: day),
                date: day,
                costUSD: 0,
                totalTokens: 0
            )
        }
    }
}
