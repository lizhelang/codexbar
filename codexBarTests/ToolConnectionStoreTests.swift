import Foundation
import XCTest
@testable import codexbar

@MainActor
final class ToolConnectionStoreTests: XCTestCase {
    func testMultipleProfilesKeepIndependentQuotaAndSecretFreeMetadataAcrossReload() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let store = ToolConnectionStore(directory: directory, service: service)
        try await store.saveOpenCodeProfile(label: "First", apiKey: "fixture-secret-one")
        let first = try XCTUnwrap(store.profiles.first)
        try await store.saveOpenCodeProfile(label: "Second", apiKey: "fixture-secret-two")
        let second = try XCTUnwrap(store.profiles.last)
        XCTAssertEqual(store.quota(for: first.id)?.balance?.amount, 1)
        XCTAssertEqual(store.quota(for: second.id)?.balance?.amount, 2)
        try store.select(first.id)
        for name in ["connections.json", "quota-cache.json"] {
            let text = String(decoding: try Data(contentsOf: directory.appendingPathComponent(name)), as: UTF8.self)
            XCTAssertFalse(text.contains("fixture-secret"))
            XCTAssertFalse(text.contains("apiKey"))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("credentials.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let restored = ToolConnectionStore(directory: directory, service: service)
        XCTAssertEqual(restored.profiles, store.profiles)
        XCTAssertEqual(restored.selectedProfile(for: .openCode)?.id, first.id)
        XCTAssertEqual(restored.quota(for: second.id)?.balance?.amount, 2)
    }

    func testOpenCodeSameAccountConfirmationIncludesExistingKeyAndNewCookie() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolConnectionStore(directory: directory, service: ConnectionStoreFixtureService())
        try await store.saveOpenCodeProfile(label: "First", apiKey: "fixture-secret-one")
        let id = try XCTUnwrap(store.profiles.first?.id)
        do { try await store.saveOpenCodeProfile(label: "First", cookie: "auth=fixture-cookie", profileID: id); XCTFail("Confirmation required") }
        catch { XCTAssertEqual(error as? ToolConnectionError, .sameAccountConfirmationRequired) }
        try await store.saveOpenCodeProfile(label: "First", cookie: "auth=fixture-cookie", profileID: id, confirmedSameAccount: true)
        XCTAssertTrue(store.profiles[0].hasAPIKey && store.profiles[0].hasCookie)
        // Blank editing fields keep credentials; explicit removeCredential clears them.
        try await store.saveOpenCodeProfile(label: "Renamed", apiKey: "", cookie: "", profileID: id)
        XCTAssertTrue(store.profiles[0].hasAPIKey && store.profiles[0].hasCookie)
        try store.removeCredential(id, kind: .cookie)
        XCTAssertTrue(store.profiles[0].hasAPIKey)
        XCTAssertFalse(store.profiles[0].hasCookie)
    }

    func testDisabledProfileRetainsCredentialOwnershipAndOrderingSurvivesReload() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let store = ToolConnectionStore(directory: directory, service: service)
        try await store.saveOpenCodeProfile(label: "First", apiKey: "fixture-secret-one")
        let first = store.profiles[0].id
        try store.setEnabled(first, enabled: false)
        do { try await store.saveOpenCodeProfile(label: "Duplicate", apiKey: "fixture-secret-one"); XCTFail("Ownership retained") }
        catch { XCTAssertEqual(error as? ToolConnectionError, .duplicateCredential) }
        try await store.saveOpenCodeProfile(label: "Second", apiKey: "fixture-secret-two")
        let second = store.profiles[1].id
        try store.move(second, by: -1)
        try store.rename(second, label: "Second renamed")
        let restored = ToolConnectionStore(directory: directory, service: service)
        XCTAssertEqual(restored.profiles.map(\.id), [second, first])
        XCTAssertFalse(restored.profiles[1].isEnabled)
        XCTAssertEqual(restored.profiles[0].label, "Second renamed")
    }

    func testTransferCredentialRequiresConfirmationAndDoesNotOverwrite() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolConnectionStore(directory: directory, service: ConnectionStoreFixtureService())
        try await store.saveOpenCodeProfile(label: "Key", apiKey: "fixture-secret-one")
        try await store.saveOpenCodeProfile(label: "Cookie", cookie: "auth=fixture-cookie")
        let from = store.profiles[0].id, to = store.profiles[1].id
        XCTAssertThrowsError(try store.transferCredential(from: from, to: to, kind: .apiKey)) {
            XCTAssertEqual($0 as? ToolConnectionError, .sameAccountConfirmationRequired)
        }
        try store.transferCredential(from: from, to: to, kind: .apiKey, confirmedSameAccount: true)
        XCTAssertFalse(store.profiles[0].hasAPIKey)
        XCTAssertTrue(store.profiles[1].hasAPIKey && store.profiles[1].hasCookie)
        XCTAssertNil(store.quota(for: from)); XCTAssertNil(store.quota(for: to))
        try await store.saveOpenCodeProfile(label: "Other", apiKey: "fixture-secret-two")
        XCTAssertThrowsError(try store.transferCredential(from: store.profiles[2].id, to: to, kind: .apiKey, confirmedSameAccount: true))
    }

    func testDeletionAndGlobalPauseRejectLateRefreshAndThrottleWithoutQueryingPausedProfile() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "codexbar-connection-prefs-\(UUID().uuidString)")!
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        let service = ConnectionStoreFixtureService()
        let store = ToolConnectionStore(directory: directory, service: service, preferencesStore: preferences)
        try await store.saveOpenCodeProfile(label: "First", apiKey: "fixture-secret-one")
        let id = store.profiles[0].id
        let before = await service.queryCount()
        await store.refresh()
        let throttled = await service.queryCount(); XCTAssertEqual(throttled, before)
        await service.blockNext(1)
        let refresh = Task { await store.refresh(profileID: id, force: true) }
        await service.waitUntilBlocked(1)
        preferences.update { $0.disabledTools.append("openCode") }
        await service.release()
        await refresh.value
        let paused = await service.queryCount()
        await store.refresh(force: true)
        let afterPause = await service.queryCount(); XCTAssertEqual(paused, afterPause)
        preferences.update { $0.disabledTools.removeAll { $0 == "openCode" } }
        await service.blockNext(1)
        let deletedRefresh = Task { await store.refresh(profileID: id, force: true) }
        await service.waitUntilBlocked(1)
        try store.remove(id)
        await service.release(); await deletedRefresh.value
        XCTAssertTrue(store.profiles.isEmpty); XCTAssertNil(store.quota(for: id))
    }

    func testConcurrentSavesCannotBindSameCredentialToTwoProfiles() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let store = ToolConnectionStore(directory: directory, service: service)
        await service.blockNext(2)
        let first = Task { try await store.saveOpenCodeProfile(label: "First", apiKey: "fixture-secret-one") }
        let second = Task { try await store.saveOpenCodeProfile(label: "Second", apiKey: "fixture-secret-one") }
        await service.waitUntilBlocked(2); await service.release()
        var succeeded = 0, rejected = 0
        for task in [first, second] {
            do { try await task.value; succeeded += 1 }
            catch { XCTAssertEqual(error as? ToolConnectionError, .duplicateCredential); rejected += 1 }
        }
        XCTAssertEqual(succeeded, 1); XCTAssertEqual(rejected, 1); XCTAssertEqual(store.profiles.count, 1)
    }

    func testExplicitClaudeWebWinsDiscoveryAndOrganizationSelectionNeverDefaultsToFirst() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let store = ToolConnectionStore(directory: directory, service: service)
        _ = try await store.loadClaudeOrganizations(sessionKey: "sk-ant-fixture")
        do { try await store.saveClaudeSession(sessionKey: "sk-ant-fixture"); XCTFail("Choice required") }
        catch { XCTAssertEqual(error as? ToolConnectionError, .organizationSelectionRequired) }
        try await store.saveClaudeSession(sessionKey: "sk-ant-fixture", organizationID: "org-two")
        await store.discover(client: .claudeCode, preferences: ApplicationPreferences())
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertFalse(store.profiles[0].isAutomatic)
        XCTAssertEqual(store.profiles[0].organizationID, "org-two")
        let secret = String(decoding: try Data(contentsOf: directory.appendingPathComponent("credentials.json")), as: UTF8.self)
        XCTAssertTrue(secret.contains("sk-ant-rotated"))
        let metadata = String(decoding: try Data(contentsOf: directory.appendingPathComponent("connections.json")), as: UTF8.self)
        XCTAssertFalse(metadata.contains("sk-ant-"))
    }

    func testPausedAutomaticGoBindingDoesNotCreateDuplicateAndAmbientKeyChangesInvalidateRow() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        await service.setDiscoveryKey("fixture-secret-one")
        let store = ToolConnectionStore(directory: directory, service: service)
        await store.discover(client: .openCode, preferences: ApplicationPreferences())
        let id = try XCTUnwrap(store.profiles.first?.id)
        try store.setEnabled(id, enabled: false)
        await store.discover(client: .openCode, preferences: ApplicationPreferences())
        XCTAssertEqual(store.profiles.count, 1); XCTAssertFalse(store.profiles[0].isEnabled)
        await service.setDiscoveryKey("fixture-secret-two")
        await store.discover(client: .openCode, preferences: ApplicationPreferences())
        XCTAssertEqual(store.profiles.count, 1); XCTAssertNotEqual(store.profiles[0].id, id); XCTAssertNil(store.quota(for: id))
    }

    func testFailedMetadataWriteRollsBackCredentialAndReloadRejectsFingerprintMismatch() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let store = ToolConnectionStore(directory: directory, service: service)
        try await store.saveDeepSeekKey("fixture-secret-one")
        let credentialURL = directory.appendingPathComponent("credentials.json")
        let previousSecret = try Data(contentsOf: credentialURL)
        let metadataURL = directory.appendingPathComponent("connections.json")
        let previousMetadata = try Data(contentsOf: metadataURL)
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: false)
        do { try await store.saveDeepSeekKey("fixture-secret-two"); XCTFail("Write must fail") }
        catch { XCTAssertEqual(error as? ToolConnectionError, .storageFailure) }
        XCTAssertEqual(try Data(contentsOf: credentialURL), previousSecret)
        try FileManager.default.removeItem(at: metadataURL); try previousMetadata.write(to: metadataURL)
        let wrong = ["deepSeekHarness": ManagedToolCredential(apiKey: "fixture-wrong-secret")]
        try JSONEncoder().encode(wrong).write(to: credentialURL)
        let restored = ToolConnectionStore(directory: directory, service: service)
        XCTAssertNil(restored.quota(for: "deepSeekHarness"))
        let before = await service.queryCount(); await restored.refresh(force: true)
        let after = await service.queryCount(); XCTAssertEqual(before, after)
    }

    func testHiddenAutomaticDSHSourceSurvivesRediscoveryAndReloadAndRejectsLateQuota() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        await service.setDiscoveryKey("dsh-source-fixture")
        let store = ToolConnectionStore(directory: directory, service: service)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        let source = try XCTUnwrap(store.profiles(for: .deepSeekHarness).first)
        XCTAssertTrue(source.canHideAutomaticSource && source.canRemove)
        await store.refresh(force: true)
        XCTAssertNotNil(store.selectedQuota(for: .deepSeekHarness))
        await service.blockNext(1)
        let refresh = Task { await store.refresh(profileID: source.id, force: true) }
        await service.waitUntilBlocked(1)
        try store.hideAutomaticSource(source.id)
        await service.release(); await refresh.value
        XCTAssertTrue(store.profiles(for: .deepSeekHarness).isEmpty)
        XCTAssertNil(store.selectedQuota(for: .deepSeekHarness))
        XCTAssertNil(store.quota(for: source.id))
        XCTAssertEqual(store.hiddenProfiles(for: .deepSeekHarness).map(\.id), [source.id])
        let before = await service.queryCount()
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        await store.refresh(force: true)
        let after = await service.queryCount(); XCTAssertEqual(before, after)
        let restored = ToolConnectionStore(directory: directory, service: service)
        await restored.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertTrue(restored.profiles(for: .deepSeekHarness).isEmpty)
        XCTAssertEqual(restored.hiddenProfiles(for: .deepSeekHarness).map(\.id), [source.id])
        try restored.restoreAutomaticSource(source.id)
        await restored.refresh(force: true)
        XCTAssertEqual(restored.profiles(for: .deepSeekHarness).map(\.id), [source.id])
        XCTAssertNotNil(restored.selectedQuota(for: .deepSeekHarness))
        // The generic remove action means hide for automatic DSH sources.
        try restored.remove(source.id)
        XCTAssertEqual(restored.hiddenProfiles(for: .deepSeekHarness).map(\.id), [source.id])
    }

    func testDSHSourceDeduplicationAndHideNeverModifyOriginalSnapshotAndOldMetadataLoads() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("fixture-home")
        let snapshot = home.appendingPathComponent(".dsh/dsh-usage/provider-snapshots.json")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = Data(#"{"providers":{"old":{"provider":"deepseek","credential":"same-account","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100000}},"new":{"provider":"deepseek-official","credential":"same-account","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100333}}}}"#.utf8)
        try document.write(to: snapshot)
        let storage = directory.appendingPathComponent("connections")
        let service = ToolConnectionService(home: home, environment: [:], keychainReader: { nil })
        let store = ToolConnectionStore(directory: storage, service: service)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertEqual(store.profiles(for: .deepSeekHarness).count, 1)
        let id = try XCTUnwrap(store.profiles(for: .deepSeekHarness).first?.id)
        await store.refresh(force: true, now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.quota(for: id)?.refreshedAt, Date(timeIntervalSince1970: 100.333))
        await store.refresh(force: true, now: Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(store.quota(for: id)?.refreshedAt, Date(timeIntervalSince1970: 100.333))
        let metadata = storage.appendingPathComponent("connections.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        legacy.removeValue(forKey: "hiddenAutomaticSourceIDs")
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadata)
        let loaded = ToolConnectionStore(directory: storage, service: service)
        XCTAssertEqual(loaded.profiles(for: .deepSeekHarness).map(\.id), [id])
        try loaded.hideAutomaticSource(id)
        XCTAssertEqual(try Data(contentsOf: snapshot), document)
        XCTAssertNil(loaded.selectedQuota(for: .deepSeekHarness))
    }

    func testDeepSeekFallbackPrefersLiveSourceDiscoveredAfterSnapshotWithoutCombiningBalances() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let snapshot = self.deepSeekDiscovery(id: "snapshot", providerKind: .dshSnapshot, key: "fixture-secret-one")
        let official = self.deepSeekDiscovery(id: "official", providerKind: .dshOfficialAPI, key: "fixture-secret-two")
        await service.setDiscoveries([snapshot])
        let store = ToolConnectionStore(directory: directory, service: service)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, snapshot.profile.id)
        await service.setDiscoveries([official, snapshot])
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        await store.refresh(force: true)

        XCTAssertEqual(store.profiles(for: .deepSeekHarness).map(\.id), [snapshot.profile.id, official.profile.id])
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, official.profile.id)
        XCTAssertEqual(store.selectedQuota(for: .deepSeekHarness)?.balance?.amount, 2)
        XCTAssertEqual(store.quota(for: snapshot.profile.id)?.balance?.amount, 1)
        XCTAssertEqual(store.quota(for: official.profile.id)?.balance?.amount, 2)
    }

    func testDeepSeekFallbackSkipsPausedAndHiddenOfficialSource() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let snapshot = self.deepSeekDiscovery(id: "snapshot", providerKind: .dshSnapshot, key: "fixture-secret-one")
        let official = self.deepSeekDiscovery(id: "official", providerKind: .dshOfficialAPI, key: "fixture-secret-two")
        await service.setDiscoveries([snapshot, official])
        let store = ToolConnectionStore(directory: directory, service: service)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        try store.setEnabled(official.profile.id, enabled: false)
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, snapshot.profile.id)
        try store.setEnabled(official.profile.id, enabled: true)
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, official.profile.id)
        try store.hideAutomaticSource(official.profile.id)
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, snapshot.profile.id)
        try store.restoreAutomaticSource(official.profile.id)
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, official.profile.id)
    }

    func testDeepSeekExplicitSnapshotSelectionSurvivesRediscoveryAndReload() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let snapshot = self.deepSeekDiscovery(id: "snapshot", providerKind: .dshSnapshot, key: "fixture-secret-one")
        let official = self.deepSeekDiscovery(id: "official", providerKind: .dshOfficialAPI, key: "fixture-secret-two")
        await service.setDiscoveries([snapshot, official])
        let store = ToolConnectionStore(directory: directory, service: service)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        try store.select(snapshot.profile.id)
        await store.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        await store.refresh(force: true)
        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, snapshot.profile.id)
        XCTAssertEqual(store.selectedQuota(for: .deepSeekHarness)?.balance?.amount, 1)

        let restored = ToolConnectionStore(directory: directory, service: service)
        XCTAssertEqual(restored.selectedProfile(for: .deepSeekHarness)?.id, snapshot.profile.id)
        try restored.setEnabled(snapshot.profile.id, enabled: false)
        XCTAssertEqual(restored.selectedProfile(for: .deepSeekHarness)?.id, official.profile.id)
        try restored.setEnabled(snapshot.profile.id, enabled: true)
        XCTAssertEqual(restored.selectedProfile(for: .deepSeekHarness)?.id, snapshot.profile.id)
        try restored.select(official.profile.id)
        XCTAssertEqual(restored.selectedProfile(for: .deepSeekHarness)?.id, official.profile.id)
    }

    func testDeepSeekFallbackAcceptsLegacyManualPrimaryAndLeavesOtherClientsInStoredOrder() async throws {
        let directory = try self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ConnectionStoreFixtureService()
        let snapshot = self.deepSeekDiscovery(id: "snapshot", providerKind: .dshSnapshot, key: "fixture-secret-one")
        let credential = ManagedToolCredential(apiKey: "fixture-secret-two")
        let legacy = ManagedToolConnection(id: "legacy", client: .deepSeekHarness, label: "Legacy official API", source: "fixture",
            hasAPIKey: true, credentialFingerprint: ToolConnectionService.fingerprint(credential))
        let openCodeFirst = ManagedToolConnection(id: "openCode-first", client: .openCode, label: "First", source: "fixture",
            isAutomatic: true, providerKind: .dshSnapshot)
        let openCodeSecond = ManagedToolConnection(id: "openCode-second", client: .openCode, label: "Second", source: "fixture",
            isAutomatic: true, providerKind: .dshOfficialAPI)
        let profiles = [snapshot.profile, legacy, openCodeFirst, openCodeSecond]
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles))
        try JSONSerialization.data(withJSONObject: ["profiles": metadata, "selected": ["deepSeekHarness": "removed-source"]])
            .write(to: directory.appendingPathComponent("connections.json"))
        try JSONEncoder().encode([legacy.id: credential]).write(to: directory.appendingPathComponent("credentials.json"))
        let store = ToolConnectionStore(directory: directory, service: service)

        XCTAssertEqual(store.selectedProfile(for: .deepSeekHarness)?.id, legacy.id)
        XCTAssertEqual(store.selectedProfile(for: .openCode)?.id, openCodeFirst.id)
    }

    private func deepSeekDiscovery(id: String, providerKind: ManagedToolProviderKind, key: String) -> DiscoveredToolConnection {
        let credential = ManagedToolCredential(apiKey: key)
        return DiscoveredToolConnection(profile: ManagedToolConnection(id: id, client: .deepSeekHarness, label: id, source: "fixture",
            hasAPIKey: true, isAutomatic: true, credentialFingerprint: ToolConnectionService.fingerprint(credential),
            providerKind: providerKind), credential: credential)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-connection-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor ConnectionStoreFixtureService: ToolConnectionServicing {
    private var queries = 0
    private var toBlock = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var discoveryKey: String?
    private var discoveredConnections: [DiscoveredToolConnection]?
    func queryCount() -> Int { self.queries }
    func blockNext(_ count: Int) { self.toBlock = count }
    func waitUntilBlocked(_ count: Int) async {
        while self.continuations.count < count { await Task.yield() }
    }
    func release() { let waiting = self.continuations; self.continuations = []; waiting.forEach { $0.resume() } }
    func setDiscoveryKey(_ key: String) { self.discoveryKey = key }
    func setDiscoveries(_ connections: [DiscoveredToolConnection]) { self.discoveredConnections = connections }
    func discover(client: ToolUsageClient, preferences: ApplicationPreferences) async throws -> [DiscoveredToolConnection] {
        if let discoveredConnections { return discoveredConnections }
        guard let key = self.discoveryKey else { return [] }
        let credential = ManagedToolCredential(apiKey: key)
        let hash = ToolConnectionService.fingerprint(credential)
        return [DiscoveredToolConnection(profile: ManagedToolConnection(id: "auto.\(hash)", client: client,
            label: "Automatic", source: "fixture", hasAPIKey: true, isAutomatic: true, credentialFingerprint: hash), credential: credential)]
    }
    func organizations(sessionKey: String) async throws -> [ClaudeOrganization] {
        [ClaudeOrganization(id: "org-one", name: "One"), ClaudeOrganization(id: "org-two", name: "Two")]
    }
    func organizationLookup(sessionKey: String) async throws -> ClaudeOrganizationResult {
        ClaudeOrganizationResult(organizations: try await self.organizations(sessionKey: sessionKey), renewedCookie: "sessionKey=sk-ant-rotated")
    }
    func query(profile: ManagedToolConnection, credential: ManagedToolCredential, now: Date) async throws -> ManagedToolQuotaResult {
        self.queries += 1
        if self.toBlock > 0 {
            self.toBlock -= 1
            await withCheckedContinuation { continuation in self.continuations.append(continuation) }
        }
        let amount = credential.apiKey?.hasSuffix("two") == true ? 2.0 : 1.0
        return ManagedToolQuotaResult(snapshot: ToolQuotaSnapshot(client: profile.client, status: .ready,
            providerName: profile.client.displayName, balance: ToolQuotaBalance(amount: amount, currency: "USD"),
            refreshedAt: now, statusDetail: "fixture server quota"), organizationID: profile.organizationID)
    }
}
