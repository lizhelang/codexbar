import Foundation

struct LegacyCodexTomlSnapshot {
    var model: String?
    var reviewModel: String?
    var reasoningEffort: String?
    var openAIBaseURL: String?
}

struct OpenAIAuthJSONSnapshot {
    let account: TokenAccount
    let localAccountID: String
    let remoteAccountID: String
    let email: String?
    let tokenLastRefreshAt: Date?
}

final class CodexBarConfigStore {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let presetProviders: [(id: String, label: String, baseURL: String, envKey: String)] = [
        ("funai", "FunAI", "https://api.funai.vip", "OPENAI_API_KEY"),
        ("s", "S", "https://api.0vo.dev/v1", "S_OAI_KEY"),
        ("htj", "HTJ", "https://rhino.tjhtj.com", "HTJ_OAI_KEY"),
    ]
    private let switchJournalStore: SwitchJournalStore
    private let recentOpenRouterModelResolver: () -> String?

    init(
        switchJournalStore: SwitchJournalStore = SwitchJournalStore(),
        recentOpenRouterModelResolver: @escaping () -> String? = {
            CodexBarConfigStore.defaultRecentOpenRouterModelIdentifier()
        }
    ) {
        self.switchJournalStore = switchJournalStore
        self.recentOpenRouterModelResolver = recentOpenRouterModelResolver
    }

    func loadOrMigrate() throws -> CodexBarConfig {
        try CodexPaths.ensureDirectories()
        let loaded: CodexBarConfig
        if FileManager.default.fileExists(atPath: CodexPaths.barConfigURL.path) {
            do {
                loaded = try self.load()
            } catch {
                try self.backupForeignConfig()
                loaded = try self.migrateFromLegacy()
            }
        } else {
            loaded = try self.migrateFromLegacy()
        }

        let normalized = self.normalizeOAuthAccountIdentities(in: loaded)
        let metadataRefreshed = self.refreshOAuthAccountMetadata(in: normalized.config)
        let reconciled = self.reconcileAuthJSON(in: metadataRefreshed.config)
        let sanitized = self.sanitizeOAuthQuotaSnapshots(in: reconciled.config)
        let teamOrganizationNormalized = self.normalizeSharedOpenAITeamOrganizationNames(in: sanitized.config)
        let reservedProviderIDNormalized = self.normalizeReservedProviderIDs(in: teamOrganizationNormalized.config)
        let openRouterNormalized = self.normalizeOpenRouterProviders(in: reservedProviderIDNormalized.config)
        if FileManager.default.fileExists(atPath: CodexPaths.barConfigURL.path) == false ||
            normalized.changed ||
            metadataRefreshed.changed ||
            reconciled.changed ||
            sanitized.changed ||
            teamOrganizationNormalized.changed ||
            reservedProviderIDNormalized.changed ||
            openRouterNormalized.changed {
            try self.save(openRouterNormalized.config)
            if normalized.migratedAccountIDs.isEmpty == false {
                try? self.switchJournalStore.remapOpenAIOAuthAccountIDs(using: normalized.migratedAccountIDs)
            }
        }
        return openRouterNormalized.config
    }

    func load() throws -> CodexBarConfig {
        let data = try Data(contentsOf: CodexPaths.barConfigURL)
        return try self.decoder.decode(CodexBarConfig.self, from: data)
    }

    func save(_ config: CodexBarConfig) throws {
        let data = try self.encoder.encode(self.legacyCompatiblePersistenceConfig(from: config))
        try CodexPaths.writeSecureFile(data, to: CodexPaths.barConfigURL)
    }

    private func migrateFromLegacy() throws -> CodexBarConfig {
        let toml = self.readLegacyToml()
        let auth = self.readAuthJSON()
        let authSnapshot = self.readAuthJSONSnapshot()
        let envSecrets = self.readProviderSecrets()

        var providers: [CodexBarProvider] = []

        if let oauthProvider = self.makeOAuthProvider(authSnapshot: authSnapshot) {
            providers.append(oauthProvider)
        }

        for preset in self.presetProviders {
            guard let apiKey = envSecrets[preset.envKey], !apiKey.isEmpty else { continue }
            let account = CodexBarProviderAccount(
                kind: .apiKey,
                label: "Default",
                apiKey: apiKey,
                addedAt: Date()
            )
            providers.append(
                CodexBarProvider(
                    id: preset.id,
                    kind: .openAICompatible,
                    label: preset.label,
                    enabled: true,
                    baseURL: preset.baseURL,
                    activeAccountId: account.id,
                    accounts: [account]
                )
            )
        }

        if let authAPIKey = auth["OPENAI_API_KEY"] as? String,
           !authAPIKey.isEmpty,
           let imported = self.makeImportedProviderIfNeeded(
               baseURL: toml.openAIBaseURL,
               apiKey: authAPIKey,
               existingProviders: providers
           ) {
            providers.append(imported)
        }

        let global = CodexBarGlobalSettings(
            defaultModel: toml.model ?? "gpt-5.4",
            reviewModel: toml.reviewModel ?? toml.model ?? "gpt-5.4",
            reasoningEffort: toml.reasoningEffort ?? "xhigh"
        )

        let active = self.resolveActiveSelection(
            toml: toml,
            auth: auth,
            authSnapshot: authSnapshot,
            providers: providers
        )

        return CodexBarConfig(
            version: 1,
            global: global,
            active: active,
            providers: providers
        )
    }

    private func makeOAuthProvider(authSnapshot: OpenAIAuthJSONSnapshot?) -> CodexBarProvider? {
        var importedAccounts: [CodexBarProviderAccount] = []

        if let data = try? Data(contentsOf: CodexPaths.tokenPoolURL),
           let pool = try? self.decoder.decode(TokenPool.self, from: data) {
            importedAccounts = pool.accounts.map { account in
                CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
            }
        }

        if let imported = authSnapshot.map(self.accountFromAuthSnapshot) {
            if importedAccounts.contains(where: { $0.id == imported.id }) == false {
                importedAccounts.append(imported)
            }
        }

        guard importedAccounts.isEmpty == false else { return nil }

        let activeAccountId = importedAccounts.first?.id
        return CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            baseURL: nil,
            activeAccountId: activeAccountId,
            accounts: importedAccounts
        )
    }

    private func makeImportedProviderIfNeeded(
        baseURL: String?,
        apiKey: String,
        existingProviders: [CodexBarProvider]
    ) -> CodexBarProvider? {
        let normalizedBaseURL = baseURL ?? "https://api.openai.com/v1"
        if existingProviders.contains(where: { $0.baseURL == normalizedBaseURL }) {
            return nil
        }

        let label = URL(string: normalizedBaseURL)?.host ?? "Imported"
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: "Imported",
            apiKey: apiKey,
            addedAt: Date()
        )
        return CodexBarProvider(
            id: self.slug(from: label),
            kind: .openAICompatible,
            label: label,
            enabled: true,
            baseURL: normalizedBaseURL,
            activeAccountId: account.id,
            accounts: [account]
        )
    }

    private func resolveActiveSelection(
        toml: LegacyCodexTomlSnapshot,
        auth: [String: Any],
        authSnapshot: OpenAIAuthJSONSnapshot?,
        providers: [CodexBarProvider]
    ) -> CodexBarActiveSelection {
        if let baseURL = toml.openAIBaseURL,
           let provider = providers.first(where: { $0.baseURL == baseURL }) {
            return CodexBarActiveSelection(providerId: provider.id, accountId: provider.activeAccount?.id)
        }

        if let snapshot = authSnapshot,
           let provider = providers.first(where: { $0.kind == .openAIOAuth }) {
            let activeAccount = snapshot.account
            let remoteAccountID = snapshot.remoteAccountID
            let selected = provider.accounts.first(where: { $0.id == activeAccount.accountId })
                ?? self.uniqueOAuthAccount(in: provider, matchingRemoteAccountID: remoteAccountID)
                ?? provider.activeAccount
            return CodexBarActiveSelection(providerId: provider.id, accountId: selected?.id)
        }

        if let openAIAPIKey = auth["OPENAI_API_KEY"] as? String,
           !openAIAPIKey.isEmpty,
           let provider = providers.first(where: { $0.kind == .openAICompatible }) {
            return CodexBarActiveSelection(providerId: provider.id, accountId: provider.activeAccount?.id)
        }

        let fallbackProvider = providers.first
        return CodexBarActiveSelection(providerId: fallbackProvider?.id, accountId: fallbackProvider?.activeAccount?.id)
    }

    private func normalizeOAuthAccountIdentities(
        in original: CodexBarConfig
    ) -> (config: CodexBarConfig, migratedAccountIDs: [String: String], changed: Bool) {
        var config = original
        guard let providerIndex = config.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (config, [:], false)
        }

        var provider = config.providers[providerIndex]
        var migratedAccountIDs: [String: String] = [:]
        var migratedAccounts: [CodexBarProviderAccount] = []
        var changed = false

        for stored in provider.accounts {
            guard stored.kind == .oauthTokens,
                  let accessToken = stored.accessToken,
                  accessToken.isEmpty == false else {
                migratedAccounts.append(stored)
                continue
            }

            let localAccountID = AccountBuilder.localAccountID(fromAccessToken: accessToken)
            let remoteAccountID = AccountBuilder.openAIAccountID(fromAccessToken: accessToken)
            var updated = stored

            if localAccountID.isEmpty == false, updated.id != localAccountID {
                migratedAccountIDs[updated.id] = localAccountID
                updated.id = localAccountID
                changed = true
            }

            if remoteAccountID.isEmpty == false, updated.openAIAccountId != remoteAccountID {
                updated.openAIAccountId = remoteAccountID
                changed = true
            }

            if let existingIndex = migratedAccounts.firstIndex(where: { $0.id == updated.id }) {
                migratedAccounts[existingIndex] = self.mergeOAuthAccount(
                    existing: migratedAccounts[existingIndex],
                    incoming: updated
                )
                changed = true
            } else {
                migratedAccounts.append(updated)
            }
        }

        provider.accounts = migratedAccounts
        config.providers[providerIndex] = provider
        config.remapOAuthAccountReferences(using: migratedAccountIDs)
        return (config, migratedAccountIDs, changed)
    }

    private func normalizeOpenRouterProviders(
        in original: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
        let request = PortableCoreOpenRouterNormalizationRequest(
            globalDefaultModel: original.global.defaultModel,
            recentOpenRouterModelID: self.recentOpenRouterModelResolver(),
            activeProviderID: original.active.providerId,
            activeAccountID: original.active.accountId,
            switchProviderID: original.openAI.switchModeSelection?.providerId,
            switchAccountID: original.openAI.switchModeSelection?.accountId,
            providers: original.providers.map(PortableCoreOpenRouterProviderInput.legacy(from:))
        )
        let result: PortableCoreOpenRouterNormalizationResult
        do {
            result = try RustPortableCoreAdapter.shared.normalizeOpenRouterProviders(
                request,
                buildIfNeeded: false
            )
        } catch {
            NSLog("codexbar openrouter normalization rust error: %@", error.localizedDescription)
            return (original, false)
        }
        guard let mergedProvider = result.mergedProvider else {
            return (original, false)
        }

        var config = original
        let removeIDs = Set(result.removeProviderIDs)
        config.providers.removeAll { removeIDs.contains($0.id) }
        config.providers.append(mergedProvider.provider())
        config.active.providerId = result.activeProviderID
        config.active.accountId = result.activeAccountID
        if result.switchProviderID != nil || result.switchAccountID != nil || config.openAI.switchModeSelection != nil {
            config.openAI.switchModeSelection = CodexBarActiveSelection(
                providerId: result.switchProviderID,
                accountId: result.switchAccountID
            )
        }
        return (config, result.changed)
    }

    private func legacyCompatiblePersistenceConfig(from original: CodexBarConfig) -> CodexBarConfig {
        var config = original
        guard let providerIndex = config.providers.firstIndex(where: { $0.kind == .openRouter }) else {
            return config
        }

        let runtimeProvider = config.providers[providerIndex]
        let request = PortableCoreOpenRouterCompatPersistenceRequest(
            provider: .legacy(from: runtimeProvider),
            activeProviderID: config.active.providerId,
            switchProviderID: config.openAI.switchModeSelection?.providerId
        )
        let result: PortableCoreOpenRouterCompatPersistenceResult
        do {
            result = try RustPortableCoreAdapter.shared.makeOpenRouterCompatPersistence(
                request,
                buildIfNeeded: false
            )
        } catch {
            NSLog("codexbar openrouter compat persistence rust error: %@", error.localizedDescription)
            return config
        }
        config.providers[providerIndex] = result.persistedProvider.provider()
        config.active.providerId = result.activeProviderID
        if config.active.providerId != result.activeProviderID,
           config.active.providerId == runtimeProvider.id {
            config.active.providerId = result.activeProviderID
        }
        config.openAI.switchModeSelection?.providerId = result.switchProviderID

        return config
    }

    private func normalizeReservedProviderIDs(
        in original: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
        if let result = try? RustPortableCoreAdapter.shared.normalizeReservedProviderIds(
            PortableCoreReservedProviderIdNormalizationRequest(
                activeProviderID: original.active.providerId,
                switchProviderID: original.openAI.switchModeSelection?.providerId,
                providers: original.providers.map {
                    PortableCoreReservedProviderIdInput(id: $0.id, kind: $0.kind.rawValue)
                }
            ),
            buildIfNeeded: false
        ),
        result.changed,
        result.providers.count == original.providers.count {
            var config = original
            for index in config.providers.indices {
                config.providers[index].id = result.providers[index].id
            }
            config.active.providerId = result.activeProviderID
            config.openAI.switchModeSelection?.providerId = result.switchProviderID
            return (config, true)
        }

        var config = original
        var changed = false

        for index in config.providers.indices {
            let provider = config.providers[index]
            guard provider.id == "openrouter",
                  provider.kind != .openRouter else {
                continue
            }

            let replacementID = self.nextAvailableProviderID(
                base: "openrouter-custom",
                excluding: provider.id,
                providers: config.providers
            )
            config.providers[index].id = replacementID

            if config.active.providerId == provider.id {
                config.active.providerId = replacementID
            }
            if config.openAI.switchModeSelection?.providerId == provider.id {
                config.openAI.switchModeSelection?.providerId = replacementID
            }
            changed = true
        }

        return (config, changed)
    }

    private func mergeOAuthAccount(
        existing: CodexBarProviderAccount,
        incoming: CodexBarProviderAccount
    ) -> CodexBarProviderAccount {
        var merged = incoming
        merged.label = existing.label
        merged.addedAt = existing.addedAt ?? incoming.addedAt
        merged.apiKey = incoming.apiKey ?? existing.apiKey
        merged.email = incoming.email ?? existing.email
        merged.expiresAt = incoming.expiresAt ?? existing.expiresAt
        merged.oauthClientID = incoming.oauthClientID ?? existing.oauthClientID
        merged.tokenLastRefreshAt = incoming.tokenLastRefreshAt ?? existing.tokenLastRefreshAt ?? existing.lastRefresh
        merged.lastRefresh = incoming.lastRefresh ?? existing.lastRefresh
        merged.primaryUsedPercent = incoming.primaryUsedPercent ?? existing.primaryUsedPercent
        merged.secondaryUsedPercent = incoming.secondaryUsedPercent ?? existing.secondaryUsedPercent
        merged.primaryResetAt = incoming.primaryResetAt ?? existing.primaryResetAt
        merged.secondaryResetAt = incoming.secondaryResetAt ?? existing.secondaryResetAt
        merged.primaryLimitWindowSeconds = incoming.primaryLimitWindowSeconds ?? existing.primaryLimitWindowSeconds
        merged.secondaryLimitWindowSeconds = incoming.secondaryLimitWindowSeconds ?? existing.secondaryLimitWindowSeconds
        merged.lastChecked = incoming.lastChecked ?? existing.lastChecked
        merged.isSuspended = incoming.isSuspended ?? existing.isSuspended
        merged.tokenExpired = incoming.tokenExpired ?? existing.tokenExpired
        merged.organizationName = incoming.organizationName ?? existing.organizationName
        merged.interopProxyKey = incoming.interopProxyKey ?? existing.interopProxyKey
        merged.interopNotes = incoming.interopNotes ?? existing.interopNotes
        merged.interopConcurrency = incoming.interopConcurrency ?? existing.interopConcurrency
        merged.interopPriority = incoming.interopPriority ?? existing.interopPriority
        merged.interopRateMultiplier = incoming.interopRateMultiplier ?? existing.interopRateMultiplier
        merged.interopAutoPauseOnExpired =
            incoming.interopAutoPauseOnExpired ??
            existing.interopAutoPauseOnExpired
        merged.interopCredentialsJSON =
            incoming.interopCredentialsJSON ??
            existing.interopCredentialsJSON
        merged.interopExtraJSON = incoming.interopExtraJSON ?? existing.interopExtraJSON
        return merged
    }

    func reconcileAuthJSON(
        in original: CodexBarConfig,
        onlyAccountIDs: Set<String>? = nil
    ) -> (config: CodexBarConfig, changed: Bool) {
        guard let snapshot = self.readAuthJSONSnapshot() else {
            return (original, false)
        }
        guard let providerIndex = original.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (original, false)
        }

        var config = original
        var provider = config.providers[providerIndex]
        if let result = try? RustPortableCoreAdapter.shared.reconcileOAuthAuthSnapshot(
            PortableCoreOAuthAuthReconciliationRequest(
                accounts: provider.accounts.map(PortableCoreOAuthStoredAccountInput.legacy(from:)),
                snapshot: .legacy(from: snapshot),
                onlyAccountIDs: Array(onlyAccountIDs ?? [])
            ),
            buildIfNeeded: false
        ),
           result.changed,
           let accountIndex = result.matchedIndex,
           let updatedAccount = result.updatedAccount?.providerAccount(),
           provider.accounts.indices.contains(accountIndex) {
            provider.accounts[accountIndex] = updatedAccount
            config.providers[providerIndex] = provider
            return (config, true)
        }

        guard let fallback = self.legacyReconciledOAuthAccount(
            in: provider.accounts,
            snapshot: snapshot,
            onlyAccountIDs: onlyAccountIDs
        ) else {
            return (config, false)
        }

        provider.accounts[fallback.index] = fallback.account
        config.providers[providerIndex] = provider
        return (config, true)
    }

    private func refreshOAuthAccountMetadata(
        in original: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
        var config = original
        guard let providerIndex = config.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (config, false)
        }

        if let result = try? RustPortableCoreAdapter.shared.refreshOAuthAccountMetadata(
            PortableCoreOAuthMetadataRefreshRequest(
                accounts: config.providers[providerIndex].accounts.map(
                    PortableCoreOAuthStoredAccountInput.legacy(from:)
                )
            ),
            buildIfNeeded: false
        ),
        result.changed {
            let existingAccountsByID = Dictionary(
                uniqueKeysWithValues: config.providers[providerIndex].accounts.map { ($0.id, $0) }
            )
            config.providers[providerIndex].accounts = result.accounts.map { refreshed in
                let updated = refreshed.providerAccount()
                guard let existing = existingAccountsByID[updated.id] else {
                    return updated
                }
                return self.mergeOAuthAccount(existing: existing, incoming: updated)
            }
            return (config, true)
        }

        var provider = config.providers[providerIndex]
        var changed = false
        provider.accounts = provider.accounts.map { stored in
            guard stored.kind == .oauthTokens,
                  let accessToken = stored.accessToken,
                  let refreshToken = stored.refreshToken,
                  let idToken = stored.idToken else {
                return stored
            }

            var refreshed = stored
            let rebuilt = AccountBuilder.build(
                from: OAuthTokens(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    idToken: idToken,
                    oauthClientID: stored.oauthClientID,
                    tokenLastRefreshAt: stored.tokenLastRefreshAt ?? stored.lastRefresh
                )
            )

            if refreshed.email == nil || refreshed.email?.isEmpty == true {
                refreshed.email = rebuilt.email.isEmpty ? refreshed.email : rebuilt.email
            }
            if refreshed.openAIAccountId == nil || refreshed.openAIAccountId?.isEmpty == true {
                refreshed.openAIAccountId = rebuilt.remoteAccountId
            }
            refreshed.expiresAt = rebuilt.expiresAt ?? refreshed.expiresAt
            refreshed.oauthClientID = rebuilt.oauthClientID ?? refreshed.oauthClientID
            refreshed.tokenLastRefreshAt = refreshed.tokenLastRefreshAt ?? refreshed.lastRefresh
            refreshed.lastRefresh = refreshed.tokenLastRefreshAt ?? refreshed.lastRefresh
            if refreshed != stored {
                changed = true
            }
            return refreshed
        }

        config.providers[providerIndex] = provider
        return (config, changed)
    }

    private func sanitizeOAuthQuotaSnapshots(
        in config: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
        var sanitizedConfig = config
        var changed = false

        for providerIndex in sanitizedConfig.providers.indices {
            guard sanitizedConfig.providers[providerIndex].kind == .openAIOAuth else { continue }
            var provider = sanitizedConfig.providers[providerIndex]
            provider.accounts = provider.accounts.map { account in
                let sanitized = account.sanitizedQuotaSnapshot()
                if sanitized != account {
                    changed = true
                }
                return sanitized
            }
            sanitizedConfig.providers[providerIndex] = provider
        }

        return (sanitizedConfig, changed)
    }

    private func normalizeSharedOpenAITeamOrganizationNames(
        in config: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
        guard let providerIndex = config.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (config, false)
        }

        if let result = try? RustPortableCoreAdapter.shared.normalizeSharedTeamOrganizationNames(
            PortableCoreSharedTeamOrganizationNormalizationRequest(
                accounts: config.providers[providerIndex].accounts.map(
                    PortableCoreOAuthStoredAccountInput.legacy(from:)
                )
            ),
            buildIfNeeded: false
        ),
        result.changed {
            var normalizedConfig = config
            normalizedConfig.providers[providerIndex].accounts = result.accounts.map { $0.providerAccount() }
            return (normalizedConfig, true)
        }

        var normalizedConfig = config
        let changed = normalizedConfig.normalizeSharedOpenAITeamOrganizationNames()
        return (normalizedConfig, changed)
    }

    private func uniqueOAuthAccount(
        in provider: CodexBarProvider,
        matchingRemoteAccountID accountID: String
    ) -> CodexBarProviderAccount? {
        guard accountID.isEmpty == false else { return nil }
        let matches = provider.accounts.filter { $0.openAIAccountId == accountID }
        return matches.count == 1 ? matches[0] : nil
    }

    private func readAuthJSONSnapshot() -> OpenAIAuthJSONSnapshot? {
        guard let text = self.readAuthJSONText() else {
            return nil
        }

        do {
            return try RustPortableCoreAdapter.shared.parseAuthJsonSnapshot(
                PortableCoreAuthJSONSnapshotParseRequest(text: text),
                buildIfNeeded: false
            ).snapshot?.openAIAuthJSONSnapshot()
        } catch {
            NSLog("codexbar auth json snapshot rust error: %@", error.localizedDescription)
            return nil
        }
    }

    private func accountFromAuthSnapshot(_ snapshot: OpenAIAuthJSONSnapshot) -> CodexBarProviderAccount {
        var stored = CodexBarProviderAccount.fromTokenAccount(
            snapshot.account,
            existingID: snapshot.localAccountID
        )
        stored.openAIAccountId = snapshot.remoteAccountID
        stored.email = snapshot.email ?? stored.email
        stored.label = stored.email ?? String(stored.id.prefix(8))
        stored.tokenLastRefreshAt = snapshot.tokenLastRefreshAt ?? stored.tokenLastRefreshAt
        stored.lastRefresh = stored.tokenLastRefreshAt ?? stored.lastRefresh
        return stored
    }

    private func legacyReconciledOAuthAccount(
        in accounts: [CodexBarProviderAccount],
        snapshot: OpenAIAuthJSONSnapshot,
        onlyAccountIDs: Set<String>?
    ) -> (index: Int, account: CodexBarProviderAccount)? {
        let eligibleAccounts: [(offset: Int, element: CodexBarProviderAccount)] = accounts.enumerated().filter { pair in
            pair.element.kind == .oauthTokens &&
                (onlyAccountIDs == nil || onlyAccountIDs?.contains(pair.element.id) == true)
        }

        let matchedIndex: Int?
        if snapshot.localAccountID.isEmpty == false,
           let localMatch = eligibleAccounts.first(where: { $0.element.id == snapshot.localAccountID }) {
            matchedIndex = localMatch.offset
        } else {
            guard snapshot.remoteAccountID.isEmpty == false else { return nil }
            let remoteMatches = eligibleAccounts.filter {
                ($0.element.openAIAccountId ?? $0.element.id) == snapshot.remoteAccountID
            }
            if remoteMatches.count == 1 {
                matchedIndex = remoteMatches[0].offset
            } else if let email = snapshot.email?.lowercased(), remoteMatches.isEmpty == false {
                let emailMatches = remoteMatches.filter { pair in
                    pair.element.email?.lowercased() == email
                }
                matchedIndex = emailMatches.count == 1 ? emailMatches[0].offset : nil
            } else {
                matchedIndex = nil
            }
        }

        guard let matchedIndex else { return nil }
        let stored = accounts[matchedIndex]
        let localLastRefresh = stored.tokenLastRefreshAt ?? stored.lastRefresh
        let isLater: (Date?, Date?) -> Bool = { lhs, rhs in
            switch (lhs, rhs) {
            case let (lhs?, rhs?):
                return lhs > rhs
            case (.some, .none):
                return true
            default:
                return false
            }
        }
        let tokenTupleChanged =
            stored.accessToken != snapshot.account.accessToken ||
            stored.refreshToken != snapshot.account.refreshToken ||
            stored.idToken != snapshot.account.idToken
        let shouldAbsorb =
            isLater(snapshot.tokenLastRefreshAt, localLastRefresh) ||
            isLater(snapshot.account.expiresAt, stored.expiresAt) ||
            isLater(snapshot.account.tokenLastRefreshAt, localLastRefresh) ||
            (tokenTupleChanged && stored.tokenExpired == true)
        guard shouldAbsorb else { return nil }

        var updated = stored
        updated.accessToken = snapshot.account.accessToken
        if snapshot.account.refreshToken.isEmpty == false {
            updated.refreshToken = snapshot.account.refreshToken
        }
        if snapshot.account.idToken.isEmpty == false {
            updated.idToken = snapshot.account.idToken
        }
        updated.email = snapshot.email ?? updated.email
        updated.openAIAccountId = snapshot.remoteAccountID
        updated.expiresAt = snapshot.account.expiresAt ?? updated.expiresAt
        updated.oauthClientID = snapshot.account.oauthClientID ?? updated.oauthClientID
        updated.tokenLastRefreshAt =
            snapshot.tokenLastRefreshAt ??
            snapshot.account.tokenLastRefreshAt ??
            updated.tokenLastRefreshAt ??
            updated.lastRefresh
        updated.lastRefresh = updated.tokenLastRefreshAt ?? updated.lastRefresh
        updated.tokenExpired = false
        return (matchedIndex, updated)
    }

    private func readLegacyToml() -> LegacyCodexTomlSnapshot {
        guard let text = try? String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8) else {
            return LegacyCodexTomlSnapshot()
        }
        do {
            return try RustPortableCoreAdapter.shared.parseLegacyCodexToml(
                PortableCoreLegacyCodexTomlParseRequest(text: text),
                buildIfNeeded: false
            ).legacySnapshot()
        } catch {
            NSLog("codexbar legacy toml parse rust error: %@", error.localizedDescription)
            return LegacyCodexTomlSnapshot()
        }
    }

    private nonisolated static func defaultRecentOpenRouterModelIdentifier() -> String? {
        do {
            let result = try RustPortableCoreAdapter.shared.resolveRecentOpenRouterModel(
                PortableCoreRecentOpenRouterModelRequest(
                    rootPaths: [
                        CodexPaths.sessionsRootURL.path,
                        CodexPaths.archivedSessionsRootURL.path,
                    ]
                ),
                buildIfNeeded: false
            )
            return result.modelId
        } catch {
            NSLog("codexbar recent openrouter model rust error: %@", error.localizedDescription)
            return nil
        }
    }

    private func nextAvailableProviderID(
        base: String,
        excluding currentID: String,
        providers: [CodexBarProvider]
    ) -> String {
        var candidate = base
        var suffix = 2
        let existingIDs = Set(providers.map(\.id).filter { $0 != currentID })

        while existingIDs.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }

        return candidate
    }

    private func readAuthJSON() -> [String: Any] {
        guard let data = try? Data(contentsOf: CodexPaths.authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func readAuthJSONText() -> String? {
        guard let data = try? Data(contentsOf: CodexPaths.authURL) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func readProviderSecrets() -> [String: String] {
        guard let text = try? String(contentsOf: CodexPaths.providerSecretsURL, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("export ") else { continue }
            let body = String(line.dropFirst("export ".count))
            let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    private func slug(from label: String) -> String {
        let lowered = label.lowercased()
        let slug = lowered.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "provider-\(UUID().uuidString.lowercased())" : slug
    }

    private func backupForeignConfig() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = CodexPaths.codexBarRoot.appendingPathComponent("config.foreign-backup-\(stamp).json")
        try CodexPaths.backupFileIfPresent(from: CodexPaths.barConfigURL, to: backupURL)
        try? FileManager.default.removeItem(at: CodexPaths.barConfigURL)
    }
}
