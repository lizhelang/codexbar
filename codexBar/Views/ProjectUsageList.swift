import Combine
import SwiftUI

/// Pagination is shared by production buttons and native interaction tests.
@MainActor
final class ProjectUsageNavigation: ObservableObject {
    static let projectsPerPage = 20
    static let sessionsPerPage = 10

    @Published var expandedProjectPaths: Set<String>
    @Published var projectPageIndex: Int
    @Published var sessionPageIndices: [String: Int]

    init(expandedProjectPaths: Set<String> = [], projectPageIndex: Int = 0,
         sessionPageIndices: [String: Int] = [:]) {
        self.expandedProjectPaths = expandedProjectPaths
        self.projectPageIndex = projectPageIndex
        self.sessionPageIndices = sessionPageIndices
    }

    func toggleProject(_ path: String) {
        if self.expandedProjectPaths.contains(path) {
            self.expandedProjectPaths.remove(path)
        } else {
            self.expandedProjectPaths.insert(path)
        }
    }

    func setProjectPage(_ page: Int, totalProjects: Int) {
        let resolved = Self.clampedPage(page, count: totalProjects, pageSize: Self.projectsPerPage)
        if self.projectPageIndex != resolved { self.projectPageIndex = resolved }
    }

    func moveProjectPage(by offset: Int, totalProjects: Int) {
        let page = Self.clampedPage(self.projectPageIndex, count: totalProjects, pageSize: Self.projectsPerPage)
        self.setProjectPage(page + offset, totalProjects: totalProjects)
    }

    func setSessionPage(_ page: Int, for path: String, totalSessions: Int) {
        let resolved = Self.clampedPage(page, count: totalSessions, pageSize: Self.sessionsPerPage)
        if self.sessionPageIndices[path, default: 0] != resolved {
            self.sessionPageIndices[path] = resolved
        }
    }

    func moveSessionPage(by offset: Int, for path: String, totalSessions: Int) {
        let page = Self.clampedPage(self.sessionPageIndices[path, default: 0], count: totalSessions, pageSize: Self.sessionsPerPage)
        self.setSessionPage(page + offset, for: path, totalSessions: totalSessions)
    }

    func reconcile(projectCount: Int, sessionCounts: [String: Int]) {
        self.setProjectPage(self.projectPageIndex, totalProjects: projectCount)
        let resolved = self.sessionPageIndices.reduce(into: [String: Int]()) { pages, item in
            guard let count = sessionCounts[item.key] else { return }
            pages[item.key] = Self.clampedPage(item.value, count: count, pageSize: Self.sessionsPerPage)
        }
        if resolved != self.sessionPageIndices { self.sessionPageIndices = resolved }
    }

    static func pageCount(count: Int, pageSize: Int) -> Int {
        max(1, (max(0, count - 1) / max(1, pageSize)) + 1)
    }

    static func clampedPage(_ page: Int, count: Int, pageSize: Int) -> Int {
        min(max(0, page), Self.pageCount(count: count, pageSize: pageSize) - 1)
    }
}

/// Only the current project page and each expanded project's current session page
/// enter the SwiftUI tree. Totals and tool breakdowns still use the full projection.
@MainActor
struct ProjectUsageList<Summary: View, Details: View, Session: View>: View {
    let projects: [MonitorRunningProject]
    let sessionsByProject: [String: [MonitorSessionSummary]]
    @ObservedObject var navigation: ProjectUsageNavigation
    private let summary: (MonitorRunningProject, Int) -> Summary
    private let details: (MonitorRunningProject) -> Details
    private let session: (MonitorSessionSummary, Int) -> Session

    init(projects: [MonitorRunningProject], sessionsByProject: [String: [MonitorSessionSummary]],
         navigation: ProjectUsageNavigation,
         @ViewBuilder summary: @escaping (MonitorRunningProject, Int) -> Summary,
         @ViewBuilder details: @escaping (MonitorRunningProject) -> Details,
         @ViewBuilder session: @escaping (MonitorSessionSummary, Int) -> Session) {
        self.projects = projects
        self.sessionsByProject = sessionsByProject
        self.navigation = navigation
        self.summary = summary
        self.details = details
        self.session = session
    }

    private var sessionCounts: [String: Int] { self.sessionsByProject.mapValues(\.count) }

    var body: some View {
        let pageSize = ProjectUsageNavigation.projectsPerPage
        let page = ProjectUsageNavigation.clampedPage(self.navigation.projectPageIndex, count: self.projects.count, pageSize: pageSize)
        let pageCount = ProjectUsageNavigation.pageCount(count: self.projects.count, pageSize: pageSize)
        let visible = Array(self.projects.dropFirst(page * pageSize).prefix(pageSize))
        let maximum = max(self.projects.lazy.map(\.totalTokens).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 7) {
            self.pager(count: self.projects.count, page: page, pageCount: pageCount,
                       title: L.zh ? "个项目" : "projects", identifier: "codexbar.projects",
                       previous: { self.navigation.moveProjectPage(by: -1, totalProjects: self.projects.count) },
                       next: { self.navigation.moveProjectPage(by: 1, totalProjects: self.projects.count) })
            ForEach(visible) { project in
                VStack(alignment: .leading, spacing: 7) {
                    Button { self.navigation.toggleProject(project.cwd) } label: {
                        self.summary(project, maximum).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("codexbar.project." + project.cwd)
                    if self.navigation.expandedProjectPaths.contains(project.cwd) {
                        self.details(project)
                        self.sessions(project)
                    }
                }
                .padding(.bottom, 9)
            }
        }
        .onAppear { self.reconcile() }
        .onChange(of: self.projects.count) { _ in self.reconcile() }
        .onChange(of: self.sessionCounts) { _ in self.reconcile() }
    }

    private func sessions(_ project: MonitorRunningProject) -> some View {
        let rows = self.sessionsByProject[project.cwd] ?? []
        let pageSize = ProjectUsageNavigation.sessionsPerPage
        let page = ProjectUsageNavigation.clampedPage(self.navigation.sessionPageIndices[project.cwd, default: 0], count: rows.count, pageSize: pageSize)
        let pageCount = ProjectUsageNavigation.pageCount(count: rows.count, pageSize: pageSize)
        let visible = Array(rows.dropFirst(page * pageSize).prefix(pageSize))
        let maximum = max(rows.lazy.map(\.totalTokens).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 7) {
            self.pager(count: rows.count, page: page, pageCount: pageCount,
                       title: L.zh ? "个会话" : "sessions", identifier: "codexbar.project." + project.cwd + ".sessions",
                       previous: { self.navigation.moveSessionPage(by: -1, for: project.cwd, totalSessions: rows.count) },
                       next: { self.navigation.moveSessionPage(by: 1, for: project.cwd, totalSessions: rows.count) })
            ForEach(visible) { row in
                self.session(row, maximum)
                    .accessibilityIdentifier("codexbar.project-session." + row.id)
            }
        }
    }

    private func pager(count: Int, page: Int, pageCount: Int, title: String, identifier: String,
                       previous: @escaping () -> Void, next: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Text("\(count) \(title)")
            Spacer(minLength: 4)
            if pageCount > 1 {
                Button(action: previous) { Image(systemName: "chevron.left") }
                    .disabled(page == 0)
                    .accessibilityLabel(L.zh ? "上一页" : "Previous page")
                    .accessibilityIdentifier(identifier + ".previous")
                Text("\(page + 1) / \(pageCount)").monospacedDigit()
                Button(action: next) { Image(systemName: "chevron.right") }
                    .disabled(page + 1 >= pageCount)
                    .accessibilityLabel(L.zh ? "下一页" : "Next page")
                    .accessibilityIdentifier(identifier + ".next")
            }
        }
        .buttonStyle(.borderless)
        .font(MenuSurface.font(size: 9, design: .monospaced))
        .foregroundStyle(MenuSurface.muted)
        .padding(.vertical, 4)
    }

    private func reconcile() {
        self.navigation.reconcile(projectCount: self.projects.count, sessionCounts: self.sessionCounts)
    }
}
