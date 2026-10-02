import AppKit
import SwiftUI
import XCTest
@testable import codexbar

@MainActor
final class ProjectUsageListTests: XCTestCase {
    func testLargeProjectNativeLayoutBuildsOnlyCurrentPages() throws {
        let fixture = Self.fixture()
        let navigation = ProjectUsageNavigation()
        let probe = ProjectUsageConstructionProbe()
        let root = AdaptiveMenuScrollContainer(maxHeight: 640) {
            ProjectUsageList(projects: fixture.projects, sessionsByProject: fixture.sessions,
                             navigation: navigation) { project, maximum in
                probe.summary(project, maximum: maximum)
            } details: { project in
                probe.details(project)
            } session: { session, maximum in
                probe.session(session, maximum: maximum)
            }
            .padding(.horizontal, 14)
        }.frame(width: 360, height: 640)
        let initialRenderStarted = ProcessInfo.processInfo.systemUptime
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        func render(_ name: String, includingInitialConstruction: Bool = false, action: () -> Void = {}) {
            if !includingInitialConstruction { probe.reset() }
            let start = includingInitialConstruction ? initialRenderStarted : ProcessInfo.processInfo.systemUptime
            action()
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 640)
            host.layoutSubtreeIfNeeded()
            // Execute the actual published-state update and native layout, not just a value projection.
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            print("ProjectUsageList native \(name): \(String(format: "%.3f", elapsed))s, project builds=\(probe.projectBuilds), session builds=\(probe.sessionBuilds)")
            XCTAssertLessThan(elapsed, 2, "Large-project native interaction stalled: \(name)")
            XCTAssertLessThanOrEqual(probe.projectIDs.count, 20)
            XCTAssertLessThanOrEqual(probe.sessionIDs.count, 10)
            // SwiftUI may ask for a row several times during layout. Even allowing repeated
            // evaluation, a single interaction must never construct thousands of hidden rows.
            XCTAssertLessThanOrEqual(probe.projectBuilds, 200)
            XCTAssertLessThanOrEqual(probe.sessionBuilds, 100)
            XCTAssertEqual(host.fittingSize.height, 640, accuracy: 1)
            XCTAssertEqual(window.contentView?.bounds.height ?? 0, 640, accuracy: 1)
        }

        render("collapsed", includingInitialConstruction: true)
        XCTAssertEqual(probe.projectIDs.count, 20)
        XCTAssertTrue(probe.sessionIDs.isEmpty)
        render("expand 4,000 sessions") { navigation.toggleProject(fixture.largePath) }
        XCTAssertEqual(probe.sessionIDs, Self.largeSessionIDs(0..<10))
        XCTAssertEqual(probe.detailSessionTotals.last, 4000)
        XCTAssertEqual(probe.detailTokenTotals.last, 400_000)

        render("next session page") {
            navigation.moveSessionPage(by: 1, for: fixture.largePath, totalSessions: 4000)
        }
        XCTAssertEqual(probe.sessionIDs, Self.largeSessionIDs(10..<20))
        render("last session page") {
            navigation.setSessionPage(Int.max, for: fixture.largePath, totalSessions: 4000)
        }
        XCTAssertEqual(navigation.sessionPageIndices[fixture.largePath], 399)
        XCTAssertEqual(probe.sessionIDs, Self.largeSessionIDs(3990..<4000))
        XCTAssertEqual(probe.detailSessionTotals.last, 4000)
        XCTAssertEqual(probe.detailTokenTotals.last, 400_000)

        render("next project page") { navigation.moveProjectPage(by: 1, totalProjects: fixture.projects.count) }
        XCTAssertTrue(probe.sessionIDs.isEmpty, "The expanded project is outside the current page")
        render("last project page") { navigation.setProjectPage(Int.max, totalProjects: fixture.projects.count) }
        XCTAssertEqual(navigation.projectPageIndex, 20)
        XCTAssertEqual(probe.projectIDs, Set(["/fixture/project-399"]))
        render("return to large project") { navigation.setProjectPage(0, totalProjects: fixture.projects.count) }
        XCTAssertEqual(probe.sessionIDs.count, 10)
        render("collapse large project") { navigation.toggleProject(fixture.largePath) }
        XCTAssertTrue(probe.sessionIDs.isEmpty)
        XCTAssertFalse(window.isVisible)
    }

    func testNavigationClampsAfterRangeChangesAndKeepsMultipleProjectsExpanded() {
        let navigation = ProjectUsageNavigation(expandedProjectPaths: ["a", "b"], projectPageIndex: 20,
                                                sessionPageIndices: ["a": 399, "b": 2, "removed": 10])
        navigation.reconcile(projectCount: 2, sessionCounts: ["a": 11, "b": 0])
        XCTAssertEqual(navigation.projectPageIndex, 0)
        XCTAssertEqual(navigation.sessionPageIndices, ["a": 1, "b": 0])
        XCTAssertEqual(navigation.expandedProjectPaths, ["a", "b"])
        navigation.moveSessionPage(by: 1, for: "a", totalSessions: 11)
        XCTAssertEqual(navigation.sessionPageIndices["a"], 1)
        navigation.moveSessionPage(by: -1, for: "a", totalSessions: 11)
        XCTAssertEqual(navigation.sessionPageIndices["a"], 0)
        navigation.toggleProject("a")
        XCTAssertEqual(navigation.expandedProjectPaths, ["b"])
        navigation.setProjectPage(Int.max, totalProjects: 0)
        XCTAssertEqual(navigation.projectPageIndex, 0)
    }

    private static let sources = ["codex", "claudeCode", "openCode", "cursor", "deepSeekHarness"]

    private static func largeSessionIDs(_ range: Range<Int>) -> Set<String> {
        Set(range.map { "\(Self.sources[$0 % Self.sources.count])|large-\($0)" })
    }

    private static func fixture() -> (projects: [MonitorRunningProject], sessions: [String: [MonitorSessionSummary]], largePath: String) {
        let now = Date(timeIntervalSince1970: 1_790_812_800)
        let largePath = "/fixture/长期维护的大型项目"
        var sessions: [String: [MonitorSessionSummary]] = [:]
        func rows(_ count: Int, path: String, prefix: String) -> [MonitorSessionSummary] {
            (0..<count).map { index in
                MonitorSessionSummary(sourceID: Self.sources[index % Self.sources.count], sessionID: "\(prefix)-\(index)",
                    title: "第 \(index + 1) 个真实布局会话：含模型、用量、上下文与较长的中文标题",
                    modelIDs: ["gpt-fixture"], projectPath: path, firstUsageAt: now,
                    lastActivityAt: now.addingTimeInterval(Double(-index)), totalTokens: 100,
                    knownCostUSD: 0.01, costIsComplete: true, isRunning: index % 31 == 0,
                    contextWindowTokens: 200_000, contextUsedTokens: 50_000)
            }
        }
        sessions[largePath] = rows(4000, path: largePath, prefix: "large")
        var paths = [largePath]
        for index in 0..<400 {
            let path = "/fixture/project-\(index)"
            paths.append(path)
            sessions[path] = rows(3, path: path, prefix: "project-\(index)")
        }
        let projects = paths.map { path in
            let rows = sessions[path]!
            let count = rows.count
            let tools = Dictionary(grouping: rows, by: \.sourceID).map { source, rows in
                MonitorProjectToolUsage(sourceID: source, totalTokens: rows.count * 100,
                    knownCostUSD: Double(rows.count) * 0.01, costIsComplete: true, sessionCount: rows.count)
            }.sorted { $0.sourceID < $1.sourceID }
            return MonitorRunningProject(cwd: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
                runningThreadCount: 1, lastRuntimeAt: now, totalTokens: count * 100,
                knownCostUSD: Double(count) * 0.01, costIsComplete: true, sessionCount: count,
                sourceIDs: tools.map(\.sourceID), toolBreakdown: tools)
        }
        return (projects, sessions, largePath)
    }
}

@MainActor
private final class ProjectUsageConstructionProbe {
    var projectIDs: Set<String> = []
    var sessionIDs: Set<String> = []
    var projectBuilds = 0
    var sessionBuilds = 0
    var detailSessionTotals: [Int] = []
    var detailTokenTotals: [Int] = []

    func reset() {
        self.projectIDs = []; self.sessionIDs = []
        self.projectBuilds = 0; self.sessionBuilds = 0
        self.detailSessionTotals = []; self.detailTokenTotals = []
    }

    func summary(_ project: MonitorRunningProject, maximum: Int) -> some View {
        self.projectIDs.insert(project.id)
        self.projectBuilds += 1
        return VStack(alignment: .leading, spacing: 5) {
            HStack { Label(project.displayName, systemImage: "folder"); Spacer(); Text(project.totalTokens.formatted()) }
            Text("\(project.sessionCount) 个会话 · 最大项目 \(maximum)").font(.caption)
            ProgressView(value: Double(project.totalTokens), total: Double(maximum))
        }.font(.system(size: 11)).padding(.vertical, 8)
    }

    func details(_ project: MonitorRunningProject) -> some View {
        self.detailSessionTotals.append(project.sessionCount)
        self.detailTokenTotals.append(project.totalTokens)
        return VStack(alignment: .leading, spacing: 5) {
            Text(project.cwd).lineLimit(2)
            ForEach(project.toolBreakdown) { tool in
                HStack { Text(tool.sourceID); Spacer(); Text("\(tool.totalTokens) tokens · \(tool.sessionCount) 会话") }
            }
        }.font(.system(size: 10)).padding(.vertical, 5)
    }

    func session(_ session: MonitorSessionSummary, maximum: Int) -> some View {
        self.sessionIDs.insert(session.id)
        self.sessionBuilds += 1
        return Button {} label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack { Image(systemName: "text.bubble"); Text(session.title).lineLimit(1); Spacer(); Text(session.totalTokens.formatted()) }
                HStack { Text(session.modelID); Spacer(); Text(session.isRunning == true ? "运行中" : "已结束") }
                Text("上下文剩余 75% · 单会话最大 \(maximum)").font(.caption)
            }.font(.system(size: 11)).padding(.vertical, 5)
        }.buttonStyle(.plain)
    }
}
