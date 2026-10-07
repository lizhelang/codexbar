import Foundation
import SQLite3
import XCTest
@testable import codexbar

@MainActor
final class CursorAccountStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testVerifiedManualAccountsDeduplicateByUserIDAndKeepSecretsOutOfMetadataAndCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let first = "user_first%3A%3Aaa.bb.cc"
        let rotated = "user_first%3A%3Add.ee.ff"
        let id = try await store.addAccount(sessionCookie: first, alias: "工作", now: self.now)
        try await store.replaceCredential(accountID: id, sessionCookie: rotated, now: self.now.addingTimeInterval(5))
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.alias, "工作")
        XCTAssertEqual(store.accounts.first?.createdAt, self.now)
        XCTAssertEqual(store.selectedAccountID, id)
        let credential = fixture.root.appendingPathComponent("credentials/\(id).json")
        XCTAssertTrue(String(decoding: try Data(contentsOf: credential), as: UTF8.self).contains(rotated))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: credential.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for path in ["accounts.json", "snapshots/\(id).json"] {
            let text = String(decoding: try Data(contentsOf: fixture.root.appendingPathComponent(path)), as: UTF8.self)
            XCTAssertFalse(text.contains(first))
            XCTAssertFalse(text.contains(rotated))
            XCTAssertFalse(text.contains("sessionCookie"))
        }
        let restored = fixture.store()
        XCTAssertEqual(restored.accounts, store.accounts)
        XCTAssertEqual(restored.states, store.states)
        XCTAssertEqual(restored.selectedAccountID, id)
        let calls = await fixture.service.probeCalls
        XCTAssertEqual(calls, 2, "Initialization only reads identity metadata and cached states")
    }

    func testValidationFailureAndDifferentIdentityCredentialReplacementDoNotSave() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        await fixture.service.failProbe(.authenticationRequired)
        do { _ = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc") ; XCTFail("Failed validation must not add an account") }
        catch { XCTAssertEqual(error as? CursorAccountError, .authenticationRequired) }
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        await fixture.service.failProbe(nil)
        let id = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc")
        do { try await store.replaceCredential(accountID: id, sessionCookie: "user_second%3A%3Add.ee.ff") ; XCTFail("Cannot replace account with another identity") }
        catch { XCTAssertEqual(error as? CursorAccountError, .identityMismatch) }
        XCTAssertEqual(store.accounts.map(\.id), [id])
    }

    func testDesktopDiscoveryIsReadOnlyDoesNotReplaceSelectionAndKeepsPauseChoice() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeDesktopSession("user_desktop%3A%3Aaa.bb.cc")
        let before = try Data(contentsOf: fixture.database)
        let store = fixture.store()
        let manual = try await store.addAccount(sessionCookie: "user_manual%3A%3Add.ee.ff", now: self.now)
        await store.discoverDesktopAccount(force: true, now: self.now)
        XCTAssertEqual(store.desktopAccountID, "user_desktop")
        XCTAssertEqual(store.selectedAccountID, manual)
        XCTAssertEqual(store.accounts.first(where: { $0.id == "user_desktop" })?.source, .desktop)
        XCTAssertEqual(try Data(contentsOf: fixture.database), before, "Cursor desktop DB must remain unchanged")
        XCTAssertThrowsError(try store.removeAccount("user_desktop")) { error in
            XCTAssertEqual(error as? CursorAccountError, .desktopAccountCannotBeRemoved)
        }
        try store.setPaused("user_desktop", paused: true)
        let calls = await fixture.service.probeCalls
        await store.discoverDesktopAccount(force: true, now: self.now.addingTimeInterval(10))
        let pausedCalls = await fixture.service.probeCalls
        XCTAssertEqual(pausedCalls, calls)
        XCTAssertTrue(store.accounts.first(where: { $0.id == "user_desktop" })?.isPaused == true)
        XCTAssertEqual(try Data(contentsOf: fixture.database), before)
    }

    func testPerAccountUsageImportRefreshAndRestartNeverBorrowAnotherAccountCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let first = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc")
        let second = try await store.addAccount(sessionCookie: "user_second%3A%3Add.ee.ff")
        try store.importUsage(self.usage(tokens: 37), accountID: first)
        try store.importUsage(self.usage(tokens: 83), accountID: second)
        try store.selectAccount(second)
        try store.renameAccount(first, alias: "个人")
        let restored = fixture.store()
        XCTAssertEqual(restored.selectedAccountID, second)
        XCTAssertEqual(restored.states[first]?.usage?.dailyEntries.first?.totalTokens, 37)
        XCTAssertEqual(restored.states[second]?.usage?.dailyEntries.first?.totalTokens, 83)
        XCTAssertEqual(restored.accounts.first?.alias, "个人")
        await fixture.service.setUsage(tokens: 101, id: first)
        await store.refreshAccount(first, force: true, now: self.now)
        XCTAssertEqual(store.states[first]?.usage?.dailyEntries.first?.totalTokens, 101)
        XCTAssertEqual(store.states[second]?.usage?.dailyEntries.first?.totalTokens, 83)
        XCTAssertEqual(store.selectedAccountID, second)
    }

    func testFailedAndEmptyRefreshKeepOnlyThatAccountsHistoryAndMarkFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let id = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc")
        try store.importUsage(self.usage(tokens: 37), accountID: id)
        await fixture.service.failUsage(.networkFailure)
        await store.refreshAccount(id, force: true, now: self.now)
        XCTAssertEqual(store.states[id]?.status, .failed)
        XCTAssertEqual(store.states[id]?.usage?.availability, .failed)
        XCTAssertEqual(store.states[id]?.usage?.dailyEntries.first?.totalTokens, 37)
        XCTAssertEqual(store.states[id]?.quota?.status, .ready)
        await fixture.service.failUsage(nil)
        await fixture.service.setUsage(tokens: 0, id: id)
        await store.refreshAccount(id, force: true, now: self.now.addingTimeInterval(1))
        XCTAssertEqual(store.states[id]?.status, .ready)
        XCTAssertEqual(store.states[id]?.usage?.availability, .partial)
        XCTAssertEqual(store.states[id]?.usage?.dailyEntries.first?.totalTokens, 37)
        XCTAssertTrue(store.states[id]?.statusDetail?.contains("保留该账号") == true)
    }

    func testForceThrottleAndClientOrAccountPausePreventNewRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let id = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc")
        await store.refreshAccount(id, now: self.now)
        await store.refreshAccount(id, now: self.now.addingTimeInterval(1))
        let throttled = await fixture.service.usageCalls
        XCTAssertEqual(throttled, 1)
        await store.refreshAccount(id, force: true, now: self.now.addingTimeInterval(2))
        let forced = await fixture.service.usageCalls
        XCTAssertEqual(forced, 2)
        try store.setPaused(id, paused: true)
        await store.refreshAll(force: true, now: self.now.addingTimeInterval(3))
        let paused = await fixture.service.usageCalls
        XCTAssertEqual(paused, 2)
        try store.setPaused(id, paused: false)
        fixture.preferences.update { $0.disabledTools.append("cursor") }
        await store.discoverDesktopAccount(force: true)
        await store.refreshAll(force: true)
        XCTAssertFalse(store.isCollectionEnabled)
        XCTAssertEqual(store.states[id]?.status, .paused)
        let globallyPaused = await fixture.service.usageCalls
        XCTAssertEqual(globallyPaused, 2)
        XCTAssertNotNil(store.states[id]?.usage)
    }

    func testExpiredProbeRetainsOwnWindowsButMarksQuotaAndHistoryAsFailed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let id = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc", now: self.now)
        try store.importUsage(self.usage(tokens: 37), accountID: id)
        let originalQuota = store.states[id]?.quota
        await fixture.service.failProbe(.authenticationRequired)
        await store.refreshAccount(id, force: true, now: self.now.addingTimeInterval(60))
        XCTAssertEqual(store.states[id]?.status, .authenticationRequired)
        XCTAssertEqual(store.states[id]?.quota?.status, .authenticationRequired)
        XCTAssertEqual(store.states[id]?.quota?.windows, originalQuota?.windows)
        XCTAssertEqual(store.states[id]?.quota?.refreshedAt, originalQuota?.refreshedAt)
        XCTAssertEqual(store.states[id]?.usage?.dailyEntries.first?.totalTokens, 37)
        XCTAssertEqual(store.states[id]?.usage?.availability, .failed)
    }

    func testDeletedAccountRejectsLateUsageAndDeletesCredentialAndSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let id = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc")
        await fixture.service.holdUsage()
        let refresh = Task { await store.refreshAccount(id, force: true, now: self.now) }
        await self.waitForHeldUsage(fixture.service)
        try store.removeAccount(id)
        await fixture.service.releaseUsage()
        await refresh.value
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.states[id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("credentials/\(id).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("snapshots/\(id).json").path))
        XCTAssertTrue(fixture.store().accounts.isEmpty)
    }

    func testPauseRejectsLateUsageAndDoesNotReplaceRetainedHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let id = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc")
        try store.importUsage(self.usage(tokens: 37), accountID: id)
        await fixture.service.holdUsage()
        let refresh = Task { await store.refreshAccount(id, force: true, now: self.now) }
        await self.waitForHeldUsage(fixture.service)
        try store.setPaused(id, paused: true)
        await fixture.service.releaseUsage()
        await refresh.value
        XCTAssertEqual(store.states[id]?.status, .paused)
        XCTAssertEqual(store.states[id]?.usage?.dailyEntries.first?.totalTokens, 37)
        XCTAssertEqual(fixture.store().states[id]?.usage?.dailyEntries.first?.totalTokens, 37)
    }

    func testCredentialReplacementRejectsOldInFlightResultAndKeepsAlias() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let id = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc", alias: "工作")
        try store.importUsage(self.usage(tokens: 37), accountID: id)
        await fixture.service.holdUsage()
        let refresh = Task { await store.refreshAccount(id, force: true, now: self.now) }
        await self.waitForHeldUsage(fixture.service)
        try await store.replaceCredential(accountID: id, sessionCookie: "user_first%3A%3Add.ee.ff")
        await fixture.service.releaseUsage()
        await refresh.value
        XCTAssertEqual(store.states[id]?.usage?.dailyEntries.first?.totalTokens, 37)
        XCTAssertEqual(store.accounts.first?.alias, "工作")
        XCTAssertFalse(store.isRefreshing)
    }

    func testGlobalPauseRejectsLateUsageAndKeepsHistoryWithoutNewNetworkRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let id = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc")
        try store.importUsage(self.usage(tokens: 37), accountID: id)
        await fixture.service.holdUsage()
        let refresh = Task { await store.refreshAccount(id, force: true, now: self.now) }
        await self.waitForHeldUsage(fixture.service)
        fixture.preferences.update { $0.disabledTools.append("cursor") }
        await fixture.service.releaseUsage()
        await refresh.value
        XCTAssertEqual(store.states[id]?.status, .paused)
        XCTAssertEqual(store.states[id]?.usage?.dailyEntries.first?.totalTokens, 37)
        await store.refreshAll(force: true)
        let calls = await fixture.service.usageCalls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    func testSymlinkedStorageRootIsRejectedWithoutWritingCredentialsOutsideRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outside = fixture.folder.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: outside)
        let store = fixture.store()
        do { _ = try await store.addAccount(sessionCookie: "user_first%3A%3Aaa.bb.cc"); XCTFail("Owned account root must not be a symbolic link") }
        catch { XCTAssertEqual(error as? CursorAccountError, .storageFailure) }
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testUnsafeCredentialAliasAndImportedEchoAreExcludedFromOrdinaryFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let cookie = "user_first%3A%3Aaa.bb.cc"
        let id = try await store.addAccount(sessionCookie: cookie)
        XCTAssertThrowsError(try store.renameAccount(id, alias: cookie))
        let usage = ToolUsageSnapshot(client: .cursor, availability: .ready, usageRecords: [.init(id: cookie, timestamp: self.now, modelID: cookie, totalTokens: 1)], statusDetail: cookie)
        try store.importUsage(usage, accountID: id)
        XCTAssertNil(store.states[id]?.usage?.statusDetail)
        XCTAssertNil(store.states[id]?.usage?.usageRecords.first?.modelID)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.root.appendingPathComponent("snapshots/\(id).json")), as: UTF8.self).contains(cookie))
    }

    private func usage(tokens: Int) -> ToolUsageSnapshot {
        ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .imported,
            dailyEntries: [.init(date: self.now, totalTokens: tokens)], refreshedAt: self.now)
    }

    private func waitForHeldUsage(_ service: StoreServiceFixture) async {
        let deadline = Date().addingTimeInterval(3)
        while !(await service.isHoldingUsage), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let held = await service.isHoldingUsage
        XCTAssertTrue(held, "Isolated usage query did not reach fixture gate")
    }
}

@MainActor
private struct Fixture {
    let folder: URL
    let defaults: UserDefaults
    let suite: String
    let preferences: ApplicationPreferencesStore
    let service = StoreServiceFixture()
    var root: URL { self.folder.appendingPathComponent("accounts", isDirectory: true) }
    var database: URL { self.folder.appendingPathComponent("state.vscdb") }

    init() throws {
        self.folder = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-cursor-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        self.suite = "codexbar.cursor-account-tests." + UUID().uuidString
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.suite))
        self.preferences = ApplicationPreferencesStore(defaults: self.defaults)
    }
    func store() -> CursorAccountStore {
        CursorAccountStore(rootURL: self.root, service: self.service, sessionReader: CursorDesktopSessionReader(databaseURL: self.database),
                           preferencesStore: self.preferences, refreshInterval: 60)
    }
    func cleanUp() {
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.folder)
    }
    func writeDesktopSession(_ cookie: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(self.database.path, &database) == SQLITE_OK, let database else { throw CursorUsageSyncError.unreadableDesktopSession }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil) == SQLITE_OK else {
            throw CursorUsageSyncError.unreadableDesktopSession
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO ItemTable(key,value) VALUES ('cursorAuth/accessToken',?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CursorUsageSyncError.unreadableDesktopSession }
        defer { sqlite3_finalize(statement) }
        let bound = cookie.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw CursorUsageSyncError.unreadableDesktopSession }
    }
}

private actor StoreServiceFixture {
    private var probeFailure: CursorAccountError?
    private var usageFailure: CursorAccountError?
    private var usages: [String: Int] = [:]
    private var shouldHoldUsage = false
    private var usageGate: CheckedContinuation<Void, Never>?
    private(set) var probeCalls = 0
    private(set) var usageCalls = 0
    var isHoldingUsage: Bool { self.usageGate != nil }

    func failProbe(_ error: CursorAccountError?) { self.probeFailure = error }
    func failUsage(_ error: CursorAccountError?) { self.usageFailure = error }
    func setUsage(tokens: Int, id: String) { self.usages[id] = tokens }
    func holdUsage() { self.shouldHoldUsage = true }
    func releaseUsage() { self.shouldHoldUsage = false; self.usageGate?.resume(); self.usageGate = nil }
    func probe(sessionCookie: String, now: Date) async throws -> CursorAccountProbe {
        self.probeCalls += 1
        if let failure = self.probeFailure { throw failure }
        let id = try CursorAccountService.userID(sessionCookie: sessionCookie)
        return CursorAccountProbe(identity: .init(userID: id, email: "shared@example.test", planType: "pro"),
            quota: .init(client: .cursor, status: .ready, providerName: "Cursor", windows: [.init(id: "auto", label: "Cursor 模型", usedPercent: 20)],
                         refreshedAt: now, statusDetail: "Fixture quota"))
    }
    func usage(sessionCookie: String, now: Date, calendar: Calendar) async throws -> ToolUsageSnapshot {
        self.usageCalls += 1
        if self.shouldHoldUsage { await withCheckedContinuation { self.usageGate = $0 } }
        if let failure = self.usageFailure { throw failure }
        let id = try CursorAccountService.userID(sessionCookie: sessionCookie)
        let tokens = self.usages[id] ?? 10
        return ToolUsageSnapshot(client: .cursor, availability: tokens == 0 ? .noRecords : .ready, evidence: .server,
            dailyEntries: tokens == 0 ? [] : [.init(date: calendar.startOfDay(for: now), totalTokens: tokens)], refreshedAt: now)
    }
}

// Keep the conformance on an extension: this Swift toolchain otherwise infers
// the protocol's nonisolated modifier onto the actor declaration itself.
extension StoreServiceFixture: CursorAccountServicing {}
