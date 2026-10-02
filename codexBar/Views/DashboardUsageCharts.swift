import Charts
import SwiftUI

enum DashboardTrendChartStyle: Equatable {
    case line
    case bar

    var toggleSymbol: String {
        self == .line ? "chart.bar.xaxis" : "chart.xyaxis.line"
    }
}

/// 首页历史独立于顶部的统计周期，避免“本月”在月初把全年活动图清空。
struct DashboardActivityView: View {
    let entries: [UsageChartEntry]
    let now: Date
    let metric: UsageMetric
    let accent: Color
    let muted: Color
    var showsTrendChart = true
    let showTrends: () -> Void

    private var calendar: Calendar { .current }
    private var today: Date { self.calendar.startOfDay(for: self.now) }
    private var firstDay: Date {
        let month = self.calendar.dateInterval(of: .month, for: self.now)?.start ?? self.today
        return self.calendar.date(byAdding: .month, value: -11, to: month) ?? month
    }
    private var weeks: [[Date]] {
        var calendar = self.calendar
        calendar.firstWeekday = 1
        let start = calendar.dateInterval(of: .weekOfYear, for: self.firstDay)?.start ?? self.firstDay
        let count = (calendar.dateComponents([.day], from: start, to: self.today).day ?? 0) / 7 + 1
        return (0..<count).map { week in
            (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: start) }
        }
    }

    var body: some View {
        let history = self.entries.filter { $0.date >= self.firstDay && $0.date <= self.today }
        let byDay = Dictionary(uniqueKeysWithValues: history.map { ($0.date, $0) })
        let maximum = max(history.map { self.value($0) }.max() ?? 0, 1)
        let weeks = self.weeks
        VStack(alignment: .leading, spacing: 9) {
            Button(action: self.showTrends) {
                HStack {
                    Text(L.zh ? "活动" : "ACTIVITY").fontWeight(.bold)
                    Spacer()
                    Text(L.zh ? "近 12 月 · \(history.filter { $0.tokens > 0 }.count) 个活跃日" : "12 months · \(history.filter { $0.tokens > 0 }.count) active days")
                        .font(MenuSurface.font(size: 9, design: .monospaced))
                        .foregroundStyle(self.muted)
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(self.muted)
                }
                .font(MenuSurface.font(size: 12, design: .monospaced))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(weeks.indices, id: \.self) { index in
                            VStack(spacing: 3) {
                                ForEach(weeks[index], id: \.self) { date in
                                    let entry = byDay[date]
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(self.cellColor(entry, maximum: maximum))
                                        .frame(width: 9, height: 9)
                                        .opacity(date < self.firstDay || date > self.today ? 0 : 1)
                                        .help(self.cellLabel(date, entry: entry))
                                }
                                Text(self.monthLabel(weeks[index]))
                                    .font(MenuSurface.font(size: 8, design: .monospaced))
                                    .foregroundStyle(self.muted)
                                    .fixedSize()
                                    .frame(width: 9, alignment: .leading)
                            }
                            .id(index)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { proxy.scrollTo(weeks.count - 1, anchor: .trailing) }
            }
            if self.showsTrendChart {
            HStack {
                Text(L.zh ? "趋势" : "TREND")
                Spacer()
                Text((L.zh ? "单日峰值 " : "Peak ") + self.peakLabel)
                    .foregroundStyle(self.muted)
            }
            .font(MenuSurface.font(size: 10, weight: .medium, design: .monospaced))
            DashboardTrendChart(
                entries: UsagePresentation.chartEntries(dailyEntries: self.entries, numberOfDays: 45, now: self.now, calendar: self.calendar),
                metric: self.metric, accent: self.accent, muted: self.muted, height: 70
            )
            }
        }
    }

    private func value(_ entry: UsageChartEntry) -> Double {
        self.metric == .tokens ? Double(entry.tokens) : entry.knownCostUSD
    }

    private func cellColor(_ entry: UsageChartEntry?, maximum: Double) -> Color {
        guard let entry, self.value(entry) > 0 else { return .primary.opacity(0.07) }
        let level = min(4, max(1, Int(ceil(self.value(entry) / maximum * 4))))
        return self.accent.opacity(0.18 + Double(level) * 0.2)
    }

    private func cellLabel(_ date: Date, entry: UsageChartEntry?) -> String {
        let amount = self.metric == .tokens
            ? "\((entry?.tokens ?? 0).formatted()) tokens"
            : self.costLabel(entry)
        return date.formatted(date: .abbreviated, time: .omitted) + " · " + amount
    }

    private var peakLabel: String {
        if self.metric == .tokens {
            return (self.entries.map(\.tokens).max() ?? 0).formatted(.number.notation(.compactName))
        }
        let peak = self.entries.map(\.knownCostUSD).max() ?? 0
        let complete = self.entries.allSatisfy(\.costIsComplete)
        if !complete && peak == 0 { return L.zh ? "费用未知" : "Cost unknown" }
        return (complete ? "" : "≥") + MenuSurface.currency(peak)
    }

    private func costLabel(_ entry: UsageChartEntry?) -> String {
        let value = entry?.knownCostUSD ?? 0
        if entry?.costIsComplete == false && value == 0 { return L.zh ? "费用未知" : "Cost unknown" }
        return (entry?.costIsComplete == false ? "≥" : "") + MenuSurface.currency(value)
    }

    private func monthLabel(_ dates: [Date]) -> String {
        guard let first = dates.first(where: { self.calendar.component(.day, from: $0) == 1 }) else { return " " }
        return first.formatted(.dateTime.month(.abbreviated))
    }
}

struct DashboardTrendChart: View {
    let entries: [UsageChartEntry]
    let metric: UsageMetric
    let accent: Color
    let muted: Color
    var height: CGFloat = 128
    var style: DashboardTrendChartStyle = .line
    @State private var hoveredDate: Date?
    @State private var hoveredBarIndex: Int?

    private var barEntries: [UsageChartEntry] {
        self.entries.filter { self.value($0) > 0 }
    }

    private var barReferenceDate: Date {
        Date(timeIntervalSince1970: 0)
    }

    private var xDomain: ClosedRange<Date> {
        if self.style == .bar {
            let count = max(self.barEntries.count, 1)
            let halfWidth = max(4.0, (Double(count - 1) / 2.0) + 1.5)
            return self.barReferenceDate.addingTimeInterval(-halfWidth * 86_400)...self.barReferenceDate.addingTimeInterval(halfWidth * 86_400)
        }
        guard let first = self.entries.first?.date, let last = self.entries.last?.date else {
            return self.barReferenceDate.addingTimeInterval(-86_400)...self.barReferenceDate.addingTimeInterval(86_400)
        }
        if first == last {
            return first.addingTimeInterval(-86_400)...last.addingTimeInterval(86_400)
        }
        return first...last
    }

    private func barDate(at index: Int) -> Date {
        let center = Double(max(self.barEntries.count - 1, 0)) / 2.0
        return self.barReferenceDate.addingTimeInterval((Double(index) - center) * 86_400)
    }

    private func value(_ entry: UsageChartEntry) -> Double {
        self.metric == .tokens ? Double(entry.tokens) : entry.knownCostUSD
    }

    var body: some View {
        let maximum = max(self.entries.map { self.value($0) }.max() ?? 0, 1)
        let hovered = self.hoveredDate.flatMap { date in
            self.entries.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        let hoveredBar = self.hoveredBarIndex.flatMap { index in
            self.barEntries.indices.contains(index) ? self.barEntries[index] : nil
        }
        VStack(spacing: 5) {
            Chart {
                if self.style == .bar {
                    ForEach(Array(self.barEntries.enumerated()), id: \.element.id) { index, entry in
                        BarMark(x: .value("Date", self.barDate(at: index)), y: .value("Usage", self.value(entry)))
                            .foregroundStyle(self.accent)
                            .cornerRadius(2)
                    }
                } else {
                    ForEach(self.entries) { entry in
                        AreaMark(x: .value("Date", entry.date), y: .value("Usage", self.value(entry)))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [self.accent.opacity(0.22), self.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", entry.date), y: .value("Usage", self.value(entry)))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(self.accent)
                        if self.entries.count == 1 {
                            PointMark(x: .value("Date", entry.date), y: .value("Usage", self.value(entry)))
                            .foregroundStyle(self.accent)
                        }
                    }
                }
                if self.style == .bar, hoveredBar != nil {
                    RuleMark(x: .value("Date", self.barDate(at: self.hoveredBarIndex ?? 0)))
                        .foregroundStyle(self.accent.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                } else if let hovered {
                    RuleMark(x: .value("Date", hovered.date))
                        .foregroundStyle(self.accent.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .chartXScale(domain: self.xDomain)
            .chartYScale(domain: 0...(maximum * 1.05))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                                if self.style == .bar {
                                    guard let date = proxy.value(atX: x, as: Date.self) else { return }
                                    let center = Double(max(self.barEntries.count - 1, 0)) / 2.0
                                    let index = Int(round(date.timeIntervalSince(self.barReferenceDate) / 86_400 + center))
                                    self.hoveredBarIndex = self.barEntries.indices.contains(index) ? index : nil
                                    self.hoveredDate = nil
                                } else {
                                    self.hoveredDate = proxy.value(atX: x, as: Date.self)
                                    self.hoveredBarIndex = nil
                                }
                            case .ended: self.hoveredDate = nil
                                self.hoveredBarIndex = nil
                            }
                        }
                }
            }
            .frame(height: self.height)
            HStack {
                if let hovered = self.style == .bar ? hoveredBar : hovered {
                    Text(hovered.date.formatted(.dateTime.month().day()))
                    Spacer()
                    Text(self.metric == .tokens ? "\(hovered.tokens.formatted()) tokens" : (hovered.costIsComplete ? "" : "≥") + MenuSurface.currency(hovered.knownCostUSD))
                } else if let first = self.entries.first, let last = self.entries.last {
                    Text(first.date.formatted(.dateTime.month().day()))
                    Spacer()
                    if self.entries.count > 2 {
                        Text(self.entries[self.entries.count / 2].date.formatted(.dateTime.month().day()))
                        Spacer()
                    }
                    if first.date != last.date { Text(last.date.formatted(.dateTime.month().day())) }
                }
            }
            .font(MenuSurface.font(size: 9, design: .monospaced))
            .foregroundStyle(self.muted)
            .frame(height: 13)
        }
    }
}
