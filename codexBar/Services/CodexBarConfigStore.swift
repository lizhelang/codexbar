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
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                let stamp = formatter.string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let backupURL = CodexPaths.codexBarRoot.appendingPathComponent("config.foreign-backup-\(stamp).json")
                if FileManager.default.fileExists(atPath: CodexPaths.barConfigURL.path) {
                    let data = try Data(contentsOf: CodexPaths.barConfigURL)
                    try CodexPaths.writeSecureFile(data, to: backupURL)
                }
                try? FileManager.default.removeItem(at: CodexPaths.barConfigURL)
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
        let toml: LegacyCodexTomlSnapshot
        if let text = try? String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8) {
            do {
                toml = try RustPortableCoreAdapter.shared.parseLegacyCodexToml(
                    PortableCoreLegacyCodexTomlParseRequest(text: text),
                    buildIfNeeded: false
                ).legacySnapshot()
            } catch {
                NSLog("codexbar legacy toml parse rust error: %@", error.localizedDescription)
                toml = LegacyCodexTomlSnapshot()
            }
        } else {
            toml = LegacyCodexTomlSnapshot()
        }
        let authParseResult = self.readAuthJSONSnapshotParseResult()
        let authSnapshot = authParseResult?.snapshot?.openAIAuthJSONSnapshot()
        let authAPIKey = authParseResult?.openAIAPIKey
        let envSecrets: [String: String]
        if let text = try? String(contentsOf: CodexPaths.providerSecretsURL, encoding: .utf8) {
            do {
                envSecrets = try RustPortableCoreAdapter.shared.parseProviderSecretsEnv(
                    PortableCoreProviderSecretsEnvParseRequest(text: text),
                    buildIfNeeded: false
                ).values
            } catch {
                NSLog("codexbar provider secrets rust parse error: %@", error.localizedDescription)
                envSecrets = [:]
            }
        } else {
            envSecrets = [:]
        }

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

        if let authAPIKey,
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
            hasOpenAIAPIKey: authAPIKey?.isEmpty == false,
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
        let request = PortableCoreOAuthProviderAssemblyRequest(
            importedAccounts: importedAccounts.map(PortableCoreOAuthStoredAccountInput.legacy(from:)),
            snapshot: authSnapshot.map(PortableCoreAuthJSONSnapshotInput.legacy(from:))
        )
        let result =
            (try? RustPortableCoreAdapter.shared.assembleOAuthProvider(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreOAuthProviderAssemblyResult(
                shouldCreate: importedAccounts.isEmpty == false,
                activeAccountID: importedAccounts.first?.id,
                accounts: importedAccounts.map(PortableCoreOAuthStoredAccountInput.legacy(from:))
            )

        guard result.shouldCreate else { return nil }

        let accounts = result.accounts.map { $0.providerAccount() }
        return CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            baseURL: nil,
            activeAccountId: result.activeAccountID,
            accounts: accounts
        )
    }

    private func makeImportedProviderIfNeeded(
        baseURL: String?,
        apiKey: String,
        existingProviders: [CodexBarProvider]
    ) -> CodexBarProvider? {
        let request = PortableCoreLegacyImportedProviderPlanRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            existingBaseURLs: existingProviders.compactMap(\.baseURL)
        )
        let result = (try? RustPortableCoreAdapter.shared.planLegacyImportedProvider(
            request,
            buildIfNeeded: false
        )) ?? PortableCoreLegacyImportedProviderPlanResult.failClosed(request: request)
        guard result.shouldCreate,
              let normalizedBaseURL = result.normalizedBaseURL,
              let label = result.label,
              let providerID = result.providerId else {
            return nil
        }
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: result.accountLabel ?? "Imported",
            apiKey: apiKey,
            addedAt: Date()
        )
        return CodexBarProvider(
            id: providerID,
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
        hasOpenAIAPIKey: Bool,
        authSnapshot: OpenAIAuthJSONSnapshot?,
        providers: [CodexBarProvider]
    ) -> CodexBarActiveSelection {
        let request = PortableCoreLegacyMigrationActiveSelectionRequest(
            openAIBaseURL: toml.openAIBaseURL,
            hasOpenAIAPIKey: hasOpenAIAPIKey,
            authSnapshotLocalAccountId: authSnapshot?.localAccountID,
            authSnapshotRemoteAccountId: authSnapshot?.remoteAccountID,
            providers: providers.map(PortableCoreLegacyMigrationProviderInput.legacy(from:))
        )
        let result =
            (try? RustPortableCoreAdapter.shared.resolveLegacyMigrationActiveSelection(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreLegacyMigrationActiveSelectionResult.failClosed(request: request)
        return result.activeSelection()
    }

    private func normalizeOAuthAccountIdentities(
        in original: CodexBarConfig
    ) -> (config: CodexBarConfig, migratedAccountIDs: [String: String], changed: Bool) {
        var config = original
        guard let providerIndex = config.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (config, [:], false)
        }

        let result: PortableCoreOAuthIdentityNormalizationResult
        do {
            result = try RustPortableCoreAdapter.shared.normalizeOAuthAccountIdentities(
                PortableCoreOAuthIdentityNormalizationRequest(
                    accounts: config.providers[providerIndex].accounts.map(
                        PortableCoreOAuthStoredAccountInput.legacy(from:)
                    )
                ),
                buildIfNeeded: false
            )
        } catch {
            NSLog("codexbar oauth identity normalization rust error: %@", error.localizedDescription)
            return (config, [:], false)
        }

        guard result.changed else {
            return (config, [:], false)
        }

        config.providers[providerIndex].accounts = result.accounts.map { $0.providerAccount() }
        config.remapOAuthAccountReferences(using: result.migratedAccountIDs)
        return (config, result.migratedAccountIDs, true)
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
        guard let result = try? RustPortableCoreAdapter.shared.normalizeReservedProviderIds(
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
        result.providers.count == original.providers.count else {
            return (original, false)
        }

        var config = original
        for index in config.providers.indices {
            config.providers[index].id = result.providers[index].id
        }
        config.active.providerId = result.activeProviderID
        config.openAI.switchModeSelection?.providerId = result.switchProviderID
        return (config, true)
    }

    func reconcileAuthJSON(
        in original: CodexBarConfig,
        onlyAccountIDs: Set<String>? = nil
    ) -> (config: CodexBarConfig, changed: Bool) {
        guard let snapshot = self.readAuthJSONSnapshotParseResult()?.snapshot?.openAIAuthJSONSnapshot() else {
            return (original, false)
        }
        guard let providerIndex = original.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (original, false)
        }

        guard let result = try? RustPortableCoreAdapter.shared.reconcileOAuthAuthSnapshot(
            PortableCoreOAuthAuthReconciliationRequest(
                accounts: original.providers[providerIndex].accounts.map(PortableCoreOAuthStoredAccountInput.legacy(from:)),
                snapshot: .legacy(from: snapshot),
                onlyAccountIDs: Array(onlyAccountIDs ?? [])
            ),
            buildIfNeeded: false
        ),
        result.changed,
        let accountIndex = result.matchedIndex,
        let updatedAccount = result.updatedAccount?.providerAccount(),
        original.providers[providerIndex].accounts.indices.contains(accountIndex) else {
            return (original, false)
        }

        var config = original
        var provider = config.providers[providerIndex]
        provider.accounts[accountIndex] = updatedAccount
        config.providers[providerIndex] = provider
        return (config, true)
    }

    private func refreshOAuthAccountMetadata(
        in original: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
        guard let providerIndex = original.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (original, false)
        }

        guard let result = try? RustPortableCoreAdapter.shared.refreshOAuthAccountMetadata(
            PortableCoreOAuthMetadataRefreshRequest(
                accounts: original.providers[providerIndex].accounts.map(
                    PortableCoreOAuthStoredAccountInput.legacy(from:)
                )
            ),
            buildIfNeeded: false
        ),
        result.changed else {
            return (original, false)
        }

        var config = original
        config.providers[providerIndex].accounts = result.accounts.map { $0.providerAccount() }
        return (config, true)
    }

    private func sanitizeOAuthQuotaSnapshots(
        in config: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
        guard let providerIndex = config.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (config, false)
        }

        let result: PortableCoreOAuthQuotaSnapshotSanitizationResult
        do {
            result = try RustPortableCoreAdapter.shared.sanitizeOAuthQuotaSnapshots(
                PortableCoreOAuthQuotaSnapshotSanitizationRequest(
                    now: Date().timeIntervalSince1970,
                    accounts: config.providers[providerIndex].accounts.map(
                        PortableCoreOAuthStoredAccountInput.legacy(from:)
                    )
                ),
                buildIfNeeded: false
            )
        } catch {
            NSLog("codexbar oauth quota snapshot rust error: %@", error.localizedDescription)
            return (config, false)
        }

        guard result.changed else {
            return (config, false)
        }

        var sanitizedConfig = config
        sanitizedConfig.providers[providerIndex].accounts = result.accounts.map { $0.providerAccount() }
        return (sanitizedConfig, true)
    }

    private func normalizeSharedOpenAITeamOrganizationNames(
        in config: CodexBarConfig
    ) -> (config: CodexBarConfig, changed: Bool) {
        guard let providerIndex = config.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return (config, false)
        }

        guard let result = try? RustPortableCoreAdapter.shared.normalizeSharedTeamOrganizationNames(
            PortableCoreSharedTeamOrganizationNormalizationRequest(
                accounts: config.providers[providerIndex].accounts.map(
                    PortableCoreOAuthStoredAccountInput.legacy(from:)
                )
            ),
            buildIfNeeded: false
        ),
        result.changed else {
            return (config, false)
        }

        var normalizedConfig = config
        normalizedConfig.providers[providerIndex].accounts = result.accounts.map { $0.providerAccount() }
        return (normalizedConfig, true)
    }

    private func readAuthJSONSnapshotParseResult() -> PortableCoreAuthJSONSnapshotParseResult? {
        guard let data = try? Data(contentsOf: CodexPaths.authURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        do {
            return try RustPortableCoreAdapter.shared.parseAuthJsonSnapshot(
                PortableCoreAuthJSONSnapshotParseRequest(text: text),
                buildIfNeeded: false
            )
        } catch {
            NSLog("codexbar auth json snapshot rust error: %@", error.localizedDescription)
            return nil
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

}
