import SwiftUI

struct CostSummaryRowView: View {
    let summary: LocalCostSummary
    var refreshState: LocalCostRefreshState = .idle
    let currency: (Double) -> String
    let compactTokens: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cost")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(self.todayText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(self.last30DaysText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let statusText = LocalCostSummaryPresentation.statusText(for: self.refreshState) {
                HStack(spacing: 6) {
                    if self.refreshState.isScanning {
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

    private var todayText: String {
        guard LocalCostSummaryPresentation.shouldDisplayUnknown(summary: self.summary) == false else {
            return "Today: —"
        }
        return "Today: \(self.currency(self.summary.todayCostUSD)) · \(self.compactTokens(self.summary.todayTokens)) tokens"
    }

    private var last30DaysText: String {
        guard LocalCostSummaryPresentation.shouldDisplayUnknown(summary: self.summary) == false else {
            return "Last 30 days: —"
        }
        return "Last 30 days: \(self.currency(self.summary.last30DaysCostUSD)) · \(self.compactTokens(self.summary.last30DaysTokens)) tokens"
    }

    private var statusColor: Color {
        if case .failed = self.refreshState.phase {
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
    }

    private struct MiniBarChart: View {
        let points: [Point]
        @Binding var selectedID: String?

        private let minBarHeight: CGFloat = 6
        private let barSpacing: CGFloat = 4

        var body: some View {
            GeometryReader { geometry in
                let maxCost = max(points.map(\.costUSD).max() ?? 0, 0.01)
                let slotWidth = geometry.size.width / CGFloat(Swift.max(points.count, 1))

                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(points) { point in
                        let isSelected = selectedID == point.id
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.68))
                            .frame(maxWidth: .infinity)
                            .frame(height: self.barHeight(for: point, totalHeight: geometry.size.height, maxCost: maxCost))
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

        private func barHeight(for point: Point, totalHeight: CGFloat, maxCost: Double) -> CGFloat {
            guard totalHeight > 0 else { return minBarHeight }
            let usableHeight = max(totalHeight - 4, minBarHeight)
            let ratio = point.costUSD > 0 ? CGFloat(point.costUSD / maxCost) : 0
            return max(minBarHeight, usableHeight * ratio)
        }
    }

    let summary: LocalCostSummary
    var refreshState: LocalCostRefreshState = .idle
    let currency: (Double) -> String
    let compactTokens: (Int) -> String
    let shortDay: (Date) -> String
    var now: Date = Date()
    var calendar: Calendar = .current

    @State private var selectedID: String?

    private var points: [Point] {
        LocalCostChartSeries.entries(
            summary: self.summary,
            now: self.now,
            calendar: self.calendar
        )
            .map { entry in
                Point(id: entry.id, date: entry.date, costUSD: entry.costUSD, totalTokens: entry.totalTokens)
            }
    }

    private var selectedPoint: Point? {
        guard let selectedID else { return nil }
        return points.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricRow(title: "Today", cost: summary.todayCostUSD, tokens: summary.todayTokens)
            metricRow(title: "Last 30 Days", cost: summary.last30DaysCostUSD, tokens: summary.last30DaysTokens)
            metricRow(title: "All-Time", cost: summary.lifetimeCostUSD, tokens: summary.lifetimeTokens)

            if let statusText = LocalCostSummaryPresentation.statusText(for: self.refreshState) {
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

            if points.isEmpty {
                Text("No cost history data.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                MiniBarChart(points: points, selectedID: $selectedID)

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
            height: Self.panelHeight(hasHistory: !points.isEmpty),
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

    private func metricRow(title: String, cost: Double, tokens: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Text("\(compactTokens(tokens)) tokens")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(currency(cost))
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func primaryDetailText() -> String {
        if let point = selectedPoint {
            return "\(shortDay(point.date)) · \(currency(point.costUSD))"
        }
        return "Last 30 days trend"
    }

    private func secondaryDetailText() -> String {
        if let point = selectedPoint {
            return "\(compactTokens(point.totalTokens)) tokens"
        }
        return "Hover bars for daily details"
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
