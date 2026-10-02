import AppKit
import Charts
import Combine
import SwiftUI

@MainActor
final class UsageDashboardWindow: NSObject, NSWindowDelegate {
    static let shared = UsageDashboardWindow()
    private var window: NSWindow?
    private let model = UsageDashboardWindowModel()

    func show(
        codex: LocalCostSummary,
        tools: [ToolUsageClient: ToolUsageSnapshot],
        period: UsagePeriod = .last30Days,
        scope: UsageScope = .all,
        refresh: @escaping @MainActor () -> Void
    ) {
        self.model.start(codex: codex, tools: tools, period: period, scope: scope, refresh: refresh)
        if self.window == nil {
            let controller = NSHostingController(rootView: UsageDashboardView(model: self.model))
            let window = NSWindow(contentViewController: controller)
            window.identifier = NSUserInterfaceItemIdentifier("codexbar.usage-dashboard")
            window.title = L.zh ? "Codexbar · 用量仪表盘" : "Codexbar · Usage Dashboard"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 820, height: 620)
            window.setContentSize(NSSize(width: 1100, height: 780))
            window.level = .normal
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("codexbar.usage-dashboard.frame")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        self.window?.makeKeyAndOrderFront(nil)
        if let window { MenuBarStatusItemController.clearInitialKeyboardFocus(in: window) }
    }

    func windowWillClose(_ notification: Notification) { self.model.stop() }
}

@MainActor
final class UsageDashboardWindowModel: ObservableObject {
    enum Page: String, CaseIterable { case overview, trends }
    @Published var page: Page = .overview
    @Published var period: UsagePeriod = .last30Days { didSet { if oldValue != self.period { self.requestProjection() } } }
    @Published var scope: UsageScope = .all { didSet { if oldValue != self.scope { self.requestProjection() } } }
    @Published var metric: UsageMetric = .tokens
    @Published var year = Calendar.current.component(.year, from: Date()) { didSet { if oldValue != self.year { self.requestProjection() } } }
    @Published private(set) var projection: UsageDashboardProjection?
    @Published private(set) var isProjecting = false
    private var codex: LocalCostSummary = .empty
    private var tools: [ToolUsageClient: ToolUsageSnapshot] = [:]
    private var refreshAction: (@MainActor () -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private let worker = UsageDashboardProjectionWorker()
    private var isOpen = false
    private var revision = 0

    var currentProjection: UsageDashboardProjection? {
        // Keep a complete snapshot on screen while the next selection is projected.
        self.projection
    }

    init(previewProjection: UsageDashboardProjection? = nil, period: UsagePeriod = .last30Days, year: Int = Calendar.current.component(.year, from: Date())) {
        self.projection = previewProjection
        self.period = period
        self.year = year
    }

    func start(codex: LocalCostSummary, tools: [ToolUsageClient: ToolUsageSnapshot], period: UsagePeriod, scope: UsageScope, refresh: @escaping @MainActor () -> Void) {
        self.stop()
        self.codex = codex
        self.tools = tools
        self.period = period
        self.scope = scope
        self.refreshAction = refresh
        self.metric = ApplicationPreferencesStore.shared.preferences.defaultUsageMetric == "cost" ? .cost : .tokens
        self.isOpen = true
        TokenStore.shared.$localCostSummary.dropFirst().removeDuplicates().sink { [weak self] summary in
            self?.codex = summary
            self?.requestProjection()
        }.store(in: &self.subscriptions)
        ToolUsageStore.shared.$snapshots.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isOpen else { return }
                self.tools = ToolUsageStore.shared.displaySnapshots
                self.requestProjection()
            }
        }.store(in: &self.subscriptions)
        ApplicationPreferencesStore.shared.$preferences.map(\.disabledTools).removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                self.codex = TokenStore.shared.localCostSummary
                self.tools = ToolUsageStore.shared.displaySnapshots
                self.requestProjection()
            }
        }.store(in: &self.subscriptions)
        self.requestProjection()
    }

    func stop() {
        self.isOpen = false
        self.task?.cancel()
        self.task = nil
        self.subscriptions.removeAll()
        self.isProjecting = false
    }

    func refresh() {
        self.refreshAction?()
        self.requestProjection()
    }

    private func requestProjection() {
        guard self.isOpen else { return }
        self.task?.cancel()
        self.revision += 1
        let revision = self.revision
        let enabled = ApplicationPreferencesStore.shared.preferences.enabledTools
        if self.scope != .all, !enabled.contains(self.scope.id) {
            self.scope = .all
            return
        }
        let codex = enabled.contains("codex") ? self.codex : .empty
        let tools = self.tools.filter { enabled.contains($0.key.rawValue) }
        let indexURL = enabled.contains("codex") ? SessionLogStore.shared.costUsageIndexURL : nil
        let pricing = TokenStore.shared.config.modelPricing
        let period = self.period
        let scope = self.scope
        let year = self.year
        self.isProjecting = true
        self.task = Task {
            do {
                // A collector may publish several sources in one turn. Only the latest selection is projected.
                try await Task.sleep(for: .milliseconds(120))
                let projection = try await self.worker.project(codex: codex, tools: tools, indexURL: indexURL,
                                                               pricing: pricing, period: period, scope: scope, year: year, now: Date())
                guard !Task.isCancelled, self.isOpen, self.revision == revision else { return }
                self.projection = projection
                self.isProjecting = false
            } catch {
                if self.revision == revision { self.isProjecting = false }
            }
        }
    }
}

@MainActor
private struct UsageDashboardView: View {
    @ObservedObject var model: UsageDashboardWindowModel
    @ObservedObject var preferences: ApplicationPreferencesStore = .shared
    @State private var showsAllModels = false
    @State private var showsAllTools = false

    private var colorScheme: ColorScheme? {
        switch self.preferences.preferences.theme { case .dark: .dark; case .light: .light; case .system: nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider().overlay(MenuSurface.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let projection = self.model.currentProjection {
                        self.statistics(projection)
                        if self.model.page == .trends { self.trends(projection) }
                        self.activity(projection)
                        self.rankings(projection)
                        HStack(alignment: .top) {
                            Text(L.zh ? "费用为估算或工具报告；≥ 表示已知费用下限。" : "Costs are estimated or reported; ≥ marks a known lower bound.")
                            Spacer(minLength: 8)
                            Text(projection.scope.title + " · " + projection.period.title)
                            Text(projection.projectedAt, style: .time)
                        }
                        .font(MenuSurface.font(size: 9)).foregroundStyle(MenuSurface.muted)
                    } else {
                        ProgressView(L.zh ? "正在读取已缓存的统计…" : "Loading cached statistics…")
                            .frame(maxWidth: .infinity, minHeight: 350)
                    }
                }
                .padding(18)
                .frame(maxWidth: 1600)
                .frame(maxWidth: .infinity)
            }
        }
        .background(MenuSurface.backgroundBottom)
        .preferredColorScheme(self.colorScheme)
        .foregroundStyle(MenuSurface.foreground)
        .tint(MenuSurface.accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                .accessibilityLabel("Codexbar")
            Text(L.zh ? "用量仪表盘" : "Usage Dashboard")
                .font(MenuSurface.font(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Picker("View", selection: self.$model.page) {
                Text(L.zh ? "总览" : "Overview").tag(UsageDashboardWindowModel.Page.overview)
                Text(L.zh ? "趋势" : "Trends").tag(UsageDashboardWindowModel.Page.trends)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 116)
            RouteSelectionMenu(
                title: self.model.scope.title,
                accessibilityLabel: L.zh ? "仪表盘工具" : "Dashboard tool",
                items: UsageScope.allCases.filter { $0 == .all || self.preferences.preferences.enabledTools.contains($0.id) }.map { scope in
                    RouteSelectionMenuItem(id: scope.id, title: scope.title, isSelected: scope == self.model.scope) { self.model.scope = scope }
                }, fontSize: 12
            ).frame(width: 138)
            RouteSelectionMenu(
                title: self.model.period.title,
                accessibilityLabel: L.zh ? "仪表盘时间范围" : "Dashboard date range",
                items: UsagePeriod.allCases.map { period in
                    RouteSelectionMenuItem(id: period.rawValue, title: period.title, isSelected: period == self.model.period) { self.model.period = period }
                }, fontSize: 12
            ).frame(width: 108)
            Picker("Metric", selection: self.$model.metric) {
                Text("Tokens").tag(UsageMetric.tokens)
                Text(L.zh ? "费用" : "Cost").tag(UsageMetric.cost)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 112)
            Button(action: self.model.refresh) {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(self.model.isProjecting ? 0 : 1)
                    if self.model.isProjecting { ProgressView().controlSize(.small) }
                }.frame(width: 24, height: 24)
            }.buttonStyle(.plain).disabled(self.model.isProjecting)
                .help(L.zh ? "刷新" : "Refresh")
                .accessibilityLabel(L.zh ? "刷新仪表盘" : "Refresh dashboard")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    private func statistics(_ projection: UsageDashboardProjection) -> some View {
        let mostUsed = projection.models.max { $0.totalTokens < $1.totalTokens }
        let commonModel = mostUsed.map { self.preferences.preferences.modelAliases[$0.modelID] ?? $0.modelID } ?? "—"
        return HStack(spacing: 0) {
            self.statistic(L.zh ? "总 TOKENS" : "Total tokens", value: self.compact(projection.aggregate.tokens))
            Divider()
            self.statistic(L.zh ? "费用估算" : "Estimated cost", value: self.cost(projection.aggregate.knownCostUSD, complete: projection.aggregate.costIsComplete))
            Divider()
            self.statistic(L.zh ? "活跃天数" : "Active days", value: "\(projection.activeDayCount)")
            Divider()
            self.statistic(L.zh ? "最长连续" : "Longest streak", value: "\(projection.longestStreakDays)")
            Divider()
            self.statistic(L.zh ? "日均 TOKENS" : "Tokens / active day", value: self.compact(projection.activeDayCount > 0 ? projection.aggregate.tokens / projection.activeDayCount : 0))
            Divider()
            self.statistic(L.zh ? "单日峰值" : "Peak day", value: self.compact(projection.peakDay?.tokens ?? 0))
            Divider()
            self.statistic(L.zh ? "常用模型" : "Top model", value: commonModel, isModel: true)
        }
        .frame(height: 78)
        .background(MenuSurface.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(MenuSurface.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codexbar.dashboard.statistics")
    }

    private func statistic(_ title: String, value: String, isModel: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(MenuSurface.font(size: isModel ? 16 : 22, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6).help(value)
            Text(title).font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.muted).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activity(_ projection: UsageDashboardProjection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L.zh ? "Token 活动" : "Token activity").font(MenuSurface.font(size: 13, weight: .semibold))
                Text(L.zh ? "\(projection.annualActiveDays) 个活跃日" : "\(projection.annualActiveDays) active days")
                    .font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.muted)
                Spacer()
                // The picker reflects the requested year; the heatmap stays labeled with its rendered year.
                if projection.year != self.model.year {
                    Text(String(projection.year)).font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.muted)
                }
                RouteSelectionMenu(
                    title: String(self.model.year), accessibilityLabel: L.zh ? "活动年份" : "Activity year",
                    items: projection.availableYears.map { year in
                        RouteSelectionMenuItem(id: String(year), title: String(year), isSelected: year == self.model.year) { self.model.year = year }
                    }, fontSize: 12
                ).frame(width: 80)
            }
            UsageDashboardAnnualGrid(weeks: projection.annualWeeks, metric: self.model.metric)
                .aspectRatio(CGFloat(max(1, projection.annualWeeks.count)) / 10, contentMode: .fit)
        }
    }

    private func trends(_ projection: UsageDashboardProjection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L.zh ? "每日用量" : "Daily usage").font(MenuSurface.font(size: 13, weight: .semibold))
                Spacer()
                Text(projection.chartIsLastYearOnly ? (L.zh ? "近一年 · 总览覆盖全部记录" : "Past year · totals cover all records") : projection.period.title)
                    .font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.muted)
            }
            UsageDashboardLargeChart(entries: projection.chartEntries, metric: self.model.metric)
                .frame(height: 250)
        }
    }

    private func rankings(_ projection: UsageDashboardProjection) -> some View {
        HStack(alignment: .top, spacing: 32) {
            self.rankingColumn(title: L.zh ? "按模型" : "By model") {
                let models = projection.models.sorted { self.model.metric == .tokens ? $0.totalTokens > $1.totalTokens : $0.estimatedCostUSD > $1.estimatedCostUSD }
                if models.isEmpty { self.emptyRankings(projection.modelsAvailable ? (L.zh ? "此范围暂无模型用量" : "No model usage in this period") : (L.zh ? "模型索引暂不可用" : "Model index unavailable")) }
                ForEach(Array(models.prefix(self.showsAllModels ? models.count : 5))) { row in
                    self.rankRow(title: self.preferences.preferences.modelAliases[row.modelID] ?? row.modelID,
                                 detail: row.sourceIDs.map(self.toolName).joined(separator: " · "),
                                 value: self.model.metric == .tokens ? self.compact(row.totalTokens) : self.cost(row.estimatedCostUSD, complete: row.costIsComplete),
                                 fraction: self.fraction(tokens: row.totalTokens, cost: row.estimatedCostUSD, aggregate: projection.aggregate))
                }
                if models.count > 5 {
                    Button(self.showsAllModels ? (L.zh ? "收起" : "Show less") : (L.zh ? "显示全部 \(models.count) 个模型" : "Show all \(models.count) models")) {
                        self.showsAllModels.toggle()
                    }.buttonStyle(.plain).font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.accent)
                }
            }
            self.rankingColumn(title: L.zh ? "按工具" : "By tool") {
                let tools = projection.tools.sorted { self.model.metric == .tokens ? $0.usage.tokens > $1.usage.tokens : $0.usage.knownCostUSD > $1.usage.knownCostUSD }
                if tools.isEmpty { self.emptyRankings(L.zh ? "此范围暂无工具用量" : "No tool usage in this period") }
                ForEach(Array(tools.prefix(self.showsAllTools ? tools.count : 5))) { row in
                    self.rankRow(title: row.scope.title,
                                 detail: self.cost(row.usage.knownCostUSD, complete: row.usage.costIsComplete),
                                 value: self.model.metric == .tokens ? self.compact(row.usage.tokens) : self.cost(row.usage.knownCostUSD, complete: row.usage.costIsComplete),
                                 fraction: self.fraction(tokens: row.usage.tokens, cost: row.usage.knownCostUSD, aggregate: projection.aggregate))
                }
                if tools.count > 5 {
                    Button(self.showsAllTools ? (L.zh ? "收起" : "Show less") : (L.zh ? "显示全部 \(tools.count) 个工具" : "Show all \(tools.count) tools")) {
                        self.showsAllTools.toggle()
                    }.buttonStyle(.plain).font(MenuSurface.font(size: 10)).foregroundStyle(MenuSurface.accent)
                }
            }
        }
    }

    private func rankingColumn<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(MenuSurface.font(size: 13, weight: .semibold)).foregroundStyle(MenuSurface.muted)
            content()
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rankRow(title: String, detail: String, value: String, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Text(title).font(MenuSurface.font(size: 11, weight: .medium)).lineLimit(1)
                .frame(width: 114, alignment: .leading).help(title + " · " + detail)
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.07))
                    .overlay(alignment: .leading) { Capsule().fill(MenuSurface.accent).frame(width: geometry.size.width * fraction) }
            }.frame(height: 4)
            Text(value).font(MenuSurface.font(size: 11, design: .monospaced)).lineLimit(1)
                .minimumScaleFactor(0.7).frame(width: 62, alignment: .trailing)
            Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                .font(MenuSurface.font(size: 10, design: .monospaced)).foregroundStyle(MenuSurface.muted)
                .frame(width: 43, alignment: .trailing)
        }.frame(height: 20)
    }

    private func emptyRankings(_ text: String) -> some View { Text(text).font(MenuSurface.font(size: 12)).foregroundStyle(.secondary).padding(.vertical, 25) }
    private func compact(_ value: Int) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) }
    private func cost(_ value: Double, complete: Bool) -> String { !complete && value == 0 ? (L.zh ? "费用未知" : "Unknown") : (complete ? "" : "≥") + MenuSurface.currency(value) }
    private func toolName(_ id: String) -> String { id == "codex" ? "Codex" : ToolUsageClient(rawValue: id)?.displayName ?? id }
    private func fraction(tokens: Int, cost: Double, aggregate: UsageAggregate) -> Double {
        let total = self.model.metric == .tokens ? Double(aggregate.tokens) : aggregate.knownCostUSD
        let amount = self.model.metric == .tokens ? Double(tokens) : cost
        return total > 0 ? min(1, max(0, amount / total)) : 0
    }
}

@MainActor
private struct UsageDashboardAnnualGrid: View {
    let weeks: [[UsageDashboardHeatmapDay]]
    let metric: UsageMetric
    @State private var hovered: UsageDashboardHeatmapDay?

    var body: some View {
        let maximum = max(self.weeks.flatMap { $0 }.filter(\.isInYear).map { self.value($0.usage) }.max() ?? 0, 1)
        GeometryReader { geometry in
            let size = max(3, (geometry.size.width - 23 - CGFloat(max(0, self.weeks.count - 1)) * 3) / CGFloat(max(1, self.weeks.count)))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 3) {
                    VStack(spacing: 3) {
                        Color.clear.frame(height: 15)
                        ForEach(0..<7) { weekday in
                            Text(weekday == 0 ? (L.zh ? "一" : "M") : weekday == 2 ? (L.zh ? "三" : "W") : weekday == 4 ? (L.zh ? "五" : "F") : "")
                                .font(MenuSurface.font(size: 8)).foregroundStyle(.secondary).frame(width: 20, height: size)
                        }
                    }
                    ForEach(self.weeks.indices, id: \.self) { index in
                        VStack(spacing: 3) {
                            Color.clear.frame(width: size, height: 15)
                                .overlay(alignment: .leading) {
                                    Text(self.monthLabel(self.weeks[index])).font(MenuSurface.font(size: 8))
                                        .foregroundStyle(.secondary).fixedSize()
                                }
                            ForEach(self.weeks[index]) { day in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(self.heatColor(self.value(day.usage), maximum: maximum))
                                    .frame(width: size, height: size)
                                    .opacity(day.isInYear ? 1 : 0)
                                    .onHover { inside in self.hovered = inside && day.isInYear ? day : nil }
                                    .help(self.dayDescription(day))
                            }
                        }
                    }
                }
                HStack(spacing: 4) {
                    Text(self.hovered.map(self.dayDescription) ?? " ").lineLimit(1)
                    Spacer(minLength: 8)
                    Text(L.zh ? "少" : "Less")
                    ForEach(0..<5) { index in
                        RoundedRectangle(cornerRadius: 2).fill(self.heatColors[index]).frame(width: 9, height: 9)
                    }
                    Text(L.zh ? "多" : "More")
                }.font(MenuSurface.font(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private var heatColors: [Color] {
        [Color(red: 0.224, green: 0.243, blue: 0.255),
         Color(red: 0.231, green: 0.306, blue: 0.376),
         Color(red: 0.286, green: 0.420, blue: 0.537),
         Color(red: 0.380, green: 0.573, blue: 0.710),
         Color(red: 0.651, green: 0.867, blue: 0.961)]
    }
    private func heatColor(_ amount: Double, maximum: Double) -> Color {
        guard amount > 0 else { return self.heatColors[0] }
        let index = min(4, max(1, Int(ceil(sqrt(min(1, amount / maximum)) * 4))))
        return self.heatColors[index]
    }

    private func value(_ entry: UsageChartEntry) -> Double { self.metric == .tokens ? Double(entry.tokens) : entry.knownCostUSD }
    private func dayDescription(_ day: UsageDashboardHeatmapDay) -> String {
        let amount = self.metric == .tokens ? "\(day.usage.tokens.formatted()) tokens"
            : !day.usage.costIsComplete && day.usage.knownCostUSD == 0 ? (L.zh ? "费用未知" : "Cost unknown")
            : (day.usage.costIsComplete ? "" : "≥") + MenuSurface.currency(day.usage.knownCostUSD)
        return day.date.formatted(date: .abbreviated, time: .omitted) + " · " + amount
    }
    private func monthLabel(_ days: [UsageDashboardHeatmapDay]) -> String {
        guard let day = days.first(where: { $0.isInYear && Calendar.current.component(.day, from: $0.date) == 1 }) else { return " " }
        return day.date.formatted(.dateTime.month(.abbreviated))
    }
}

@MainActor
private struct UsageDashboardLargeChart: View {
    let entries: [UsageChartEntry]
    let metric: UsageMetric
    @State private var hoveredDate: Date?

    var body: some View {
        let hovered = self.hoveredDate.flatMap { date in self.entries.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        VStack(spacing: 12) {
            Chart {
                ForEach(self.entries) { entry in
                    AreaMark(x: .value("Date", entry.date), y: .value("Usage", self.value(entry)))
                        .interpolationMethod(.monotone).foregroundStyle(LinearGradient(colors: [MenuSurface.accent.opacity(0.25), MenuSurface.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", entry.date), y: .value("Usage", self.value(entry)))
                        .interpolationMethod(.monotone).foregroundStyle(MenuSurface.accent).lineStyle(StrokeStyle(lineWidth: 2))
                    if self.entries.count == 1 { PointMark(x: .value("Date", entry.date), y: .value("Usage", self.value(entry))).foregroundStyle(MenuSurface.accent) }
                }
                if let hovered { RuleMark(x: .value("Date", hovered.date)).foregroundStyle(MenuSurface.accent.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4])) }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(amount.formatted(.number.notation(.compactName))) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: self.axisDates) {
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let point): self.hoveredDate = proxy.value(atX: point.x - geometry[proxy.plotAreaFrame].origin.x, as: Date.self)
                        case .ended: self.hoveredDate = nil
                        }
                    }
                }
            }
            HStack {
                if let hovered {
                    Text(hovered.date.formatted(date: .abbreviated, time: .omitted))
                    Spacer()
                    Text(self.metric == .tokens ? "\(hovered.tokens.formatted()) tokens" : (hovered.costIsComplete ? "" : "≥") + MenuSurface.currency(hovered.knownCostUSD))
                } else { Text(L.zh ? "移动鼠标查看每日用量" : "Hover to inspect daily usage"); Spacer() }
            }.font(MenuSurface.font(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(height: 17)
        }
    }
    private func value(_ entry: UsageChartEntry) -> Double {
        let preferences = ApplicationPreferencesStore.shared.preferences
        let rate = preferences.displayCurrencyCode == "USD" ? 1 : preferences.usdExchangeRate
        return self.metric == .tokens ? Double(entry.tokens) : entry.knownCostUSD * rate
    }

    private var axisDates: [Date] {
        guard let last = self.entries.last?.date else { return [] }
        let step = max(1, Int(ceil(Double(self.entries.count - 1) / 5)))
        var dates = self.entries.enumerated().compactMap { index, entry in index.isMultiple(of: step) ? entry.date : nil }
        if dates.last != last { dates.append(last) }
        return dates
    }
}

#if DEBUG
/// Renders a synthetic projection only; it never opens a user window or starts collectors.
@MainActor
enum UsageDashboardPreviewRenderer {
    static func png(projection: UsageDashboardProjection, period: UsagePeriod, year: Int, trends: Bool = false, size: CGSize = CGSize(width: 1100, height: 1000), preferences: ApplicationPreferencesStore = .shared) -> Data? {
        let model = UsageDashboardWindowModel(previewProjection: projection, period: period, year: year)
        model.page = trends ? .trends : .overview
        let host = NSHostingView(rootView: UsageDashboardView(model: model, preferences: preferences))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
