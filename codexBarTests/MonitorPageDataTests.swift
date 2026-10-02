import XCTest

final class MonitorPageDataTests: XCTestCase {
    func testUnattributedModelRetainsKnownPartialCost() throws {
        let now = Date()
        let tool = ToolUsageSnapshot(client: .openCode, availability: .ready, dailyEntries: [
            ToolUsageDailyEntry(date: now.addingTimeInterval(-10), totalTokens: 100, knownCostUSD: 1.25)
        ])
        let result = MonitorPageData.build(costSummary: .empty, records: nil,
            toolSnapshots: [.openCode: tool], modelUsage: nil, runningThreads: .empty,
            period: .allTime, scope: .all, now: now)
        let model = try XCTUnwrap(result.models?.first)
        XCTAssertEqual(model.modelID, "unknown")
        XCTAssertEqual(model.estimatedCostUSD, 1.25)
        XCTAssertFalse(model.costIsComplete)
    }

    func testBackgroundProjectionSharesLatestDuplicateAcrossAllSections() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workerCalendar = calendar
        let now = self.date("2026-09-30T20:00:00Z")
        let old = ToolUsageRecord(
            id: "revised", timestamp: self.date("2026-09-30T09:00:00Z"),
            modelID: "obsolete", sessionID: "revised-session", totalTokens: 100, costUSD: 10
        )
        let latest = ToolUsageRecord(
            id: "revised", timestamp: self.date("2026-09-30T11:00:00Z"),
            modelID: "latest-model", sessionID: "revised-session", totalTokens: 20, costUSD: 2
        )
        let missingModel = ToolUsageRecord(
            id: "missing-model", timestamp: self.date("2026-09-30T10:00:00Z"),
            sessionID: "unknown-session", totalTokens: 5
        )
        let yesterday = ToolUsageRecord(
            id: "yesterday", timestamp: self.date("2026-09-29T12:00:00Z"),
            modelID: "older-model", sessionID: "older-session", totalTokens: 7, costUSD: 0.7
        )
        let snapshot = ToolUsageSnapshot(
            client: .openCode, availability: .ready,
            dailyEntries: [
                ToolUsageDailyEntry(date: self.date("2026-09-30T00:00:00Z"), totalTokens: 30),
                ToolUsageDailyEntry(date: self.date("2026-09-29T00:00:00Z"), totalTokens: 7, costUSD: 0.7),
            ],
            usageRecords: [latest, old, missingModel, latest, yesterday]
        )

        let result = await Task.detached {
            MonitorPageData.build(
                costSummary: .empty, records: nil, toolSnapshots: [.openCode: snapshot],
                modelUsage: nil, runningThreads: .empty, period: .today, scope: .all,
                now: now, calendar: workerCalendar
            )
        }.value

        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions.first { $0.sessionID == "revised-session" }?.totalTokens, 20)
        XCTAssertEqual(result.recentSessions.first { $0.sessionID == "revised-session" }?.totalTokens, 20)
        XCTAssertTrue(result.recentSessions.contains { $0.sessionID == "older-session" })
        XCTAssertNil(result.models?.first { $0.modelID == "obsolete" })
        XCTAssertEqual(result.models?.first { $0.modelID == "latest-model" }?.totalTokens, 20)
        XCTAssertEqual(result.models?.first { $0.modelID == "unknown" }?.totalTokens, 10)
        XCTAssertEqual(result.missingModelCount, 1)
        XCTAssertEqual(result.models?.reduce(0) { $0 + $1.totalTokens }, 30)
    }

    func testIndexedModelUsageAttributesEachEventToItsOwnModelAndFiltersPeriod() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-monitor-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let store = try LocalCostIndexStore(
            databaseURL: root.appendingPathComponent("usage.sqlite"),
            calendar: calendar
        )
        let path = root.appendingPathComponent("one-session.jsonl").path
        let events = [
            self.event("previous-week", path: path, at: "2026-09-27T12:00:00Z", model: "gpt-5.5", input: 10),
            self.event("week-model-a", path: path, at: "2026-09-29T12:00:00Z", model: "gpt-5.5", input: 20),
            self.event("today-model-b", path: path, at: "2026-09-30T12:00:00Z", model: "gpt-5.6-terra", input: 30),
            self.event("future-model-b", path: path, at: "2026-10-01T12:00:00Z", model: "gpt-5.6-terra", input: 40),
        ]
        try store.commitFileScan(LocalCostFileScanCommit(
            path: path,
            fileIdentifier: "one-session",
            size: 1_024,
            modificationTime: self.date("2026-10-01T12:00:00Z"),
            parsedBytes: 1_024,
            anchorHash: "test",
            parserStateData: Data("{}".utf8),
            isComplete: true,
            replaceExistingEvents: true,
            events: events
        ))

        let now = self.date("2026-09-30T20:00:00Z")
        let today = try XCTUnwrap(store.modelUsage(period: .today, now: now).first)
        XCTAssertEqual(today.modelID, "gpt-5.6-terra")
        XCTAssertEqual(today.totalTokens, 30)

        let week = try store.modelUsage(period: .thisWeek, now: now)
        XCTAssertEqual(week.count, 2)
        XCTAssertEqual(week.first(where: { $0.modelID == "gpt-5.5" })?.totalTokens, 20)
        XCTAssertEqual(week.first(where: { $0.modelID == "gpt-5.6-terra" })?.totalTokens, 30)
        XCTAssertTrue(week.allSatisfy { $0.estimatedCostUSD > 0 })

        let allTime = try store.modelUsage(period: .allTime, now: now)
        XCTAssertEqual(allTime.first(where: { $0.modelID == "gpt-5.5" })?.totalTokens, 30)
        XCTAssertEqual(allTime.first(where: { $0.modelID == "gpt-5.6-terra" })?.totalTokens, 30)
        XCTAssertEqual(allTime.reduce(0) { $0 + $1.totalTokens }, 60)

        let afterAllEvents = self.date("2026-10-02T12:00:00Z")
        let fullModelUsage = try store.modelUsage(period: .allTime, now: afterAllEvents)
        let fullSummary = try store.summary(now: afterAllEvents).summary
        XCTAssertEqual(fullModelUsage.reduce(0) { $0 + $1.totalTokens }, fullSummary.lifetimeTokens)
        XCTAssertEqual(
            fullModelUsage.reduce(0) { $0 + $1.estimatedCostUSD },
            fullSummary.lifetimeCostUSD,
            accuracy: 1e-12
        )
    }

    func testPageDataUsesRealSessionsRunningCWDAndSparseDailyTrend() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = self.date("2026-09-30T20:00:00Z")
        let day28 = self.date("2026-09-28T00:00:00Z")
        let day29 = self.date("2026-09-29T00:00:00Z")
        let day30 = self.date("2026-09-30T00:00:00Z")
        let summary = LocalCostSummary(
            todayCostUSD: 0.3,
            todayTokens: 30,
            last30DaysCostUSD: 0.5,
            last30DaysTokens: 50,
            lifetimeCostUSD: 0.5,
            lifetimeTokens: 50,
            dailyEntries: [
                DailyCostEntry(id: "30", date: day30, costUSD: 0.3, totalTokens: 30),
                DailyCostEntry(id: "29", date: day29, costUSD: 0.2, totalTokens: 20),
            ],
            updatedAt: now
        )
        let external = ToolUsageSnapshot(
            client: .claudeCode,
            availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: day28, totalTokens: 100, costUSD: nil)]
        )
        let session = HistoricalSessionRecord(
            sessionID: "real-session",
            modelID: "gpt-5.5",
            startedAt: day29,
            lastActivityAt: day30,
            isArchived: false,
            totalTokens: 50
        )
        let earlierSession = HistoricalSessionRecord(
            sessionID: "previous-week",
            modelID: "gpt-5.5",
            startedAt: self.date("2026-09-20T00:00:00Z"),
            lastActivityAt: self.date("2026-09-20T12:00:00Z"),
            isArchived: true,
            totalTokens: 10
        )
        let futureSession = HistoricalSessionRecord(
            sessionID: "future",
            modelID: "gpt-5.5",
            startedAt: self.date("2026-10-01T00:00:00Z"),
            lastActivityAt: self.date("2026-10-01T12:00:00Z"),
            isArchived: false,
            totalTokens: 20
        )
        let records = RecordsSnapshot(
            generatedAt: now,
            refreshMode: .incremental,
            models: [HistoricalModelRecord(
                modelID: "gpt-5.5",
                sessionCount: 3,
                lastSeenAt: futureSession.lastActivityAt
            )],
            sessions: [session, earlierSession, futureSession],
            warnings: [RecordsSnapshotWarning(
                sessionFilePath: "/tmp/incomplete.jsonl",
                kind: .incompleteSessionRecord,
                message: "partial"
            )]
        )
        let attribution = OpenAIRunningThreadAttribution(
            threads: [
                .init(threadID: "one", source: "cli", cwd: "/tmp/project-a", title: "Private title", lastRuntimeAt: now, accountID: nil),
                .init(threadID: "two", source: "cli", cwd: "/tmp/project-a/.", title: "Other private title", lastRuntimeAt: day30, accountID: nil),
                .init(threadID: "unknown-cwd", source: "cli", cwd: "", title: "No project", lastRuntimeAt: now, accountID: nil),
                .init(threadID: "relative-cwd", source: "cli", cwd: "project-b", title: "Relative path", lastRuntimeAt: now, accountID: nil),
            ],
            summary: .init(availability: .available, runningThreadCounts: [:], unknownThreadCount: 4),
            recentActivityWindow: 5,
            diagnosticMessage: nil,
            unavailableReason: nil
        )
        let model = MonitorModelUsage(
            modelID: "gpt-5.5", inputTokens: 40, cachedInputTokens: 5,
            outputTokens: 10, totalTokens: 50, estimatedCostUSD: 0.5, lastUsedDay: day30
        )

        let page = MonitorPageData.build(
            costSummary: summary,
            records: records,
            toolSnapshots: [.claudeCode: external],
            modelUsage: [model],
            runningThreads: attribution,
            period: .thisWeek,
            scope: .all,
            codexSessions: [MonitorCodexSessionUsage(
                sessionID: session.sessionID, title: "Historical session", projectPath: nil,
                modelIDs: [session.modelID], firstUsageAt: session.startedAt,
                lastActivityAt: session.lastActivityAt, totalTokens: 50,
                knownCostUSD: 0.5, costIsComplete: true
            )],
            now: now,
            calendar: calendar,
            localDeviceName: "Test Mac"
        )

        var expectedModel = model
        expectedModel.toolBreakdown = [MonitorModelToolUsage(
            sourceID: "codex", inputTokens: model.inputTokens, cachedInputTokens: model.cachedInputTokens,
            cacheWriteTokens: model.cacheWriteTokens, outputTokens: model.outputTokens,
            totalTokens: model.totalTokens, knownCostUSD: model.estimatedCostUSD, costIsComplete: model.costIsComplete
        )]
        XCTAssertEqual(page.models?.first(where: { $0.modelID == model.modelID }), expectedModel)
        XCTAssertEqual(page.models?.first(where: { $0.modelID == "unknown" })?.totalTokens, 100)
        XCTAssertEqual(page.sessions.first(where: { $0.sessionID == "real-session" })?.totalTokens, 50)
        XCTAssertEqual(page.sessions.count, 5) // The four live sessions have no usage yet.
        XCTAssertTrue(page.recordsAvailable)
        XCTAssertEqual(page.recordWarningCount, 1)
        XCTAssertEqual(page.trend.totalTokens, 150)
        XCTAssertEqual(page.trend.activeDayCount, 3)
        XCTAssertEqual(page.trend.peakDay?.date, day28)
        XCTAssertEqual(page.trend.currentStreakDays, 3)
        XCTAssertEqual(page.trend.longestStreakDays, 3)
        XCTAssertFalse(page.trend.costIsComplete)
        XCTAssertEqual(page.projects.count, 1)
        XCTAssertEqual(page.projects.first?.cwd, "/tmp/project-a")
        XCTAssertEqual(page.projects.first?.runningThreadCount, 2)
        XCTAssertEqual(page.device.localDeviceName, "Test Mac")
        XCTAssertTrue(page.device.isLocalOnly)
    }

    func testUnavailableSourcesRemainExplicitlyUnavailable() {
        let page = MonitorPageData.build(
            costSummary: .empty,
            records: nil,
            toolSnapshots: [:],
            modelUsage: nil,
            runningThreads: .init(
                threads: [],
                summary: .unavailable,
                recentActivityWindow: 5,
                diagnosticMessage: "runtime unavailable",
                unavailableReason: nil
            ),
            period: .today,
            scope: .all,
            localDeviceName: "Test Mac"
        )
        XCTAssertNil(page.models)
        XCTAssertFalse(page.recordsAvailable)
        XCTAssertEqual(page.recordWarningCount, 0)
        XCTAssertTrue(page.sessions.isEmpty)
        XCTAssertFalse(page.projectsAvailable)
        XCTAssertTrue(page.projects.isEmpty)
        XCTAssertEqual(page.trend.activeDayCount, 0)
    }

    func testModelsMergeSourcesDeduplicateEventsAndPreserveUnattributedUsage() throws {
        let at = self.date("2026-09-30T12:00:00Z")
        let record = ToolUsageRecord(
            id: "one", timestamp: at, modelID: "shared-model", sessionID: "one",
            inputTokens: 12, outputTokens: 3, cacheReadTokens: 2, cacheWriteTokens: 1,
            totalTokens: 15, costUSD: 0.15
        )
        let external = ToolUsageSnapshot(
            client: .claudeCode, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: at, totalTokens: 40)],
            usageRecords: [record, record, ToolUsageRecord(id: "missing-model", timestamp: at, sessionID: "two", totalTokens: 5)]
        )
        let codex = MonitorModelUsage(
            modelID: "shared-model", inputTokens: 20, cachedInputTokens: 0,
            outputTokens: 0, totalTokens: 20, estimatedCostUSD: 0.2, lastUsedDay: at
        )
        let result = self.page(snapshots: [.claudeCode: external], models: [codex, codex])
        let model = try XCTUnwrap(result.models?.first { $0.modelID == "shared-model" })
        XCTAssertEqual(model.totalTokens, 35)
        XCTAssertEqual(model.sourceIDs, ["claudeCode", "codex"])
        XCTAssertEqual(model.inputTokens, 32)
        XCTAssertEqual(model.cacheWriteTokens, 1)
        XCTAssertEqual(model.estimatedCostUSD, 0.35, accuracy: 1e-12)
        XCTAssertTrue(model.costIsComplete)
        let unknown = try XCTUnwrap(result.models?.first { $0.modelID == "unknown" })
        XCTAssertEqual(unknown.totalTokens, 25)
        XCTAssertEqual(unknown.sourceIDs, ["claudeCode"])
        XCTAssertFalse(unknown.costIsComplete)
        XCTAssertEqual(result.models?.reduce(0) { $0 + $1.totalTokens }, 60)
        XCTAssertEqual(result.missingModelCount, 1)
    }

    func testExternalModelsAndSessionsRespectRealTimestampsAndScope() throws {
        let before = ToolUsageRecord(id: "before", timestamp: self.date("2026-09-29T23:59:59Z"), modelID: "old", sessionID: "old", totalTokens: 500)
        let current = ToolUsageRecord(id: "current", timestamp: self.date("2026-09-30T09:00:00Z"), modelID: "new", sessionID: "new", totalTokens: 25, costUSD: 1)
        let future = ToolUsageRecord(id: "future", timestamp: self.date("2026-09-30T23:00:00Z"), modelID: "future", sessionID: "future", totalTokens: 900)
        let snapshots: [ToolUsageClient: ToolUsageSnapshot] = [
            .openCode: ToolUsageSnapshot(client: .openCode, availability: .ready, dailyEntries: [ToolUsageDailyEntry(date: current.timestamp, totalTokens: 925)], usageRecords: [before, current, future]),
            .claudeCode: ToolUsageSnapshot(client: .claudeCode, availability: .ready, usageRecords: [current])
        ]
        let page = self.page(snapshots: snapshots, scope: .client(.openCode))
        XCTAssertEqual(page.models?.map(\.modelID), ["new"])
        XCTAssertEqual(page.models?.first?.totalTokens, 25)
        XCTAssertEqual(page.models?.first?.sourceIDs, ["openCode"])
        XCTAssertEqual(page.sessions.map(\.id), ["openCode|new"])
        XCTAssertEqual(page.sessions.first?.totalTokens, 25)
        XCTAssertEqual(Set(page.recentSessions.map(\.sessionID)), Set(["old", "new"]))
        XCTAssertTrue(self.page(snapshots: snapshots, models: [], scope: .codex).sessions.isEmpty)
        XCTAssertEqual(self.page(snapshots: snapshots, models: [], scope: .codex).models, [])
    }

    func testPeriodSessionsNeverBorrowLifetimeTotalsAndRuntimeAddsMetadata() throws {
        let at = self.date("2026-09-30T12:00:00Z")
        let records = RecordsSnapshot(
            generatedAt: at, refreshMode: .incremental, models: [],
            sessions: [
                HistoricalSessionRecord(sessionID: "active", modelID: "gpt", startedAt: self.date("2026-08-01T00:00:00Z"), lastActivityAt: at, isArchived: false, totalTokens: 99_000),
                HistoricalSessionRecord(sessionID: "lifetime-only", modelID: "gpt", startedAt: self.date("2026-08-01T00:00:00Z"), lastActivityAt: at, isArchived: false, totalTokens: 88_000),
                HistoricalSessionRecord(sessionID: "empty", modelID: "gpt", startedAt: at, lastActivityAt: at, isArchived: false, totalTokens: 0)
            ], warnings: []
        )
        let session = MonitorCodexSessionUsage(
            sessionID: "active", title: "Saved display name", projectPath: "/tmp/old-project", modelIDs: ["gpt"],
            firstUsageAt: at, lastActivityAt: at, totalTokens: 10, knownCostUSD: 0.1, costIsComplete: true
        )
        let runtime = self.attribution([
            .init(threadID: "active", source: "cli", cwd: "/tmp/new-project/.", title: "Runtime first message", lastRuntimeAt: at, accountID: nil),
            .init(threadID: "just-started", source: "cli", cwd: "/tmp/new-project", title: "New task", lastRuntimeAt: at, accountID: nil)
        ])
        let result = self.page(records: records, codexSessions: [session], running: runtime)
        XCTAssertEqual(result.sessions.reduce(0) { $0 + $1.totalTokens }, 10)
        XCTAssertNil(result.sessions.first { $0.sessionID == "lifetime-only" })
        // Indexed metadata carries the display name; runtime titles may still be the first message.
        XCTAssertEqual(result.sessions.first { $0.sessionID == "active" }?.title, "Saved display name")
        XCTAssertEqual(result.sessions.first { $0.sessionID == "just-started" }?.title, "New task")
        XCTAssertEqual(result.sessions.first { $0.sessionID == "active" }?.isRunning, true)
        XCTAssertEqual(result.sessions.first { $0.sessionID == "empty" }?.totalTokens, 0)
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(result.projects.first?.cwd, "/tmp/new-project")
        XCTAssertEqual(result.projects.first?.totalTokens, 10)
        XCTAssertEqual(result.projects.first?.runningThreadCount, 2)
        XCTAssertEqual(result.projects.first?.sessionCount, 2)
    }

    func testRecentSessionsIncludeFirstFiveAndEveryRunningSessionWithoutSourceCollisions() {
        var records = (1...7).map { index in
            ToolUsageRecord(
                id: "event-\(index)", timestamp: self.date("2026-09-30T20:00:00Z").addingTimeInterval(Double(-index * 60)),
                modelID: "m", sessionID: "s\(index)", sessionTitle: "Task \(index)",
                sessionIsRunning: index == 7, totalTokens: index
            )
        }
        records.append(ToolUsageRecord(
            id: "prior-month", timestamp: self.date("2026-08-31T12:00:00Z"),
            sessionID: "prior-month", sessionIsRunning: true, totalTokens: 100
        ))
        let codex = MonitorCodexSessionUsage(
            sessionID: "s1", title: "Codex task", projectPath: nil, modelIDs: ["gpt"],
            firstUsageAt: self.date("2026-09-30T19:59:59Z"), lastActivityAt: self.date("2026-09-30T19:59:59Z"),
            totalTokens: 40, knownCostUSD: 0, costIsComplete: false
        )
        let result = self.page(
            snapshots: [.deepSeekHarness: ToolUsageSnapshot(client: .deepSeekHarness, availability: .ready, usageRecords: records)],
            codexSessions: [], recentCodexSessions: [codex]
        )
        XCTAssertEqual(result.sessions.count, 7) // All seven external sessions had usage today.
        XCTAssertEqual(result.recentSessions.map(\.id), ["codex|s1", "deepSeekHarness|s1", "deepSeekHarness|s2", "deepSeekHarness|s3", "deepSeekHarness|s4", "deepSeekHarness|s7"])
        XCTAssertFalse(result.recentSessions.contains { $0.sessionID == "prior-month" })
    }

    func testHistoricalProjectsMergeSourcesAndKeepLatestSessionContext() throws {
        let early = self.date("2026-09-30T19:50:00Z")
        let late = self.date("2026-09-30T19:55:00Z")
        let openCode = ToolUsageSnapshot(client: .openCode, availability: .ready, usageRecords: [
            ToolUsageRecord(id: "a", timestamp: early, modelID: "a", sessionID: "same", sessionTitle: "Old", projectPath: "/tmp/shared/.", sessionIsRunning: true, contextWindowTokens: 100, contextUsedTokens: 10, totalTokens: 10, costUSD: 0.1),
            ToolUsageRecord(id: "b", timestamp: late, modelID: "b", sessionID: "same", sessionTitle: "Final", projectPath: "/tmp/shared", sessionIsRunning: false, contextWindowTokens: 200, contextUsedTokens: 80, totalTokens: 20, costUSD: 0.2)
        ])
        let claude = ToolUsageSnapshot(client: .claudeCode, availability: .ready, usageRecords: [
            ToolUsageRecord(id: "a", timestamp: late, modelID: "c", sessionID: "same", projectPath: "/tmp/shared", totalTokens: 40),
            ToolUsageRecord(id: "bad", timestamp: late, sessionID: "unattributable", projectPath: "relative-project", totalTokens: 100)
        ])
        let result = self.page(snapshots: [.openCode: openCode, .claudeCode: claude])
        let session = try XCTUnwrap(result.sessions.first { $0.id == "openCode|same" })
        XCTAssertEqual(session.title, "Final")
        XCTAssertEqual(session.modelIDs, ["a", "b"])
        XCTAssertEqual(session.isRunning, false)
        XCTAssertEqual(session.contextWindowTokens, 200)
        XCTAssertEqual(session.contextUsedTokens, 80)
        XCTAssertEqual(session.totalTokens, 30)
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(project.sourceIDs, ["claudeCode", "openCode"])
        XCTAssertEqual(project.sessionCount, 2)
        XCTAssertEqual(project.totalTokens, 70)
        XCTAssertEqual(project.knownCostUSD, 0.3, accuracy: 1e-12)
        XCTAssertFalse(project.costIsComplete)
        XCTAssertEqual(project.runningThreadCount, 0)
        XCTAssertEqual(project.toolBreakdown.map(\.sourceID), ["claudeCode", "openCode"])
        XCTAssertEqual(project.toolBreakdown.map(\.totalTokens), [40, 30])
        XCTAssertEqual(project.toolBreakdown.reduce(0) { $0 + $1.totalTokens }, project.totalTokens)
        XCTAssertEqual(project.toolBreakdown.first { $0.sourceID == "openCode" }?.sessionCount, 1)
        XCTAssertEqual(project.toolBreakdown.first { $0.sourceID == "openCode" }?.costIsComplete, true)
        XCTAssertEqual(project.toolBreakdown.first { $0.sourceID == "claudeCode" }?.costIsComplete, false)
    }

    func testProjectToolBreakdownUsesOnlyTheSelectedPeriod() throws {
        let now = self.date("2026-09-30T20:00:00Z")
        let yesterday = self.date("2026-09-29T12:00:00Z")
        let today = self.date("2026-09-30T12:00:00Z")
        let claude = ToolUsageSnapshot(client: .claudeCode, availability: .ready, usageRecords: [
            ToolUsageRecord(id: "old", timestamp: yesterday, sessionID: "claude-work", projectPath: "/tmp/shared/.", totalTokens: 100, costUSD: 2),
            ToolUsageRecord(id: "new", timestamp: today, sessionID: "claude-work", projectPath: "/tmp/shared", totalTokens: 40, costUSD: 1),
            ToolUsageRecord(id: "unassigned", timestamp: today, sessionID: "unassigned", totalTokens: 999),
        ])
        let openCode = ToolUsageSnapshot(client: .openCode, availability: .ready, usageRecords: [
            ToolUsageRecord(id: "work", timestamp: today, sessionID: "opencode-work", projectPath: "/tmp/shared", totalTokens: 60),
        ])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func projection(_ period: UsagePeriod) -> MonitorPageData {
            MonitorPageData.build(
                costSummary: .empty, records: nil, toolSnapshots: [.claudeCode: claude, .openCode: openCode],
                modelUsage: nil, runningThreads: .empty, period: period, scope: .all, now: now, calendar: calendar
            )
        }
        let day = try XCTUnwrap(projection(.today).projects.first)
        let week = try XCTUnwrap(projection(.last7Days).projects.first)
        XCTAssertEqual(projection(.today).projects.count, 1)
        XCTAssertEqual(day.totalTokens, 100)
        XCTAssertEqual(day.toolBreakdown.first { $0.sourceID == "claudeCode" }?.totalTokens, 40)
        XCTAssertEqual(week.totalTokens, 200)
        XCTAssertEqual(week.toolBreakdown.first { $0.sourceID == "claudeCode" }?.totalTokens, 140)
        XCTAssertEqual(week.toolBreakdown.first { $0.sourceID == "openCode" }?.totalTokens, 60)
        for project in [day, week] {
            XCTAssertEqual(project.toolBreakdown.reduce(0) { $0 + $1.totalTokens }, project.totalTokens)
            XCTAssertEqual(project.toolBreakdown.reduce(0) { $0 + $1.sessionCount }, project.sessionCount)
            XCTAssertFalse(project.costIsComplete)
        }
    }

    func testModelCacheHitRateNormalizesCodexAndSeparateExternalCacheBuckets() throws {
        let timestamp = self.date("2026-09-30T12:00:00Z")
        let codex = MonitorModelUsage(
            modelID: "shared-model", inputTokens: 100, cachedInputTokens: 80, outputTokens: 20,
            totalTokens: 120, estimatedCostUSD: 1.2, lastUsedDay: timestamp
        )
        let claude = ToolUsageSnapshot(client: .claudeCode, availability: .ready, usageRecords: [
            ToolUsageRecord(id: "one", timestamp: timestamp, modelID: "shared-model", inputTokens: 10,
                            outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 10, totalTokens: 50),
        ])
        let result = self.page(snapshots: [.claudeCode: claude], models: [codex])
        let model = try XCTUnwrap(result.models?.first)
        XCTAssertEqual(model.totalTokens, 170)
        XCTAssertEqual(model.cacheEligibleInputTokens, 140)
        XCTAssertEqual(try XCTUnwrap(model.cacheHitRate), 100.0 / 140.0, accuracy: 1e-12)
        XCTAssertTrue(model.hasCompleteTokenBreakdown)
        XCTAssertEqual(model.toolBreakdown.reduce(0) { $0 + $1.totalTokens }, 170)
        XCTAssertEqual(model.toolBreakdown.first { $0.sourceID == "codex" }?.cacheEligibleInputTokens, 100)
        XCTAssertEqual(model.toolBreakdown.first { $0.sourceID == "claudeCode" }?.cacheEligibleInputTokens, 40)
        XCTAssertFalse(model.costIsComplete)
        XCTAssertEqual(model.estimatedCostUSD, 1.2, accuracy: 1e-12)
    }

    func testUnattributedModelUsageDoesNotInventACacheHitRate() throws {
        let snapshot = ToolUsageSnapshot(client: .cursor, availability: .ready, dailyEntries: [
            ToolUsageDailyEntry(date: self.date("2026-09-30T00:00:00Z"), totalTokens: 500),
        ])
        let result = self.page(snapshots: [.cursor: snapshot])
        let model = try XCTUnwrap(result.models?.first)
        XCTAssertEqual(model.modelID, "unknown")
        XCTAssertNil(model.cacheHitRate)
        XCTAssertFalse(model.hasCompleteTokenBreakdown)
        XCTAssertFalse(model.costIsComplete)
    }

    func testMissingModelWarningsDoNotCountAsUnreadableSessions() {
        let at = self.date("2026-09-30T12:00:00Z")
        let records = RecordsSnapshot(generatedAt: at, refreshMode: .incremental, models: [], sessions: [], warnings: [
            RecordsSnapshotWarning(sessionFilePath: "/tmp/model.jsonl", kind: .missingModel, message: "model absent"),
            RecordsSnapshotWarning(sessionFilePath: "/tmp/unreadable.jsonl", kind: .unreadableSessionFile, message: "unreadable")
        ])
        let result = self.page(records: records)
        XCTAssertEqual(result.recordWarningCount, 1)
        XCTAssertEqual(result.missingModelCount, 1)
        let scoped = self.page(records: records, scope: .client(.cursor))
        XCTAssertEqual(scoped.recordWarningCount, 0)
        XCTAssertEqual(scoped.missingModelCount, 0)
    }

    func testRecentSessionsCrossMonthBoundaryAndUseThirtyCalendarDays() {
        let now = self.date("2026-10-01T00:05:00Z")
        let previousEvening = self.date("2026-09-30T23:58:00Z")
        let boundary = self.date("2026-09-02T00:00:00Z")
        let external = ToolUsageSnapshot(client: .claudeCode, availability: .ready, usageRecords: [
            ToolUsageRecord(id: "last-night", timestamp: previousEvening, sessionID: "last-night", sessionIsRunning: false, totalTokens: 20),
            ToolUsageRecord(id: "boundary", timestamp: boundary, sessionID: "boundary", totalTokens: 10),
            ToolUsageRecord(id: "outside", timestamp: boundary.addingTimeInterval(-1), sessionID: "outside", totalTokens: 30)
        ])
        let codex = MonitorCodexSessionUsage(
            sessionID: "codex-last-night", title: "Yesterday task", projectPath: nil, modelIDs: ["gpt"],
            firstUsageAt: previousEvening, lastActivityAt: previousEvening,
            totalTokens: 40, knownCostUSD: 1, costIsComplete: true
        )
        let result = self.page(snapshots: [.claudeCode: external], codexSessions: [], recentCodexSessions: [codex], now: now)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(Set(result.recentSessions.map(\.sessionID)), Set(["last-night", "boundary", "codex-last-night"]))
        XCTAssertEqual(result.recentSessions.first { $0.sessionID == "last-night" }?.isRunning, false)
    }

    func testCodexRuntimeAbsenceDoesNotClaimSessionCompleted() {
        let at = self.date("2026-09-30T19:59:00Z")
        let session = MonitorCodexSessionUsage(
            sessionID: "quiet", title: "Quiet task", projectPath: nil, modelIDs: ["gpt"],
            firstUsageAt: at, lastActivityAt: at, totalTokens: 10, knownCostUSD: 1, costIsComplete: true
        )
        let records = RecordsSnapshot(generatedAt: at, refreshMode: .incremental, models: [], sessions: [
            HistoricalSessionRecord(sessionID: "archived-empty", modelID: "gpt", startedAt: at, lastActivityAt: at, isArchived: true, totalTokens: 0)
        ], warnings: [])
        let result = self.page(records: records, codexSessions: [session], recentCodexSessions: [session], running: .empty)
        XCTAssertNil(result.sessions.first { $0.sessionID == "quiet" }?.isRunning)
        XCTAssertNil(result.sessions.first { $0.sessionID == "archived-empty" }?.isRunning)
        XCTAssertNil(result.recentSessions.first { $0.sessionID == "quiet" }?.isRunning)
    }

    func testExternalExplicitSessionStateExpiresAfterTenMinutes() {
        let now = self.date("2026-09-30T20:00:00Z")
        let specs: [(String, TimeInterval, Bool?)] = [
            ("running-boundary", -600, true), ("running-expired", -601, true),
            ("completed-recent", -300, false), ("completed-expired", -601, false),
            ("unknown-recent", -60, nil)
        ]
        let records = specs.map { name, age, state in
            ToolUsageRecord(id: name, timestamp: now.addingTimeInterval(age), sessionID: name, sessionIsRunning: state, totalTokens: 1)
        }
        let result = self.page(snapshots: [.openCode: ToolUsageSnapshot(client: .openCode, availability: .ready, usageRecords: records)], now: now)
        XCTAssertEqual(result.sessions.first { $0.sessionID == "running-boundary" }?.isRunning, true)
        XCTAssertNil(result.sessions.first { $0.sessionID == "running-expired" }?.isRunning)
        XCTAssertEqual(result.sessions.first { $0.sessionID == "completed-recent" }?.isRunning, false)
        XCTAssertNil(result.sessions.first { $0.sessionID == "completed-expired" }?.isRunning)
        XCTAssertNil(result.sessions.first { $0.sessionID == "unknown-recent" }?.isRunning)
    }

    private func page(
        records: RecordsSnapshot? = nil,
        snapshots: [ToolUsageClient: ToolUsageSnapshot] = [:],
        models: [MonitorModelUsage]? = nil,
        scope: UsageScope = .all,
        codexSessions: [MonitorCodexSessionUsage]? = nil,
        recentCodexSessions: [MonitorCodexSessionUsage]? = nil,
        running: OpenAIRunningThreadAttribution = .empty,
        now: Date? = nil
    ) -> MonitorPageData {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return MonitorPageData.build(
            costSummary: .empty, records: records, toolSnapshots: snapshots, modelUsage: models,
            runningThreads: running, period: .today, scope: scope,
            codexSessions: codexSessions, recentCodexSessions: recentCodexSessions,
            now: now ?? self.date("2026-09-30T20:00:00Z"), calendar: calendar
        )
    }

    private func attribution(_ threads: [OpenAIRunningThreadAttribution.ThreadAttribution]) -> OpenAIRunningThreadAttribution {
        OpenAIRunningThreadAttribution(threads: threads, summary: .empty, recentActivityWindow: 5, diagnosticMessage: nil, unavailableReason: nil)
    }

    private func event(
        _ key: String,
        path: String,
        at timestamp: String,
        model: String,
        input: Int
    ) -> LocalCostIndexedEvent {
        LocalCostIndexedEvent(
            eventKey: key,
            path: path,
            sessionID: "same-session",
            timestamp: self.date(timestamp),
            model: model,
            turnID: nil,
            serviceTier: .standard,
            source: .nativeSession,
            usage: SessionLogStore.Usage(inputTokens: input, cachedInputTokens: 0, outputTokens: 0)
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
