import Foundation
import XCTest

@MainActor
final class ApplicationPreferencesTests: CodexBarTestCase {
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

    func testUnknownAndDuplicatePagesCannotRemoveHomeOrCreateBrokenNavigation() throws {
        let data = Data(#"{"pageOrder":["models","unknown","models"],"hiddenPages":["home","models"],"homeItemLimit":999,"refreshIntervalSeconds":0,"fontScale":9}"#.utf8)
        let preferences = try JSONDecoder().decode(ApplicationPreferences.self, from: data)
        XCTAssertEqual(preferences.pageOrder.first, "models")
        XCTAssertEqual(Set(preferences.pageOrder), Set(ApplicationPreferences.allPages))
        XCTAssertEqual(preferences.pageOrder.count, ApplicationPreferences.allPages.count)
        XCTAssertTrue(preferences.visiblePages.contains("home"))
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
        let tools = ToolUsageStore(cacheURL: directory.appendingPathComponent("cache.json"), preferencesStore: preferences)
        tools.refreshIfNeeded(force: true, now: Date(timeIntervalSince1970: 1790812800))
        for _ in 0..<200 where tools.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(tools.isRefreshing)
        XCTAssertEqual(tools.snapshot(for: .claudeCode).dailyEntries.first?.totalTokens, 42)
        XCTAssertNil(tools.snapshots[.cursor])
        XCTAssertNil(tools.snapshots[.openCode])
        preferences.update { $0.backgroundOpacity = 0.7 }
        await Task.yield()
        XCTAssertFalse(tools.isRefreshing, "Appearance changes must not launch collectors or remote requests")
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
