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

    init(switchJournalStore: SwitchJournalStore = SwitchJournalStore()) {
        self.switchJournalStore = switchJournalStore
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
        let data = try self.encoder.encode(config)
        try CodexPaths.writeSecureFile(data, to: CodexPaths.barConfigURL)
    }

    private func migrateFromLegacy() throws -> CodexBarConfig {
        let toml = self.readLegacyToml()
        let auth = self.readAuthJSON()
        let envSecrets = self.readProviderSecrets()

        var providers: [CodexBarProvider] = []

        if let oauthProvider = self.makeOAuthProvider(auth: auth) {
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
            providers: providers
        )

        return CodexBarConfig(
            version: 1,
            global: global,
            active: active,
            providers: providers
        )
    }

    private func makeOAuthProvider(auth: [String: Any]) -> CodexBarProvider? {
        var importedAccounts: [CodexBarProviderAccount] = []

        if let data = try? Data(contentsOf: CodexPaths.tokenPoolURL),
           let pool = try? self.decoder.decode(TokenPool.self, from: data) {
            importedAccounts = pool.accounts.map { account in
                CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
            }
        }

        if let imported = self.authJSONSnapshot(from: auth).map(self.accountFromAuthSnapshot) {
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
        providers: [CodexBarProvider]
    ) -> CodexBarActiveSelection {
        if let baseURL = toml.openAIBaseURL,
           let provider = providers.first(where: { $0.baseURL == baseURL }) {
            return CodexBarActiveSelection(providerId: provider.id, accountId: provider.activeAccount?.id)
        }

        if let snapshot = self.authJSONSnapshot(from: auth),
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
        var config = original
        let matchingProviders = config.providers.filter {
            $0.kind == .openRouter || self.isLegacyOpenRouterProvider($0)
        }
        guard matchingProviders.isEmpty == false else {
            return (config, false)
        }

        var mergedProvider = matchingProviders.first(where: { $0.kind == .openRouter }) ?? CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true
        )
        let matchingIDs = Set(matchingProviders.map(\.id))
        let previousActiveProviderID = config.active.providerId
        let previousActiveAccountID = config.active.accountId
        var changed = matchingProviders.contains { $0.kind != .openRouter }
        var resolvedActiveAccountID: String?
        var seenAccountKeys: Set<String> = []
        var mergedAccounts: [CodexBarProviderAccount] = []

        for provider in matchingProviders {
            if mergedProvider.defaultModel == nil {
                mergedProvider.defaultModel = provider.defaultModel
                    ?? self.inferOpenRouterModel(from: provider.baseURL)
            }

            for account in provider.accounts {
                let dedupeKey = self.openRouterAccountDeduplicationKey(for: account)
                guard seenAccountKeys.insert(dedupeKey).inserted else {
                    continue
                }
                mergedAccounts.append(account)
            }

            if previousActiveProviderID == provider.id {
                resolvedActiveAccountID = previousActiveAccountID ?? provider.activeAccountId
            }
        }

        if mergedProvider.defaultModel == nil,
           let inferredModel = self.validOpenRouterModelIdentifier(config.global.defaultModel) {
            mergedProvider.defaultModel = inferredModel
            changed = true
        }

        mergedProvider.accounts = mergedAccounts
        if let resolvedActiveAccountID,
           mergedAccounts.contains(where: { $0.id == resolvedActiveAccountID }) {
            mergedProvider.activeAccountId = resolvedActiveAccountID
        } else {
            let fallbackAccountID = mergedAccounts.first?.id
            if mergedProvider.activeAccountId != fallbackAccountID {
                changed = true
            }
            mergedProvider.activeAccountId = fallbackAccountID
        }

        config.providers.removeAll { matchingIDs.contains($0.id) }
        config.providers.append(mergedProvider)

        if let previousActiveProviderID,
           matchingIDs.contains(previousActiveProviderID) {
            if config.active.providerId != mergedProvider.id || config.active.accountId != mergedProvider.activeAccountId {
                changed = true
            }
            config.active.providerId = mergedProvider.id
            config.active.accountId = mergedProvider.activeAccountId
        }

        return (config, changed)
    }

    private func normalizeReservedProviderIDs(
        in original: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
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
        return merged
    }

    func reconcileAuthJSON(
        in original: CodexBarConfig,
        onlyAccountIDs: Set<String>? = nil
    ) -> (config: CodexBarConfig, changed: Bool) {
        guard let snapshot = self.authJSONSnapshot(from: self.readAuthJSON()) else {
            return (original, false)
        }
        guard let providerIndex = original.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (original, false)
        }

        var config = original
        var provider = config.providers[providerIndex]
        guard let accountIndex = self.matchingStoredAccountIndex(
            in: provider.accounts,
            snapshot: snapshot,
            onlyAccountIDs: onlyAccountIDs
        ) else {
            return (config, false)
        }

        let existing = provider.accounts[accountIndex]
        guard self.shouldAbsorbAuthSnapshot(snapshot, into: existing) else {
            return (config, false)
        }

        provider.accounts[accountIndex] = self.absorbAuthSnapshot(snapshot, into: existing)
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

    private func authJSONSnapshot(from auth: [String: Any]) -> OpenAIAuthJSONSnapshot? {
        guard let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String,
              let idToken = tokens["id_token"] as? String else {
            return nil
        }

        let lastRefresh = self.parseISO8601Date(auth["last_refresh"] as? String)
        let clientID = (auth["client_id"] as? String)
            ?? (tokens["client_id"] as? String)
            ?? (AccountBuilder.decodeJWT(accessToken)["client_id"] as? String)

        var account = AccountBuilder.build(
            from: OAuthTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                oauthClientID: clientID,
                tokenLastRefreshAt: lastRefresh
            )
        )

        let fallbackRemoteAccountID = tokens["account_id"] as? String ?? ""
        if account.accountId.isEmpty {
            account.accountId = AccountBuilder.localAccountID(fromAccessToken: accessToken)
        }
        if account.accountId.isEmpty {
            account.accountId = fallbackRemoteAccountID
        }
        if account.openAIAccountId.isEmpty {
            account.openAIAccountId = fallbackRemoteAccountID.isEmpty ? account.accountId : fallbackRemoteAccountID
        }
        account.oauthClientID = clientID ?? account.oauthClientID
        account.tokenLastRefreshAt = lastRefresh ?? account.tokenLastRefreshAt

        guard account.accountId.isEmpty == false || account.remoteAccountId.isEmpty == false else {
            return nil
        }

        return OpenAIAuthJSONSnapshot(
            account: account,
            localAccountID: account.accountId,
            remoteAccountID: account.remoteAccountId,
            email: account.email.isEmpty ? nil : account.email,
            tokenLastRefreshAt: lastRefresh ?? account.tokenLastRefreshAt
        )
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

    private func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, value.isEmpty == false else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func matchingStoredAccountIndex(
        in accounts: [CodexBarProviderAccount],
        snapshot: OpenAIAuthJSONSnapshot,
        onlyAccountIDs: Set<String>?
    ) -> Int? {
        let eligibleAccounts: [(offset: Int, element: CodexBarProviderAccount)] = accounts.enumerated().filter { pair in
            pair.element.kind == .oauthTokens &&
                (onlyAccountIDs == nil || onlyAccountIDs?.contains(pair.element.id) == true)
        }

        if snapshot.localAccountID.isEmpty == false,
           let localMatch = eligibleAccounts.first(where: { $0.element.id == snapshot.localAccountID }) {
            return localMatch.offset
        }

        guard snapshot.remoteAccountID.isEmpty == false else { return nil }
        let remoteMatches = eligibleAccounts.filter {
            ($0.element.openAIAccountId ?? $0.element.id) == snapshot.remoteAccountID
        }
        if remoteMatches.count == 1 {
            return remoteMatches[0].offset
        }

        guard let email = snapshot.email?.lowercased(), remoteMatches.isEmpty == false else {
            return nil
        }
        let emailMatches = remoteMatches.filter { pair in
            pair.element.email?.lowercased() == email
        }
        return emailMatches.count == 1 ? emailMatches[0].offset : nil
    }

    private func shouldAbsorbAuthSnapshot(
        _ snapshot: OpenAIAuthJSONSnapshot,
        into stored: CodexBarProviderAccount
    ) -> Bool {
        let localLastRefresh = stored.tokenLastRefreshAt ?? stored.lastRefresh
        if self.isLater(snapshot.tokenLastRefreshAt, than: localLastRefresh) {
            return true
        }
        if self.isLater(snapshot.account.expiresAt, than: stored.expiresAt) {
            return true
        }
        if self.isLater(snapshot.account.tokenLastRefreshAt, than: localLastRefresh) {
            return true
        }

        let tokenTupleChanged =
            stored.accessToken != snapshot.account.accessToken ||
            stored.refreshToken != snapshot.account.refreshToken ||
            stored.idToken != snapshot.account.idToken
        return tokenTupleChanged && stored.tokenExpired == true
    }

    private func absorbAuthSnapshot(
        _ snapshot: OpenAIAuthJSONSnapshot,
        into stored: CodexBarProviderAccount
    ) -> CodexBarProviderAccount {
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
        updated.tokenLastRefreshAt = snapshot.tokenLastRefreshAt ?? snapshot.account.tokenLastRefreshAt ?? updated.tokenLastRefreshAt ?? updated.lastRefresh
        updated.lastRefresh = updated.tokenLastRefreshAt ?? updated.lastRefresh
        updated.tokenExpired = false
        return updated
    }

    private func isLater(_ lhs: Date?, than rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs > rhs
        case (.some, .none):
            return true
        default:
            return false
        }
    }

    private func readLegacyToml() -> LegacyCodexTomlSnapshot {
        guard let text = try? String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8) else {
            return LegacyCodexTomlSnapshot()
        }
        return LegacyCodexTomlSnapshot(
            model: self.matchValue(for: "model", in: text),
            reviewModel: self.matchValue(for: "review_model", in: text),
            reasoningEffort: self.matchValue(for: "model_reasoning_effort", in: text),
            openAIBaseURL: self.matchOpenAIBaseURL(in: text)
        )
    }

    private func matchValue(for key: String, in text: String) -> String? {
        let pattern = #"(?m)^\#(key)\s*=\s*"([^"]+)""#
        let resolved = pattern.replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))
        guard let regex = try? NSRegularExpression(pattern: resolved) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    private func matchOpenAIBaseURL(in text: String) -> String? {
        if let explicitBaseURL = self.matchValue(for: "openai_base_url", in: text) {
            return explicitBaseURL
        }

        return self.matchBaseURLInProviderBlock(in: text, key: "OpenAI")
            ?? self.matchBaseURLInProviderBlock(in: text, key: "openai")
    }

    private func matchBaseURLInProviderBlock(in text: String, key: String) -> String? {
        guard let blockRegex = try? NSRegularExpression(
            pattern: #"(?ms)^\[model_providers\.#(key)\]\n(.*?)(?=^\[|\Z)"#
                .replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))
        ),
        let baseRegex = try? NSRegularExpression(pattern: #"(?m)^base_url\s*=\s*"([^"]+)""#) else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        guard let block = blockRegex.firstMatch(in: text, range: range),
              let blockRange = Range(block.range(at: 1), in: text) else { return nil }
        let body = String(text[blockRange])
        let bodyRange = NSRange(body.startIndex..., in: body)
        guard let baseMatch = baseRegex.firstMatch(in: body, range: bodyRange),
              let valueRange = Range(baseMatch.range(at: 1), in: body) else { return nil }
        return String(body[valueRange])
    }

    private func isLegacyOpenRouterProvider(_ provider: CodexBarProvider) -> Bool {
        guard provider.kind == .openAICompatible,
              let baseURL = provider.baseURL,
              let url = URL(string: baseURL),
              url.host?.lowercased() == "openrouter.ai" else {
            return false
        }

        let components = self.openRouterPathComponents(from: url.path)
        if components == ["api", "v1"] {
            return true
        }

        return components.count == 3 && components.last?.lowercased() == "api"
    }

    private func inferOpenRouterModel(from baseURL: String?) -> String? {
        guard let baseURL,
              let url = URL(string: baseURL),
              url.host?.lowercased() == "openrouter.ai" else {
            return nil
        }

        let components = self.openRouterPathComponents(from: url.path)
        guard components.count == 3,
              components[2].lowercased() == "api" else {
            return nil
        }

        return self.validOpenRouterModelIdentifier("\(components[0])/\(components[1])")
    }

    private func openRouterPathComponents(from path: String) -> [String] {
        path.split(separator: "/")
            .map(String.init)
            .filter { $0.isEmpty == false }
    }

    private func validOpenRouterModelIdentifier(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false,
              trimmed.contains("/"),
              trimmed.contains(" ") == false else {
            return nil
        }
        return trimmed
    }

    private func openRouterAccountDeduplicationKey(for account: CodexBarProviderAccount) -> String {
        if let apiKey = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           apiKey.isEmpty == false {
            return apiKey
        }
        return account.id
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
