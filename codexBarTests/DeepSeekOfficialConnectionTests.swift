import Foundation
import XCTest
@testable import codexbar

@MainActor
final class DeepSeekOfficialConnectionTests: XCTestCase {
    func testExplicitOfficialConnectionReusesPrivateDSHKeyAndPersistsLiveSelection() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        let file = try self.writeKey(home: home)
        let original = try Data(contentsOf: file)
        let transport = OfficialBalanceFixtureTransport(statuses: [200, 503, 200])
        let store = self.store(home: home, transport: transport)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertNil(store.selectedProfile(for: .deepSeekHarness))
        try await store.connectExistingDSHOfficialAccount(preferences: ApplicationPreferences(), officialAccountConfirmed: true)
        let id = try XCTUnwrap(store.selectedProfile(for: .deepSeekHarness)?.id)
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.providerKind, .dshOfficialAPI)
        XCTAssertFalse(store.selectedProfile(for: .deepSeekHarness)?.isAutomatic ?? true)
        let first = try XCTUnwrap(store.selectedQuota(for: .deepSeekHarness))
        XCTAssertEqual(first.balance?.amount, 9.5)
        XCTAssertEqual(first.status, .ready)
        XCTAssertFalse(first.isLocalSnapshot)

        // A failed refresh is an attempt, not a new observation of the balance.
        await store.refresh(profileID: id, force: true, now: Date(timeIntervalSinceNow: 60))
        XCTAssertEqual(store.selectedQuota(for: .deepSeekHarness)?.status, .failed)
        XCTAssertEqual(store.selectedQuota(for: .deepSeekHarness)?.balance, first.balance)
        XCTAssertEqual(store.selectedQuota(for: .deepSeekHarness)?.refreshedAt, first.refreshedAt)
        XCTAssertTrue(store.selectedQuota(for: .deepSeekHarness)?.statusDetail.contains("上次成功") ?? false)
        let restored = self.store(home: home, transport: transport)
        XCTAssertEqual(restored.selectedProfile(for: .deepSeekHarness)?.id, id)
        XCTAssertEqual(restored.selectedQuota(for: .deepSeekHarness)?.refreshedAt, first.refreshedAt)
        let next = Date(timeIntervalSinceNow: 120)
        await restored.refresh(profileID: id, force: true, now: next)
        XCTAssertEqual(restored.selectedQuota(for: .deepSeekHarness)?.status, .ready)
        XCTAssertEqual(restored.selectedQuota(for: .deepSeekHarness)?.refreshedAt, next)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.url?.absoluteString == "https://api.deepseek.com/user/balance" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer official-fixture" })
        XCTAssertEqual(try Data(contentsOf: file), original)
        for name in ["connections.json", "quota-cache.json"] {
            let text = String(decoding: try Data(contentsOf: home.appendingPathComponent(".codexbar/tool-connections/" + name)), as: UTF8.self)
            XCTAssertFalse(text.contains("official-fixture"))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".codexbar/tool-connections/credentials.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testConfirmationPrivateFileAndAuthenticationAreRequiredBeforeSaving() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        let file = try self.writeKey(home: home)
        let transport = OfficialBalanceFixtureTransport(statuses: [401])
        let store = self.store(home: home, transport: transport)
        do {
            try await store.connectExistingDSHOfficialAccount(preferences: ApplicationPreferences())
            XCTFail("Explicit official-account confirmation required")
        } catch { XCTAssertEqual(error as? ToolConnectionError, .officialAccountConfirmationRequired) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        do {
            try await store.connectExistingDSHOfficialAccount(preferences: ApplicationPreferences(), officialAccountConfirmed: true)
            XCTFail("Public credential file must not be imported")
        } catch { XCTAssertEqual(error as? ToolConnectionError, .invalidCredential) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do {
            try await store.connectExistingDSHOfficialAccount(preferences: ApplicationPreferences(), officialAccountConfirmed: true)
            XCTFail("Invalid official key must not be saved")
        } catch { XCTAssertEqual(error as? ToolConnectionError, .authenticationRequired) }
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codexbar/tool-connections/credentials.json").path))
    }

    func testLostAutomaticBindingPreservesLastSuccessfulBalanceWithoutSendingAnotherRequest() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        _ = try self.writeKey(home: home)
        let transport = OfficialBalanceFixtureTransport(statuses: [200])
        let environment = ["DEEPSEEK_BASE_URL": "https://api.deepseek.com"]
        let store = ToolConnectionStore(directory: home.appendingPathComponent(".codexbar/tool-connections"), home: home,
            environment: environment, transport: transport)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        let id = try XCTUnwrap(store.selectedProfile(for: .deepSeekHarness)?.id)
        await store.refresh(profileID: id, force: true)
        let successful = try XCTUnwrap(store.quota(for: id))
        XCTAssertEqual(successful.status, .ready)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".dsh/.credentials.yaml"))
        await store.refresh(profileID: id, force: true, now: Date(timeIntervalSinceNow: 60))
        XCTAssertEqual(store.quota(for: id)?.status, .failed)
        XCTAssertEqual(store.quota(for: id)?.balance, successful.balance)
        XCTAssertEqual(store.quota(for: id)?.refreshedAt, successful.refreshedAt)
        let restored = self.store(home: home, transport: transport)
        XCTAssertEqual(restored.quota(for: id), store.quota(for: id))
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testConnectedOfficialAccountKeepsSnapshotDiscoveryCurrentWithoutChangingSelection() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        _ = try self.writeKey(home: home)
        let file = home.appendingPathComponent(".dsh/dsh-usage/provider-snapshots.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"providers":{"old":{"provider":"deepseek","credential":"env","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100000}}}}"#.utf8).write(to: file)
        let transport = OfficialBalanceFixtureTransport(statuses: [200, 200])
        let store = self.store(home: home, transport: transport)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        let obsolete = try XCTUnwrap(store.profiles.first?.id)
        try await store.connectExistingDSHOfficialAccount(preferences: ApplicationPreferences(), officialAccountConfirmed: true)
        let selected = try XCTUnwrap(store.selectedProfile(for: .deepSeekHarness)?.id)
        try Data(#"{"providers":{"new":{"provider":"deepseek-official","credential":"env","balance":{"totalBalance":7,"currency":"CNY","updatedAt":200000}}}}"#.utf8).write(to: file)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, selected)
        XCTAssertFalse(store.profiles.contains { $0.id == obsolete })
        let snapshot = try XCTUnwrap(store.profiles.first { $0.providerKind == .dshSnapshot })
        await store.refresh(force: true)
        XCTAssertEqual(store.quota(for: snapshot.id)?.balance?.amount, 7)
        XCTAssertEqual(store.selectedQuota(for: .deepSeekHarness)?.balance?.amount, 9.5)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.deepseek.com" })
    }

    /// Deliberate real-account verification only; normal runs never access the operator's DSH key.
    func testOptInOfficialAccountConnectionWitness() async throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_VERIFY_DSH_OFFICIAL_ACCOUNT"] == "1" else {
            throw XCTSkip("Requires explicit official-account authorization and an opted-in local run")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let store = ToolConnectionStore(home: home, environment: [:], keychainReader: { nil })
        try await store.connectExistingDSHOfficialAccount(preferences: ApplicationPreferences(), officialAccountConfirmed: true)
        let first = try XCTUnwrap(store.selectedQuota(for: .deepSeekHarness))
        XCTAssertEqual(first.status, .ready)
        XCTAssertFalse(first.isLocalSnapshot)
        let id = try XCTUnwrap(store.selectedProfile(for: .deepSeekHarness)?.id)
        await store.refresh(profileID: id, force: true)
        let refreshed = try XCTUnwrap(store.selectedQuota(for: .deepSeekHarness))
        XCTAssertEqual(refreshed.status, .ready)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(refreshed.refreshedAt), try XCTUnwrap(first.refreshedAt))
        print("DeepSeek official witness: live connection and manual refresh succeeded")
    }

    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-official-connection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
    private func writeKey(home: URL) throws -> URL {
        let root = home.appendingPathComponent(".dsh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(".credentials.yaml")
        try Data("version: 1\nrefs:\n  DEEPSEEK_API_KEY: official-fixture\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
    private func store(home: URL, transport: OfficialBalanceFixtureTransport) -> ToolConnectionStore {
        ToolConnectionStore(directory: home.appendingPathComponent(".codexbar/tool-connections"), home: home,
            environment: [:], transport: transport)
    }
}

private actor OfficialBalanceFixtureTransport: CursorUsageHTTPTransport {
    private var statuses: [Int]
    private(set) var requests: [URLRequest] = []
    init(statuses: [Int]) { self.statuses = statuses }
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        guard !self.statuses.isEmpty else { throw URLError(.cannotConnectToHost) }
        let status = self.statuses.removeFirst()
        let body = status == 200 ? #"{"balance_infos":[{"currency":"CNY","total_balance":"9.5"}]}"# : ""
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
