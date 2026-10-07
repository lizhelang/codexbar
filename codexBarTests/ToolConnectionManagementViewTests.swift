import AppKit
import SwiftUI
import XCTest
@testable import codexbar

@MainActor
final class ToolConnectionManagementViewTests: XCTestCase {
    func testPauseStopsNewRequestsAndEnableResumesWithoutDiscardingHistory() async throws {
        let fixture = try self.makeFixture(enabled: [.openCode])
        defer { fixture.cleanUp() }
        let counter = ConnectionCollectorCounter()
        let quota = ConnectionFixtureQuotaFetcher()
        let tools = ToolUsageStore(
            collectors: [ConnectionFixtureCollector(client: .openCode, counter: counter)],
            cursorSyncer: ConnectionFixtureCursorSyncer(), quotaFetcher: quota,
            cacheURL: fixture.folder.appendingPathComponent("usage.json"), preferencesStore: fixture.preferences
        )
        let view = ToolConnectionManagementView(client: .openCode, preferencesStore: fixture.preferences, toolUsageStore: tools)
        view.refresh()
        try await self.waitUntil {
            tools.snapshot(for: .openCode).dailyEntries.first?.totalTokens == 37
                && !tools.isRefreshing && !tools.isRefreshingQuotas
        }
        let initialQuotaCalls = await quota.callCount
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(initialQuotaCalls, 1)

        view.setEnabled(false)
        try await self.waitUntil {
            tools.quotaSnapshots[.openCode] == nil && !tools.isRefreshing && !tools.isRefreshingQuotas
        }
        XCTAssertFalse(view.isEnabled)
        XCTAssertEqual(tools.snapshot(for: .openCode).dailyEntries.first?.totalTokens, 37)
        view.refresh()
        let pausedQuotaCalls = await quota.callCount
        XCTAssertEqual(counter.count, 1, "暂停的工具不得继续采集")
        XCTAssertEqual(pausedQuotaCalls, initialQuotaCalls, "暂停后的手动刷新不得触发额度请求")

        view.setEnabled(true)
        try await self.waitUntil {
            tools.quotaSnapshots[.openCode] != nil && counter.count == 2
                && !tools.isRefreshing && !tools.isRefreshingQuotas
        }
        XCTAssertTrue(view.isEnabled)
        let resumedQuotaCalls = await quota.callCount
        XCTAssertEqual(resumedQuotaCalls, initialQuotaCalls + 1)
    }

    func testChangingDirectoryReloadsRealLocalUsageAndPassesRootToQuotaReader() async throws {
        let fixture = try self.makeFixture(enabled: [])
        defer { fixture.cleanUp() }
        let first = fixture.folder.appendingPathComponent("first", isDirectory: true)
        let second = fixture.folder.appendingPathComponent("second", isDirectory: true)
        try self.writeClaudeUsage(tokens: 17, root: first)
        try self.writeClaudeUsage(tokens: 83, root: second)
        let quota = ConnectionFixtureQuotaFetcher()
        // Default collectors exercise the real custom-root wiring. Other clients stay disabled,
        // and all quota/session transports are fixtures, so this cannot contact real services.
        let tools = ToolUsageStore(
            cursorSyncer: ConnectionFixtureCursorSyncer(), quotaFetcher: quota,
            cacheURL: fixture.folder.appendingPathComponent("usage.json"), preferencesStore: fixture.preferences
        )
        let view = ToolConnectionManagementView(client: .claudeCode, preferencesStore: fixture.preferences, toolUsageStore: tools)
        XCTAssertNil(view.saveDataDirectory("  \(first.path)  "))
        view.setEnabled(true)
        try await self.waitUntil {
            tools.snapshot(for: .claudeCode).dailyEntries.first?.totalTokens == 17
                && !tools.isRefreshing && !tools.isRefreshingQuotas
        }
        let firstQuotaRoot = await quota.lastDirectories[.claudeCode]
        XCTAssertEqual(firstQuotaRoot, first.standardizedFileURL.path)

        XCTAssertNil(view.saveDataDirectory(second.path))
        try await self.waitUntil {
            tools.snapshot(for: .claudeCode).dailyEntries.first?.totalTokens == 83
                && !tools.isRefreshing && !tools.isRefreshingQuotas
        }
        let secondQuotaRoot = await quota.lastDirectories[.claudeCode]
        XCTAssertEqual(secondQuotaRoot, second.standardizedFileURL.path)
        XCTAssertEqual(fixture.preferences.preferences.dataDirectory(for: "claudeCode"), second.standardizedFileURL)

        let unchanged = fixture.preferences.preferences
        XCTAssertNotNil(view.saveDataDirectory("relative/source"))
        XCTAssertNotNil(view.saveDataDirectory("file://\(second.path)"))
        XCTAssertNotNil(view.saveDataDirectory(fixture.folder.appendingPathComponent("missing").path))
        XCTAssertNotNil(view.saveDataDirectory(second.appendingPathComponent("projects/fixture.jsonl").path))
        XCTAssertEqual(fixture.preferences.preferences, unchanged, "无效路径不得替换正在使用的采集目录")

        view.setEnabled(false)
        try await self.waitUntil { tools.quotaSnapshots[.claudeCode] == nil && !tools.isRefreshing && !tools.isRefreshingQuotas }
        XCTAssertNil(view.saveDataDirectory(" \n "))
        XCTAssertNil(fixture.preferences.preferences.dataDirectory(for: "claudeCode"))
        let restored = ApplicationPreferencesStore(defaults: fixture.defaults)
        XCTAssertNil(restored.preferences.dataDirectory(for: "claudeCode"))
        XCTAssertTrue(restored.preferences.disabledTools.contains("claudeCode"))
        try await self.waitUntil { !tools.isRefreshing && !tools.isRefreshingQuotas }
    }

    func testConnectionPanelsRenderInNativeWindowWithoutStartingRequests() throws {
        guard Bundle.main.bundleIdentifier != "lzhl.codexAppBar" else {
            throw XCTSkip("配置视图只在隔离的测试进程中渲染")
        }
        let fixture = try self.makeFixture(enabled: [])
        defer { fixture.cleanUp() }
        let tools = ToolUsageStore(
            collectors: [], cursorSyncer: ConnectionFixtureCursorSyncer(), quotaFetcher: ConnectionFixtureQuotaFetcher(),
            cacheURL: fixture.folder.appendingPathComponent("usage.json"), preferencesStore: fixture.preferences
        )
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-tool-connection-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for client in ToolUsageClient.allCases {
            let view = ToolConnectionManagementView(client: client, preferencesStore: fixture.preferences,
                                                    toolUsageStore: tools, importCursorCSV: {})
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 760),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.frame = NSRect(x: 0, y: 0, width: 540, height: 760)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1_000)
            try png.write(to: output.appendingPathComponent(client.rawValue + ".png"))
            let elements = self.accessibilityElements(window)
            let prefix = "codexbar.tool-connection.\(client.rawValue)."
            let controls = elements.filter { ($0.accessibilityIdentifier() ?? "").hasPrefix(prefix) }
            if controls.isEmpty {
                try "隔离进程不公开 SwiftUI 控件树；已保存原生布局，目录及暂停操作由 fixture 验证。\n".write(
                    to: output.appendingPathComponent(client.rawValue + "-ax-limitation.txt"), atomically: true, encoding: .utf8)
            }
            for element in controls {
                let frame = element.accessibilityFrame()
                XCTAssertLessThanOrEqual(frame.width, 540, element.accessibilityIdentifier() ?? "")
                if element.accessibilityIdentifier() == prefix + "refresh" {
                    XCTAssertFalse(element.isAccessibilityEnabled(), "暂停状态的刷新按钮必须禁用")
                }
            }
            let labels = elements.flatMap { [$0.accessibilityLabel(), $0.accessibilityValue() as? String].compactMap { $0 } }
            try labels.joined(separator: "\n").write(to: output.appendingPathComponent(client.rawValue + "-labels.txt"),
                                                     atomically: true, encoding: .utf8)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(tools.isRefreshing)
            XCTAssertFalse(tools.isRefreshingQuotas)
        }
    }

    private func writeClaudeUsage(tokens: Int, root: URL) throws {
        let url = root.appendingPathComponent("projects/fixture.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let row: [String: Any] = [
            "type": "assistant", "timestamp": timestamp,
            "message": ["id": "fixture", "role": "assistant", "usage": ["input_tokens": tokens, "output_tokens": 0]],
        ]
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(0x0A)
        try data.write(to: url)
    }

    private func makeFixture(enabled: [ToolUsageClient]) throws -> ConnectionPreferencesFixture {
        let suiteName = "codexbar.tool-connection-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update { $0.disabledTools = ApplicationPreferences.allTools.filter { !enabled.map(\.rawValue).contains($0) } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-tool-connection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ConnectionPreferencesFixture(defaults: defaults, preferences: preferences, suiteName: suiteName, folder: folder)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "等待隔离采集 fixture 超时")
    }

    private func accessibilityElements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 24, let element = object as? NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { self.accessibilityElements($0, depth: depth + 1) }
    }
}

@MainActor
private struct ConnectionPreferencesFixture {
    let defaults: UserDefaults
    let preferences: ApplicationPreferencesStore
    let suiteName: String
    let folder: URL

    func cleanUp() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        try? FileManager.default.removeItem(at: self.folder)
    }
}

private nonisolated final class ConnectionCollectorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    var count: Int { self.lock.withLock { self.storedCount } }
    func increment() { self.lock.withLock { self.storedCount += 1 } }
}

private nonisolated struct ConnectionFixtureCollector: ToolUsageCollecting {
    let client: ToolUsageClient
    let counter: ConnectionCollectorCounter
    func collect(now: Date, calendar: Calendar) -> ToolUsageSnapshot {
        self.counter.increment()
        return ToolUsageSnapshot(client: self.client, availability: .ready,
                                 dailyEntries: [.init(date: calendar.startOfDay(for: now), totalTokens: 37)])
    }
}

private nonisolated struct ConnectionFixtureCursorSyncer: CursorUsageSyncing {
    func sync(now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        ToolUsageSnapshot(client: .cursor, availability: .needsImport, evidence: .imported, refreshedAt: now)
    }
}

private actor ConnectionFixtureQuotaFetcher: ToolQuotaFetching {
    private(set) var callCount = 0
    private(set) var lastDirectories: [ToolUsageClient: String] = [:]
    func fetch(client: ToolUsageClient, preferences: ApplicationPreferences, now: Date) async -> ToolQuotaSnapshot {
        self.callCount += 1
        self.lastDirectories[client] = preferences.dataDirectory(for: client.rawValue)?.path
        return ToolQuotaSnapshot(client: client, status: .ready, providerName: client.displayName,
                                 windows: [.init(id: "fixture", label: "Fixture", usedPercent: 25)],
                                 refreshedAt: now, statusDetail: "隔离测试额度")
    }
}
