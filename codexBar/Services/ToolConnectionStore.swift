import Combine
import Darwin
import Foundation

/// Credential-free metadata/cache and a separate owner-readable credential file.
/// Profile behavior adapts Token Monitor's MIT Claude single Web connection, OpenCode profiles, and DeepSeek key.
@MainActor
final class ToolConnectionStore: ObservableObject {
    static let shared = ToolConnectionStore(preferencesStore: .shared)
    @Published private(set) var profiles: [ManagedToolConnection] = []
    @Published private(set) var quotas: [String: ToolQuotaSnapshot] = [:]
    @Published private(set) var organizations: [ClaudeOrganization] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusDetail: String?
    @Published private(set) var hiddenAutomaticSourceIDs = Set<String>()

    private struct Metadata: Codable {
        var profiles: [ManagedToolConnection] = []
        var selected: [String: String] = [:]
        var hiddenAutomaticSourceIDs = Set<String>()

        enum CodingKeys: String, CodingKey { case profiles, selected, hiddenAutomaticSourceIDs }
        init(profiles: [ManagedToolConnection], selected: [String: String], hiddenAutomaticSourceIDs: Set<String>) {
            self.profiles = profiles; self.selected = selected; self.hiddenAutomaticSourceIDs = hiddenAutomaticSourceIDs
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.profiles = try values.decodeIfPresent([ManagedToolConnection].self, forKey: .profiles) ?? []
            self.selected = try values.decodeIfPresent([String: String].self, forKey: .selected) ?? [:]
            self.hiddenAutomaticSourceIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenAutomaticSourceIDs) ?? []
        }
    }
    private let root: URL
    private let service: any ToolConnectionServicing
    private var credentials: [String: ManagedToolCredential] = [:]
    private var selected: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private var clientRevisions: [ToolUsageClient: Int] = [:]
    private var inFlight = Set<String>()
    private var lastRefresh: [String: Date] = [:]
    private var disabledClients = Set<String>()
    private var preferencesCancellable: AnyCancellable?
    private var pendingClaudeCookie: (fingerprint: String, cookie: String)?
    private var organizationLookupRevision = 0

    init(directory: URL? = nil, service: (any ToolConnectionServicing)? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         transport: any CursorUsageHTTPTransport = CursorUsageURLSessionTransport(),
         keychainReader: @escaping @Sendable () -> Data? = { nil },
         preferencesStore: ApplicationPreferencesStore? = nil) {
        self.root = directory ?? home.appendingPathComponent(".codexbar/tool-connections", isDirectory: true)
        // Production's default service reads Keychain; isolated-home tests inject an explicit reader.
        if let service { self.service = service }
        else if directory == nil && home == FileManager.default.homeDirectoryForCurrentUser {
            self.service = ToolConnectionService(transport: transport, home: home, environment: environment)
        } else {
            self.service = ToolConnectionService(transport: transport, home: home, environment: environment, keychainReader: keychainReader)
        }
        if let metadata: Metadata = Self.load(self.root.appendingPathComponent("connections.json")) {
            var seen = Set<String>()
            self.profiles = metadata.profiles.filter { $0.client != .cursor && seen.insert($0.id).inserted }
            self.selected = metadata.selected
            self.hiddenAutomaticSourceIDs = metadata.hiddenAutomaticSourceIDs
        }
        self.credentials = Self.load(self.root.appendingPathComponent("credentials.json")) ?? [:]
        self.quotas = Self.load(self.root.appendingPathComponent("quota-cache.json")) ?? [:]
        let valid = Set(self.profiles.map(\.id))
        self.quotas = self.quotas.filter { valid.contains($0.key) }
        // The private file never stores automatically discovered client credentials.
        let manualIDs = Set(self.profiles.filter { !$0.isAutomatic }.map(\.id))
        self.credentials = self.credentials.filter { manualIDs.contains($0.key) }
        // A failed prior transaction must never pair a new secret with another account's cached quota.
        for profile in self.profiles where !profile.isAutomatic {
            if self.credentials[profile.id].map({ profile.credentialFingerprint == ToolConnectionService.fingerprint($0) }) != true {
                self.credentials.removeValue(forKey: profile.id); self.quotas.removeValue(forKey: profile.id)
            }
        }
        self.profiles.filter { $0.providerKind == .dshSnapshot }.forEach { self.credentials[$0.id] = ManagedToolCredential() }
        self.disabledClients = Set(preferencesStore?.preferences.disabledTools ?? [])
        self.preferencesCancellable = preferencesStore?.$preferences.map(\.disabledTools).removeDuplicates().dropFirst().sink { [weak self] disabled in
            guard let self else { return }
            let changed = self.disabledClients.symmetricDifference(Set(disabled))
            self.disabledClients = Set(disabled)
            for client in ToolUsageClient.allCases where changed.contains(client.rawValue) {
                self.clientRevisions[client, default: 0] += 1
                self.profiles(for: client).forEach { self.invalidate($0.id) }
            }
        }
    }

    func profiles(for client: ToolUsageClient) -> [ManagedToolConnection] {
        self.profiles.filter { $0.client == client && !self.hiddenAutomaticSourceIDs.contains($0.id) }
    }
    func hiddenProfiles(for client: ToolUsageClient) -> [ManagedToolConnection] {
        self.profiles.filter { $0.client == client && $0.canHideAutomaticSource && self.hiddenAutomaticSourceIDs.contains($0.id) }
    }
    func quota(for profileID: String) -> ToolQuotaSnapshot? { self.quotas[profileID] }
    func selectedProfile(for client: ToolUsageClient) -> ManagedToolConnection? {
        let eligible = self.profiles(for: client).filter(\.isEnabled)
        return eligible.first { $0.id == self.selected[client.rawValue] } ?? eligible.first
    }
    func selectedQuota(for client: ToolUsageClient) -> ToolQuotaSnapshot? {
        self.selectedProfile(for: client).flatMap { self.quotas[$0.id] }
    }

    func discover(client: ToolUsageClient, preferences: ApplicationPreferences) async {
        guard !preferences.disabledTools.contains(client.rawValue), !self.disabledClients.contains(client.rawValue), client != .cursor else { return }
        if client != .openCode, self.profiles(for: client).contains(where: { !$0.isAutomatic }) { return }
        let revision = self.clientRevisions[client, default: 0]
        do {
            let discoveries = try await self.service.discover(client: client, preferences: preferences)
            guard self.clientRevisions[client, default: 0] == revision else { return }
            let discoveredIDs = Set(discoveries.map { $0.profile.id })
            var updated = self.profiles
            var secrets = self.credentials
            var cache = self.quotas
            let obsolete = updated.filter { $0.client == client && $0.isAutomatic && !discoveredIDs.contains($0.id) }
            for profile in obsolete {
                updated.removeAll { $0.id == profile.id }; secrets.removeValue(forKey: profile.id)
                cache.removeValue(forKey: profile.id); self.invalidate(profile.id)
            }
            for discovery in discoveries {
                if client == .openCode, let key = discovery.credential.apiKey,
                   updated.contains(where: { !$0.isAutomatic && secrets[$0.id]?.apiKey == key }) { continue }
                var profile = discovery.profile
                if let index = updated.firstIndex(where: { $0.id == profile.id }) {
                    guard updated[index].isAutomatic else { continue }
                    profile.isEnabled = updated[index].isEnabled
                    profile.updatedAt = updated[index].updatedAt
                    if profile.credentialFingerprint != updated[index].credentialFingerprint {
                        cache.removeValue(forKey: profile.id); self.invalidate(profile.id)
                    } else {
                        profile.label = updated[index].label
                        profile.organizationID = updated[index].organizationID
                        profile.accountIdentity = updated[index].accountIdentity
                    }
                    updated[index] = profile
                } else { updated.append(profile) }
                secrets[profile.id] = discovery.credential
            }
            if updated != self.profiles || secrets != self.credentials {
                try self.commit(updated, secrets: secrets, cache: cache, selection: self.selected)
            }
            self.statusDetail = nil
        } catch { self.statusDetail = ToolConnectionService.opaque(error).localizedDescription }
    }

    @discardableResult
    func loadClaudeOrganizations(sessionKey: String) async throws -> [ClaudeOrganization] {
        self.organizationLookupRevision += 1
        let revision = self.organizationLookupRevision
        do {
            let cookie = try ToolConnectionService.claudeCookie(sessionKey)
            let result = try await self.service.organizationLookup(sessionKey: cookie)
            if revision == self.organizationLookupRevision {
                self.pendingClaudeCookie = (ToolConnectionService.fingerprint(ManagedToolCredential(cookie: cookie)), result.renewedCookie ?? cookie)
                self.organizations = result.organizations
            }
            return result.organizations
        } catch { throw ToolConnectionService.opaque(error) }
    }

    func saveClaudeSession(sessionKey: String, organizationID: String? = nil) async throws {
        let rawCookie = try ToolConnectionService.claudeCookie(sessionKey)
        let fingerprint = ToolConnectionService.fingerprint(ManagedToolCredential(cookie: rawCookie))
        let cookie = self.pendingClaudeCookie?.fingerprint == fingerprint ? self.pendingClaudeCookie!.cookie : rawCookie
        let choices = self.pendingClaudeCookie?.fingerprint == fingerprint ? self.organizations : []
        let selectedID = try ToolConnectionService.organizationID(organizationID)
        let organization: ClaudeOrganization
        if let selectedID {
            organization = choices.first(where: { $0.id == selectedID }) ?? ClaudeOrganization(id: selectedID, name: "Claude Web")
        } else {
            if choices.count > 1 { throw ToolConnectionError.organizationSelectionRequired }
            organization = choices.first ?? ClaudeOrganization(id: "", name: "Claude Web")
        }
        let credential = ManagedToolCredential(cookie: cookie)
        let profile = ManagedToolConnection(id: ToolUsageClient.claudeCode.rawValue, client: .claudeCode,
            label: organization.name, source: "手动连接 · Claude Web", hasCookie: true,
            organizationID: organization.id.isEmpty ? nil : organization.id, credentialFingerprint: ToolConnectionService.fingerprint(credential))
        try await self.validateAndSave(profile, credential: credential)
    }

    func saveOpenCodeProfile(label: String, apiKey: String? = nil, cookie: String? = nil, profileID: String? = nil,
                             confirmedSameAccount: Bool = false) async throws {
        let existing = profileID.flatMap { id in self.profiles.first { $0.id == id && $0.client == .openCode } }
        if profileID != nil && existing == nil { throw ToolConnectionError.missingProfile }
        guard existing?.isAutomatic != true else { throw ToolConnectionError.unsupported }
        var credential = existing.flatMap { self.credentials[$0.id] } ?? ManagedToolCredential()
        if let key = try ToolConnectionService.secret(apiKey) { credential.apiKey = key }
        if let cookie = try ToolConnectionService.openCodeCookie(cookie) { credential.cookie = cookie }
        guard credential.apiKey != nil || credential.cookie != nil else { throw ToolConnectionError.invalidCredential }
        let old = existing.flatMap { self.credentials[$0.id] }
        if credential.apiKey != nil && credential.cookie != nil && credential != old && !confirmedSameAccount {
            throw ToolConnectionError.sameAccountConfirmationRequired
        }
        let id = existing?.id ?? "openCode.\(UUID().uuidString)"
        let duplicates = self.profiles.filter { $0.client == .openCode && $0.id != id && !$0.isAutomatic }
        guard !duplicates.contains(where: { other in
            let otherSecret = self.credentials[other.id]
            return credential.apiKey != nil && credential.apiKey == otherSecret?.apiKey || credential.cookie != nil && credential.cookie == otherSecret?.cookie
        }) else { throw ToolConnectionError.duplicateCredential }
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 100, !cleaned.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw ToolConnectionError.invalidCredential
        }
        var profile = ManagedToolConnection(id: id, client: .openCode, label: cleaned, source: "手动连接 · OpenCode Go / Zen",
            hasAPIKey: credential.apiKey != nil, hasCookie: credential.cookie != nil, credentialFingerprint: ToolConnectionService.fingerprint(credential))
        profile.isEnabled = existing?.isEnabled ?? true
        try await self.validateAndSave(profile, credential: credential)
        // An explicit profile may claim a previously discovered Go key. Remove the duplicate automatic row.
        let autos = self.profiles.filter { $0.client == .openCode && $0.isAutomatic && self.credentials[$0.id]?.apiKey == credential.apiKey }
        if !autos.isEmpty {
            let ids = Set(autos.map(\.id))
            try self.commit(self.profiles.filter { !ids.contains($0.id) }, secrets: self.credentials.filter { !ids.contains($0.key) },
                cache: self.quotas.filter { !ids.contains($0.key) }, selection: self.selected)
            ids.forEach { self.invalidate($0) }
        }
    }

    func saveDeepSeekKey(_ apiKey: String) async throws {
        guard let key = try ToolConnectionService.secret(apiKey) else { throw ToolConnectionError.invalidCredential }
        let credential = ManagedToolCredential(apiKey: key)
        let profile = ManagedToolConnection(id: ToolUsageClient.deepSeekHarness.rawValue, client: .deepSeekHarness,
            label: "DeepSeek API", source: "手动连接 · DeepSeek 官方 API", hasAPIKey: true,
            credentialFingerprint: ToolConnectionService.fingerprint(credential), providerKind: .dshOfficialAPI)
        try await self.validateAndSave(profile, credential: credential)
    }

    private func validateAndSave(_ profile: ManagedToolConnection, credential: ManagedToolCredential) async throws {
        guard !self.disabledClients.contains(profile.client.rawValue) else { throw ToolConnectionError.unsupported }
        let oldRevision = self.revisions[profile.id, default: 0]
        do {
            let result = try await self.service.query(profile: profile, credential: credential, now: Date())
            guard self.revisions[profile.id, default: 0] == oldRevision,
                  !self.disabledClients.contains(profile.client.rawValue) else { throw ToolConnectionError.missingProfile }
            switch result.snapshot.status {
            case .authenticationRequired: throw ToolConnectionError.authenticationRequired
            case .failed: throw ToolConnectionError.networkFailure
            case .notConfigured, .loading: throw ToolConnectionError.invalidResponse
            case .unsupported where profile.client != .openCode: throw ToolConnectionError.unsupported
            default: break
            }
            // Recheck ownership after the await: another window may have saved the same key meanwhile.
            if profile.client == .openCode {
                guard !self.profiles.contains(where: { other in
                    guard other.client == .openCode, other.id != profile.id, !other.isAutomatic else { return false }
                    let secret = self.credentials[other.id]
                    return credential.apiKey != nil && credential.apiKey == secret?.apiKey
                        || credential.cookie != nil && credential.cookie == secret?.cookie
                }) else { throw ToolConnectionError.duplicateCredential }
            }
            var secret = credential
            if let renewed = result.renewedCookie { secret.cookie = renewed }
            var stored = profile
            stored.credentialFingerprint = ToolConnectionService.fingerprint(secret)
            if let label = result.displayLabel { stored.label = label }
            if let organizationID = result.organizationID { stored.organizationID = organizationID }
            stored.accountIdentity = result.accountIdentity
            var profiles = self.profiles
            profiles.removeAll { $0.id == profile.id }
            let index = self.profiles.firstIndex(where: { $0.id == profile.id }) ?? profiles.endIndex
            profiles.insert(stored, at: min(index, profiles.endIndex))
            var secrets = self.credentials; secrets[stored.id] = secret
            var cache = self.quotas; cache[stored.id] = result.snapshot
            var selection = self.selected; selection[stored.client.rawValue] = stored.id
            self.invalidate(stored.id)
            self.clientRevisions[stored.client, default: 0] += 1
            try self.commit(profiles, secrets: secrets, cache: cache, selection: selection,
                hidden: self.hiddenAutomaticSourceIDs.subtracting([stored.id]))
            self.lastRefresh[stored.id] = Date(); self.statusDetail = nil
        } catch { throw ToolConnectionService.opaque(error) }
    }

    func refresh(profileID: String? = nil, force: Bool = false, now: Date = Date()) async {
        let targets = self.profiles.filter { profile in
            profile.isEnabled && !self.disabledClients.contains(profile.client.rawValue)
                && !self.hiddenAutomaticSourceIDs.contains(profile.id)
                && (profileID == nil || profile.id == profileID) && !self.inFlight.contains(profile.id)
                && (force || self.lastRefresh[profile.id].map { now.timeIntervalSince($0) >= 300 } ?? true)
                && self.credentials[profile.id] != nil
        }
        let service = self.service
        for profile in targets { self.inFlight.insert(profile.id); self.lastRefresh[profile.id] = now }
        self.isRefreshing = !self.inFlight.isEmpty
        await withTaskGroup(of: (String, Int, ManagedToolCredential, ManagedToolQuotaResult?, ToolConnectionError?).self) { group in
            for profile in targets {
                let credential = self.credentials[profile.id]!
                let revision = self.revisions[profile.id, default: 0]
                group.addTask {
                    do { return (profile.id, revision, credential, try await service.query(profile: profile, credential: credential, now: now), nil) }
                    catch { return (profile.id, revision, credential, nil, ToolConnectionService.opaque(error)) }
                }
            }
            for await (id, revision, original, result, error) in group {
                self.inFlight.remove(id)
                guard self.revisions[id, default: 0] == revision,
                      let profile = self.profiles.first(where: { $0.id == id }), profile.isEnabled,
                      !self.hiddenAutomaticSourceIDs.contains(id),
                      !self.disabledClients.contains(profile.client.rawValue),
                      self.credentials[id] == original else { continue }
                if let result {
                    var secrets = self.credentials
                    var updatedProfiles = self.profiles
                    if let index = updatedProfiles.firstIndex(where: { $0.id == id }) {
                        if let label = result.displayLabel { updatedProfiles[index].label = label }
                        if let organizationID = result.organizationID { updatedProfiles[index].organizationID = organizationID }
                        updatedProfiles[index].accountIdentity = result.accountIdentity ?? updatedProfiles[index].accountIdentity
                    }
                    if let renewed = result.renewedCookie, !profile.isAutomatic {
                        secrets[id]?.cookie = renewed
                        if let index = updatedProfiles.firstIndex(where: { $0.id == id }), let secret = secrets[id] {
                            updatedProfiles[index].credentialFingerprint = ToolConnectionService.fingerprint(secret)
                        }
                    }
                    var cache = self.quotas; cache[id] = result.snapshot
                    do { try self.commit(updatedProfiles, secrets: secrets, cache: cache, selection: self.selected) }
                    catch { self.statusDetail = ToolConnectionError.storageFailure.localizedDescription }
                } else {
                    self.quotas[id] = ToolQuotaSnapshot(client: profile.client,
                        status: error == .authenticationRequired ? .authenticationRequired : .failed,
                        providerName: profile.client.displayName, refreshedAt: now,
                        statusDetail: (error ?? .networkFailure).localizedDescription)
                }
            }
        }
        self.isRefreshing = !self.inFlight.isEmpty
    }

    func remove(_ id: String) throws {
        guard let profile = self.profiles.first(where: { $0.id == id }), profile.canRemove else { throw ToolConnectionError.missingProfile }
        if profile.canHideAutomaticSource { try self.hideAutomaticSource(id); return }
        self.invalidate(id); self.clientRevisions[profile.client, default: 0] += 1
        try self.commit(self.profiles.filter { $0.id != id }, secrets: self.credentials.filter { $0.key != id },
            cache: self.quotas.filter { $0.key != id }, selection: self.selected.filter { $0.value != id })
    }

    func removeCredential(_ id: String, kind: ManagedToolCredentialKind) throws {
        guard var profile = self.profiles.first(where: { $0.id == id }), !profile.isAutomatic,
              var credential = self.credentials[id] else { throw ToolConnectionError.missingProfile }
        if kind == .apiKey { credential.apiKey = nil; profile.hasAPIKey = false }
        else { credential.cookie = nil; profile.hasCookie = false; profile.organizationID = nil }
        if credential.apiKey == nil && credential.cookie == nil && credential.oauthToken == nil { try self.remove(id); return }
        profile.credentialFingerprint = ToolConnectionService.fingerprint(credential)
        var profiles = self.profiles; profiles[profiles.firstIndex(where: { $0.id == id })!] = profile
        var secrets = self.credentials; secrets[id] = credential
        self.invalidate(id)
        try self.commit(profiles, secrets: secrets, cache: self.quotas.filter { $0.key != id }, selection: self.selected)
    }

    func rename(_ id: String, label: String) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 100, !label.unicodeScalars.contains(where: { $0.value < 32 }),
              let index = self.profiles.firstIndex(where: { $0.id == id && $0.client == .openCode && !$0.isAutomatic }) else {
            throw ToolConnectionError.missingProfile
        }
        var profiles = self.profiles; profiles[index].label = label
        try self.commit(profiles, secrets: self.credentials, cache: self.quotas, selection: self.selected)
    }

    /// A credential moves only between explicit OpenCode profiles; conflicts never overwrite a target.
    func transferCredential(from sourceID: String, to targetID: String, kind: ManagedToolCredentialKind,
                            confirmedSameAccount: Bool = false) throws {
        guard sourceID != targetID,
              let sourceIndex = self.profiles.firstIndex(where: { $0.id == sourceID && $0.client == .openCode && !$0.isAutomatic }),
              let targetIndex = self.profiles.firstIndex(where: { $0.id == targetID && $0.client == .openCode && !$0.isAutomatic }),
              var source = self.credentials[sourceID], var target = self.credentials[targetID] else { throw ToolConnectionError.missingProfile }
        var profiles = self.profiles
        if !confirmedSameAccount && (kind == .apiKey && target.cookie != nil || kind == .cookie && target.apiKey != nil) {
            throw ToolConnectionError.sameAccountConfirmationRequired
        }
        switch kind {
        case .apiKey:
            guard let key = source.apiKey, target.apiKey == nil else { throw ToolConnectionError.duplicateCredential }
            source.apiKey = nil; target.apiKey = key
            profiles[sourceIndex].hasAPIKey = false; profiles[targetIndex].hasAPIKey = true
        case .cookie:
            guard let cookie = source.cookie, target.cookie == nil else { throw ToolConnectionError.duplicateCredential }
            source.cookie = nil; target.cookie = cookie
            profiles[sourceIndex].hasCookie = false; profiles[targetIndex].hasCookie = true
        }
        profiles[sourceIndex].credentialFingerprint = ToolConnectionService.fingerprint(source)
        profiles[targetIndex].credentialFingerprint = ToolConnectionService.fingerprint(target)
        var secrets = self.credentials; secrets[sourceID] = source; secrets[targetID] = target
        self.invalidate(sourceID); self.invalidate(targetID)
        self.clientRevisions[.openCode, default: 0] += 1
        try self.commit(profiles, secrets: secrets, cache: self.quotas.filter { $0.key != sourceID && $0.key != targetID }, selection: self.selected)
    }

    func move(_ id: String, by offset: Int) throws {
        guard let profile = self.profiles.first(where: { $0.id == id }), profile.client == .openCode else { throw ToolConnectionError.missingProfile }
        var group = self.profiles(for: .openCode)
        guard let index = group.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + min(max(offset, -index), group.count - 1 - index)
        guard index != destination else { return }
        group.remove(at: index); group.insert(profile, at: destination)
        var iterator = group.makeIterator()
        let profiles = self.profiles.map { $0.client == .openCode ? iterator.next()! : $0 }
        try self.commit(profiles, secrets: self.credentials, cache: self.quotas, selection: self.selected)
    }

    func setEnabled(_ id: String, enabled: Bool) throws {
        guard let index = self.profiles.firstIndex(where: { $0.id == id }) else { throw ToolConnectionError.missingProfile }
        var profiles = self.profiles; profiles[index].isEnabled = enabled
        self.invalidate(id)
        try self.commit(profiles, secrets: self.credentials, cache: self.quotas, selection: self.selected)
    }

    func select(_ id: String) throws {
        guard let profile = self.profiles.first(where: { $0.id == id }), profile.isEnabled,
              !self.hiddenAutomaticSourceIDs.contains(id) else { throw ToolConnectionError.missingProfile }
        var selected = self.selected; selected[profile.client.rawValue] = id
        try self.commit(self.profiles, secrets: self.credentials, cache: self.quotas, selection: selected)
    }

    private func invalidate(_ id: String) { self.revisions[id, default: 0] += 1; self.lastRefresh.removeValue(forKey: id) }

    /// Hide only Codexbar's representation; the DSH configuration and snapshots remain intact.
    func hideAutomaticSource(_ id: String) throws {
        guard let profile = self.profiles.first(where: { $0.id == id }), profile.canHideAutomaticSource else {
            throw ToolConnectionError.missingProfile
        }
        var hidden = self.hiddenAutomaticSourceIDs; hidden.insert(id)
        self.invalidate(id); self.clientRevisions[profile.client, default: 0] += 1
        try self.commit(self.profiles, secrets: self.credentials, cache: self.quotas.filter { $0.key != id },
            selection: self.selected.filter { $0.value != id }, hidden: hidden)
    }

    func restoreAutomaticSource(_ id: String) throws {
        guard let profile = self.profiles.first(where: { $0.id == id }), profile.canHideAutomaticSource,
              self.hiddenAutomaticSourceIDs.contains(id) else { throw ToolConnectionError.missingProfile }
        var hidden = self.hiddenAutomaticSourceIDs; hidden.remove(id)
        self.invalidate(id); self.clientRevisions[profile.client, default: 0] += 1
        try self.commit(self.profiles, secrets: self.credentials, cache: self.quotas,
            selection: self.selected, hidden: hidden)
    }

    private func commit(_ profiles: [ManagedToolConnection], secrets: [String: ManagedToolCredential],
                        cache: [String: ToolQuotaSnapshot], selection: [String: String], hidden: Set<String>? = nil) throws {
        var written: [(URL, Data?)] = []
        let hidden = hidden ?? self.hiddenAutomaticSourceIDs
        do {
            let manualIDs = Set(profiles.filter { !$0.isAutomatic }.map(\.id))
            let documents = [("credentials.json", try JSONEncoder().encode(secrets.filter { manualIDs.contains($0.key) })),
                ("connections.json", try JSONEncoder().encode(Metadata(profiles: profiles, selected: selection, hiddenAutomaticSourceIDs: hidden))),
                ("quota-cache.json", try JSONEncoder().encode(cache))]
            for (name, data) in documents {
                guard data.count <= 2 * 1024 * 1024 else { throw ToolConnectionError.storageFailure }
                let destination = self.root.appendingPathComponent(name)
                let previous = try? Data(contentsOf: destination)
                try Self.write(data, to: destination)
                written.append((destination, previous))
            }
            self.profiles = profiles; self.credentials = secrets; self.quotas = cache; self.selected = selection
            self.hiddenAutomaticSourceIDs = hidden
        } catch {
            for (destination, previous) in written.reversed() {
                if let previous { try? Self.write(previous, to: destination) }
                else { try? FileManager.default.removeItem(at: destination) }
            }
            throw ToolConnectionError.storageFailure
        }
    }

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ToolConnectionError.storageFailure }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ToolConnectionError.storageFailure }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw ToolConnectionError.storageFailure }
                written += count
            }
        }
        guard fsync(descriptor) == 0, Darwin.rename(temporary.path, destination.path) == 0 else { throw ToolConnectionError.storageFailure }
    }
}
