import Foundation

protocol CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws
}

enum CodexSyncError: LocalizedError {
    case missingActiveProvider
    case missingActiveAccount

    var errorDescription: String? {
        switch self {
        case .missingActiveProvider: return "未找到当前激活的 provider"
        case .missingActiveAccount: return "未找到当前激活的账号"
        }
    }
}

struct CodexSyncService: CodexSynchronizing {
    private let ensureDirectories: () throws -> Void
    private let backupFileIfPresent: (URL, URL) throws -> Void
    private let writeSecureFile: (Data, URL) throws -> Void
    private let readString: (URL) -> String?
    private let readData: (URL) -> Data?
    private let fileExists: (URL) -> Bool
    private let removeFileIfPresent: (URL) throws -> Void

    init(
        ensureDirectories: @escaping () throws -> Void = { try CodexPaths.ensureDirectories() },
        backupFileIfPresent: @escaping (URL, URL) throws -> Void = { source, destination in
            try CodexPaths.backupFileIfPresent(from: source, to: destination)
        },
        writeSecureFile: @escaping (Data, URL) throws -> Void = { data, url in
            try CodexPaths.writeSecureFile(data, to: url)
        },
        readString: @escaping (URL) -> String? = { url in
            try? String(contentsOf: url, encoding: .utf8)
        },
        readData: @escaping (URL) -> Data? = { url in
            try? Data(contentsOf: url)
        },
        fileExists: @escaping (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        removeFileIfPresent: @escaping (URL) throws -> Void = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    ) {
        self.ensureDirectories = ensureDirectories
        self.backupFileIfPresent = backupFileIfPresent
        self.writeSecureFile = writeSecureFile
        self.readString = readString
        self.readData = readData
        self.fileExists = fileExists
        self.removeFileIfPresent = removeFileIfPresent
    }

    func synchronize(config: CodexBarConfig) throws {
        guard let provider = config.activeProvider() else { throw CodexSyncError.missingActiveProvider }
        guard let account = config.activeAccount() else { throw CodexSyncError.missingActiveAccount }

        let previousAuthData = self.readData(CodexPaths.authURL)
        let previousTomlData = self.readData(CodexPaths.configTomlURL)
        let existingTomlText = self.readString(CodexPaths.configTomlURL) ?? ""

        try self.ensureDirectories()
        try self.backupFileIfPresent(CodexPaths.configTomlURL, CodexPaths.configBackupURL)
        try self.backupFileIfPresent(CodexPaths.authURL, CodexPaths.authBackupURL)

        let canonical = try RustPortableCoreAdapter.shared.canonicalizeConfigAndAccounts(
            PortableCoreRawConfigInput.legacy(from: config),
            buildIfNeeded: true
        )
        let rendered = try RustPortableCoreAdapter.shared.renderCodecBundle(
            PortableCoreRenderCodecRequest(
                config: canonical.config,
                activeProviderID: provider.id,
                activeAccountID: account.id,
                existingTOMLText: existingTomlText
            ),
            buildIfNeeded: false
        )
        let authData = Data(rendered.authJSON.utf8)
        let tomlData = Data(rendered.configTOML.utf8)

        do {
            try self.writeSecureFile(authData, CodexPaths.authURL)
            try self.writeSecureFile(tomlData, CodexPaths.configTomlURL)
        } catch {
            try? self.restoreSnapshot(previousAuthData, at: CodexPaths.authURL)
            try? self.restoreSnapshot(previousTomlData, at: CodexPaths.configTomlURL)
            throw error
        }
    }

    private func restoreSnapshot(_ snapshot: Data?, at url: URL) throws {
        if let snapshot {
            try self.writeSecureFile(snapshot, url)
        } else if self.fileExists(url) {
            try self.removeFileIfPresent(url)
        }
    }
}
