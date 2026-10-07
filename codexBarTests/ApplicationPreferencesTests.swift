import Foundation
import XCTest

@MainActor
final class ApplicationPreferencesTests: CodexBarTestCase {
    func testPageNavigationDefaultsToLimitsThenStatistics() throws {
        let expected = ["limits", "home", "tools", "models", "projects", "sessions", "devices", "trends"]
        XCTAssertEqual(ApplicationPreferences().pageOrder, expected)
        XCTAssertEqual(try JSONDecoder().decode(ApplicationPreferences.self, from: Data("{}".utf8)).visiblePages, expected)
    }

    func testLegacyDefaultPageOrderMigratesToLimitsThenStatistics() throws {
        let legacyOrder = ["home", "limits", "tools", "models", "projects", "sessions", "devices", "trends"]
        let data = try JSONSerialization.data(withJSONObject: ["pageOrder": legacyOrder])
        var preferences = try JSONDecoder().decode(ApplicationPreferences.self, from: data)
        XCTAssertEqual(preferences.pageOrder, ApplicationPreferences.allPages)
        preferences.normalize()
        XCTAssertEqual(preferences.pageOrder, ApplicationPreferences.allPages, "重复规范化不得重新调整页面顺序")
        XCTAssertEqual(try JSONDecoder().decode(ApplicationPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testStoredLegacyDefaultPageOrderMigratesAndSurvivesStoreReconstruction() throws {
        let suite = "codexbar.tests.page-order-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyOrder = ["home", "limits", "tools", "models", "projects", "sessions", "devices", "trends"]
        defaults.set(try JSONSerialization.data(withJSONObject: ["pageOrder": legacyOrder]),
                     forKey: ApplicationPreferencesStore.defaultsKey)

        let store = ApplicationPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.preferences.pageOrder, ApplicationPreferences.allPages)
        XCTAssertEqual(ApplicationPreferencesStore(defaults: defaults).preferences.pageOrder, ApplicationPreferences.allPages)

        store.update { $0.fontScale = 1.1 }
        let savedData = try XCTUnwrap(defaults.data(forKey: ApplicationPreferencesStore.defaultsKey))
        XCTAssertEqual(try JSONDecoder().decode(ApplicationPreferences.self, from: savedData).pageOrder,
                       ApplicationPreferences.allPages)
        XCTAssertEqual(ApplicationPreferencesStore(defaults: defaults).preferences.pageOrder, ApplicationPreferences.allPages)
    }

    func testUnifiedNavigationPreservesSavedPageOrderAndStatisticsModulePreferences() throws {
        let order = ["trends", "home", "models", "limits", "sessions", "projects", "devices", "tools"]
        let modules = ["activity", "models", "limits", "tools", "sessions", "devices", "trends"]
        let data = try JSONSerialization.data(withJSONObject: [
            "pageOrder": order,
            "hiddenPages": ["limits", "devices"],
            "homeModuleOrder": modules,
            "hiddenHomeModules": ["limits", "trends"],
        ])
        let preferences = try JSONDecoder().decode(ApplicationPreferences.self, from: data)
        XCTAssertEqual(preferences.pageOrder, order, "合并导航后保留已保存的自定义页面顺序")
        XCTAssertEqual(preferences.hiddenPages, ["devices"], "额度页承接管理入口，旧隐藏偏好必须解除")
        XCTAssertEqual(preferences.homeModuleOrder, modules)
        XCTAssertEqual(preferences.hiddenHomeModules, ["limits", "trends"], "统计模块偏好沿用原有 ID")
        XCTAssertEqual(try JSONDecoder().decode(ApplicationPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testStoredCustomPageOrderRemainsUnchangedAfterReconstruction() throws {
        let suite = "codexbar.tests.custom-page-order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let order = ["home", "limits", "models", "tools", "projects", "sessions", "devices", "trends"]
        defaults.set(try JSONSerialization.data(withJSONObject: ["pageOrder": order]),
                     forKey: ApplicationPreferencesStore.defaultsKey)
        let store = ApplicationPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.preferences.pageOrder, order, "即使额度和统计位于旧位置，真正的自定义顺序仍应保留")
        store.update { $0.fontScale = 1.1 }
        XCTAssertEqual(ApplicationPreferencesStore(defaults: defaults).preferences.pageOrder, order)
    }

    func testManagementCollapseDefaultsAndLegacyDecodePreserveSavedSoftwareOrder() throws {
        XCTAssertEqual(ApplicationPreferences().collapsedManagementTools, ApplicationPreferences.allTools)
        XCTAssertEqual(ApplicationPreferences().managementSectionLayoutVersion, 2)
        let legacy = Data(#"{"toolOrder":["cursor","codex","claudeCode","openCode","deepSeekHarness"],"disabledTools":["openCode"]}"#.utf8)
        let restored = try JSONDecoder().decode(ApplicationPreferences.self, from: legacy)
        XCTAssertEqual(restored.toolOrder, ["cursor", "codex", "claudeCode", "openCode", "deepSeekHarness"])
        XCTAssertEqual(restored.collapsedManagementTools, ApplicationPreferences.allTools)
        XCTAssertTrue(restored.isManagementToolCollapsed("codex"))
        XCTAssertTrue(restored.isManagementToolCollapsed("openCode"))
        XCTAssertEqual(restored.disabledTools, ["openCode"])

        let explicitExpansion = try JSONDecoder().decode(ApplicationPreferences.self, from: Data(#"{"managementSectionLayoutVersion":2,"collapsedManagementTools":[]}"#.utf8))
        XCTAssertTrue(explicitExpansion.collapsedManagementTools.isEmpty, "已保存的全部展开不能重新变为默认折叠")
    }

    func testLegacyManagementMigrationOnlyCollapsesNewInlineSoftwareAndPreservesCodexChoice() throws {
        let otherTools = ApplicationPreferences.allTools.filter { $0 != "codex" }
        for version in [nil, 1] as [Int?] {
            for codexWasCollapsed in [false, true] {
                var legacy: [String: Any] = [
                    "toolOrder": ["cursor", "codex", "claudeCode", "openCode", "deepSeekHarness"],
                    "collapsedManagementTools": codexWasCollapsed ? ["codex"] : [],
                    "disabledTools": ["openCode"],
                ]
                if let version { legacy["managementSectionLayoutVersion"] = version }
                let preferences = try JSONDecoder().decode(ApplicationPreferences.self,
                    from: JSONSerialization.data(withJSONObject: legacy))
                XCTAssertEqual(preferences.managementSectionLayoutVersion, 2)
                XCTAssertEqual(preferences.collapsedManagementTools, (codexWasCollapsed ? ["codex"] : []) + otherTools)
                XCTAssertEqual(preferences.isManagementToolCollapsed("codex"), codexWasCollapsed)
                XCTAssertEqual(preferences.toolOrder, ["cursor", "codex", "claudeCode", "openCode", "deepSeekHarness"])
                XCTAssertEqual(preferences.disabledTools, ["openCode"])
                XCTAssertEqual(try JSONDecoder().decode(ApplicationPreferences.self,
                    from: JSONEncoder().encode(preferences)), preferences, "迁移后的版本记录必须阻止重复迁移")
            }
        }
    }

    func testManagementCollapseNormalizationRejectsUnknownIDsAndDuplicates() throws {
        let invalid = Data(#"{"managementSectionLayoutVersion":2,"toolOrder":["cursor","unknown","cursor"],"collapsedManagementTools":["unknown","codex","cursor","codex","cursor"]}"#.utf8)
        let preferences = try JSONDecoder().decode(ApplicationPreferences.self, from: invalid)
        XCTAssertEqual(preferences.toolOrder, ["cursor", "codex", "claudeCode", "openCode", "deepSeekHarness"])
        XCTAssertEqual(preferences.collapsedManagementTools, ["codex", "cursor"])
        XCTAssertFalse(preferences.isManagementToolCollapsed("unknown"))
        XCTAssertEqual(try JSONDecoder().decode(ApplicationPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testManagementSortingAndCollapsePersistWithoutChangingCollectionPreferences() throws {
        let suite = "codexbar.tests.management-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"{"toolOrder":["cursor","codex","claudeCode","openCode","deepSeekHarness"],"disabledTools":["openCode"],"customDataDirectories":{"claudeCode":"/fixture/claude"}}"#.utf8)
        defaults.set(legacy, forKey: ApplicationPreferencesStore.defaultsKey)
        let store = ApplicationPreferencesStore(defaults: defaults)
        store.toggleManagementToolCollapsed("codex")
        store.setManagementToolCollapsed("openCode", collapsed: true)
        store.moveManagementTool("claudeCode", by: -1)
        store.moveManagementTool("openCode", by: -1)
        let restored = ApplicationPreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.preferences.toolOrder, ["cursor", "claudeCode", "openCode", "codex", "deepSeekHarness"])
        XCTAssertEqual(restored.preferences.collapsedManagementTools, ApplicationPreferences.allTools.filter { $0 != "codex" })
        XCTAssertEqual(restored.preferences.disabledTools, ["openCode"], "软件折叠和排序不得自动启用或暂停采集")
        XCTAssertEqual(restored.preferences.customDataDirectories, ["claudeCode": "/fixture/claude"])
        XCTAssertFalse(restored.preferences.isManagementToolCollapsed("codex"))
    }

    func testEveryManagementSoftwareKeepsItsOwnPersistedExpansionState() throws {
        let suite = "codexbar.tests.management-all-sections.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationPreferencesStore(defaults: defaults)
        store.update {
            $0.collapsedManagementTools = []
            $0.disabledTools = ["openCode"]
            $0.toolOrder = ["cursor", "claudeCode", "codex", "deepSeekHarness", "openCode"]
        }
        let order = store.preferences.toolOrder
        var collapsed: [String] = []
        for key in ApplicationPreferences.allTools {
            store.toggleManagementToolCollapsed(key)
            collapsed.append(key)
            let restored = ApplicationPreferencesStore(defaults: defaults).preferences
            XCTAssertEqual(restored.collapsedManagementTools, collapsed, key)
            XCTAssertTrue(restored.isManagementToolCollapsed(key), key)
            XCTAssertEqual(restored.toolOrder, order, "折叠不得改变软件顺序")
            XCTAssertEqual(restored.disabledTools, ["openCode"], "折叠不得改变软件采集状态")
        }
        for key in ApplicationPreferences.allTools.reversed() {
            store.toggleManagementToolCollapsed(key)
            collapsed.removeAll { $0 == key }
            let restored = ApplicationPreferencesStore(defaults: defaults).preferences
            XCTAssertEqual(restored.collapsedManagementTools, collapsed, key)
            XCTAssertFalse(restored.isManagementToolCollapsed(key), key)
            XCTAssertEqual(restored.disabledTools, ["openCode"])
        }
        XCTAssertTrue(ApplicationPreferencesStore(defaults: defaults).preferences.collapsedManagementTools.isEmpty,
                      "全部展开应持久化为空列表，而不是恢复缺省折叠")
    }

    func testManagementMovesClampAtEdgesAndUnknownToolsDoNotPersist() throws {
        let suite = "codexbar.tests.management-boundaries.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationPreferencesStore(defaults: defaults)
        let initial = store.preferences
        store.moveManagementTool("codex", by: -1)
        store.moveManagementTool("deepSeekHarness", by: 1)
        store.moveManagementTool("cursor", by: 0)
        store.moveManagementTool("unknown", by: 1)
        store.setManagementToolCollapsed("unknown", collapsed: true)
        store.toggleManagementToolCollapsed("unknown")
        XCTAssertEqual(store.preferences, initial)
        XCTAssertNil(defaults.data(forKey: ApplicationPreferencesStore.defaultsKey), "无效或边界操作不得写入偏好")

        store.moveManagementTool("codex", by: Int.max)
        XCTAssertEqual(store.preferences.toolOrder, ["claudeCode", "openCode", "cursor", "deepSeekHarness", "codex"])
        store.moveManagementTool("deepSeekHarness", by: Int.min)
        XCTAssertEqual(store.preferences.toolOrder, ["deepSeekHarness", "claudeCode", "openCode", "cursor", "codex"])
        XCTAssertEqual(Set(store.preferences.toolOrder), Set(ApplicationPreferences.allTools))
        XCTAssertEqual(store.preferences.toolOrder.count, ApplicationPreferences.allTools.count)
    }

    func testAccountIdentityDisplayDefaultsToEmailAndPreservesLegacyPrivacyPreference() throws {
        XCTAssertEqual(ApplicationPreferences().accountIdentityDisplay, .email)
        let missing = try JSONDecoder().decode(ApplicationPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.accountIdentityDisplay, .email)

        for hidesEmail in [false, true] {
            let data = try JSONSerialization.data(withJSONObject: ["hideAccountEmail": hidesEmail])
            let preferences = try JSONDecoder().decode(ApplicationPreferences.self, from: data)
            XCTAssertEqual(preferences.accountIdentityDisplay, hidesEmail ? .name : .email)
        }
    }

    func testAccountIdentityDisplayPersistsBothSelectionsUsingExistingPrivacyKey() throws {
        for hidesEmail in [false, true] {
            let suite = "codexbar.tests.identity.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let legacyData = try JSONSerialization.data(withJSONObject: ["hideAccountEmail": hidesEmail])
            defaults.set(legacyData, forKey: ApplicationPreferencesStore.defaultsKey)

            let store = ApplicationPreferencesStore(defaults: defaults)
            XCTAssertEqual(store.preferences.accountIdentityDisplay, hidesEmail ? .name : .email)
            let selection: ApplicationPreferences.AccountIdentityDisplay = hidesEmail ? .email : .name
            store.update { $0.accountIdentityDisplay = selection }

            let storedData = try XCTUnwrap(defaults.data(forKey: ApplicationPreferencesStore.defaultsKey))
            let storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
            XCTAssertEqual(storedObject["hideAccountEmail"] as? Bool, !hidesEmail)
            XCTAssertNil(storedObject["accountIdentityDisplay"], "The display choice must have only one stored source of truth")
            let restored = ApplicationPreferencesStore(defaults: defaults)
            XCTAssertEqual(restored.preferences.accountIdentityDisplay, selection)
            XCTAssertEqual(restored.preferences.hideAccountEmail, !hidesEmail)
        }
    }

    func testAccountIdentityUsesEmailByDefaultAndNameWhenSelected() {
        var preferences = ApplicationPreferences()
        XCTAssertEqual(preferences.accountIdentity(
            email: "  person@example.com\n", displayName: " Person ", username: "person",
            organizationName: "Team", accountID: "account-123456"
        ), "person@example.com")

        preferences.accountIdentityDisplay = .name
        XCTAssertEqual(preferences.accountIdentity(
            email: "person@example.com", displayName: " Person\n", username: "person",
            organizationName: "Team", accountID: "account-123456"
        ), "Person")
        XCTAssertEqual(preferences.accountIdentity(
            email: "person@example.com", displayName: " \n", username: " person ",
            organizationName: "Team", accountID: "account-123456"
        ), "person")
        XCTAssertEqual(preferences.accountIdentity(
            email: "person@example.com", displayName: nil, username: nil,
            organizationName: " Team ", accountID: "account-123456"
        ), "Team")
    }

    func testAccountIdentityRejectsEmailBearingNameCandidates() {
        var preferences = ApplicationPreferences()
        preferences.accountIdentityDisplay = .name
        XCTAssertEqual(preferences.accountIdentity(
            email: "person@example.com", displayName: "Person <person@example.com>", username: " member ",
            organizationName: "Team", accountID: "account-123456"
        ), "member")
        XCTAssertEqual(preferences.accountIdentity(
            email: "person@example.com", displayName: "person@example.com", username: "member@example.com",
            organizationName: " Team ", accountID: "account-123456"
        ), "Team")
        XCTAssertEqual(preferences.accountIdentity(
            email: "person@example.com", displayName: "person@example.com", username: "member@example.com",
            organizationName: "team@example.com", accountID: "account-123456"
        ), "…123456")
    }

    func testAccountIdentityWithoutNameFallsBackToSafeAccountIDSuffix() {
        var preferences = ApplicationPreferences()
        preferences.accountIdentityDisplay = .name
        XCTAssertEqual(preferences.accountIdentity(
            email: "person@example.com", displayName: nil, username: " \n", accountID: " account-123456\n"
        ), "…123456")
        XCTAssertEqual(preferences.accountIdentity(
            email: "person@example.com", displayName: nil, username: nil, accountID: "abc"
        ), "…abc")
        for accountID in ["person@example.com", " \n"] {
            XCTAssertEqual(preferences.accountIdentity(
                email: "person@example.com", displayName: nil, username: nil, accountID: accountID
            ), "—")
        }
    }

    func testAccountIdentityWithMissingEmailUsesSameNameFallbacks() {
        let preferences = ApplicationPreferences()
        XCTAssertEqual(preferences.accountIdentity(
            email: " \n", displayName: " Person ", username: nil, accountID: "account-123456"
        ), "Person")
        XCTAssertEqual(preferences.accountIdentity(
            email: "", displayName: "person@example.com", username: nil, accountID: "account-123456"
        ), "…123456")
    }

    func testMigrationPreservesExistingLanguageAndDraggedWindowHeight() throws {
        let suite = "codexbar.tests.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "languageOverride")
        defaults.set(812, forKey: "codexbar.menuBarPopoverPreferredHeight")

        let store = ApplicationPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.preferences.language, .english)
        XCTAssertEqual(store.preferences.preferredMenuHeight, 812)
        XCTAssertTrue(store.preferences.automaticUpdateChecks)
        XCTAssertFalse(store.preferences.automaticallyDownloadUpdates)
        XCTAssertFalse(store.preferences.scheduledExportEnabled)

        store.update { $0.theme = .light }
        defaults.set(940, forKey: "codexbar.menuBarPopoverPreferredHeight")
        store.update { $0.accentColor = .blue }
        XCTAssertEqual(defaults.double(forKey: "codexbar.menuBarPopoverPreferredHeight"), 940,
                       "Changing colors must not undo a window resize")
        let restored = ApplicationPreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.preferences.preferredMenuHeight, 940)
        XCTAssertEqual(restored.preferences.theme, .light)
        restored.update { $0.preferredMenuHeight = 700 }
        XCTAssertEqual(defaults.double(forKey: "codexbar.menuBarPopoverPreferredHeight"), 700)
    }

    func testUnknownAndDuplicatePagesCannotRemoveLimitsOrStatisticsOrCreateBrokenNavigation() throws {
        let data = Data(#"{"pageOrder":["models","unknown","models"],"hiddenPages":["home","limits","models","unknown"],"homeItemLimit":999,"refreshIntervalSeconds":0,"fontScale":9}"#.utf8)
        let preferences = try JSONDecoder().decode(ApplicationPreferences.self, from: data)
        XCTAssertEqual(preferences.pageOrder.first, "models")
        XCTAssertEqual(Set(preferences.pageOrder), Set(ApplicationPreferences.allPages))
        XCTAssertEqual(preferences.pageOrder.count, ApplicationPreferences.allPages.count)
        XCTAssertTrue(preferences.visiblePages.contains("home"))
        XCTAssertTrue(preferences.visiblePages.contains("limits"))
        XCTAssertFalse(preferences.visiblePages.contains("models"))
        XCTAssertEqual(preferences.homeItemLimit, 20)
        XCTAssertEqual(preferences.refreshIntervalSeconds, 30)
        XCTAssertEqual(preferences.fontScale, 1.3)
    }

    func testCollectorUsesCustomRootAndIgnoresAppearanceChanges() async throws {
        let suite = "codexbar.tests.collectors.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let projects = directory.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let record = #"{"type":"assistant","timestamp":"2026-09-30T09:00:00Z","message":{"id":"test","role":"assistant","usage":{"input_tokens":12,"output_tokens":30}}}"#
        try Data((record + "\n").utf8).write(to: projects.appendingPathComponent("test.jsonl"))
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update {
            $0.disabledTools = ["cursor", "openCode", "deepSeekHarness"]
            $0.customDataDirectories["claudeCode"] = directory.path
        }
        let quotaFetcher = PreferencesFixtureQuotaFetcher()
        let tools = ToolUsageStore(quotaFetcher: quotaFetcher, cacheURL: directory.appendingPathComponent("cache.json"), preferencesStore: preferences)
        tools.refreshIfNeeded(force: true, now: Date(timeIntervalSince1970: 1790812800))
        for _ in 0..<200 where tools.isRefreshing || tools.isRefreshingQuotas { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(tools.isRefreshing)
        XCTAssertFalse(tools.isRefreshingQuotas)
        XCTAssertEqual(tools.snapshot(for: .claudeCode).dailyEntries.first?.totalTokens, 42)
        XCTAssertNil(tools.snapshots[.cursor])
        XCTAssertNil(tools.snapshots[.openCode])
        let quotaCallsBeforePresentationChanges = await quotaFetcher.callCount
        preferences.update { $0.backgroundOpacity = 0.7 }
        preferences.toggleManagementToolCollapsed("codex")
        preferences.moveManagementTool("claudeCode", by: -1)
        await Task.yield()
        XCTAssertFalse(tools.isRefreshing, "Appearance changes must not launch collectors or remote requests")
        XCTAssertFalse(tools.isRefreshingQuotas, "管理列表排序或折叠不得重新读取额度")
        let quotaCallsAfterPresentationChanges = await quotaFetcher.callCount
        XCTAssertEqual(quotaCallsAfterPresentationChanges, quotaCallsBeforePresentationChanges)
    }

    func testUsageExportWritesOnlyDailyMetadataAndNeverOverwritesEarlierExport() throws {
        let suite = "codexbar.tests.export.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ApplicationPreferencesStore(defaults: defaults)
        store.update { $0.scheduledExportDirectory = directory.path }
        let service = ScheduledUsageExportService(preferencesStore: store, makeSnapshot: {
            ScheduledUsageExport(exportedAt: Date(timeIntervalSince1970: 1000), sources: [
                .init(tool: "codex", dailyEntries: [.init(date: Date(timeIntervalSince1970: 0), totalTokens: 420, costUSD: 1.2)])
            ])
        })
        let first = try XCTUnwrap(service.exportNow())
        let second = try XCTUnwrap(service.exportNow())
        XCTAssertNotEqual(first, second)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "exportedAt", "sources"]))
        let source = try XCTUnwrap((object["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(source.keys), Set(["tool", "dailyEntries"]))
        let entry = try XCTUnwrap((source["dailyEntries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["totalTokens"] as? Int, 420)
        XCTAssertFalse(entry.keys.contains("sessionTitle"))
        XCTAssertFalse(entry.keys.contains("projectPath"))
        XCTAssertNil(service.errorMessage)
    }
}

private actor PreferencesFixtureQuotaFetcher: ToolQuotaFetching {
    private(set) var callCount = 0

    func fetch(client: ToolUsageClient, preferences: ApplicationPreferences, now: Date) async -> ToolQuotaSnapshot {
        self.callCount += 1
        return ToolQuotaSnapshot(client: client, status: .notConfigured, providerName: client.displayName,
                                 refreshedAt: now, statusDetail: "偏好测试使用隔离额度数据")
    }
}
