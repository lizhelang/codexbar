import Foundation

enum CodexPaths {
    static var realHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEXBAR_HOME"],
           override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pwDir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var codexRoot: URL {
        self.realHome.appendingPathComponent(".codex", isDirectory: true)
    }

    static var codexBarRoot: URL {
        self.realHome.appendingPathComponent(".codexbar", isDirectory: true)
    }

    static var authURL: URL { self.codexRoot.appendingPathComponent("auth.json") }
    static var tokenPoolURL: URL { self.codexRoot.appendingPathComponent("token_pool.json") }
    static var configTomlURL: URL { self.codexRoot.appendingPathComponent("config.toml") }
    static var providerSecretsURL: URL { self.codexRoot.appendingPathComponent("provider-secrets.env") }
    static var oauthFlowsDirectoryURL: URL { self.codexBarRoot.appendingPathComponent("oauth-flows", isDirectory: true) }

    static var barConfigURL: URL { self.codexBarRoot.appendingPathComponent("config.json") }
    static var costCacheURL: URL { self.codexBarRoot.appendingPathComponent("cost-cache.json") }
    static var costSessionCacheURL: URL { self.codexBarRoot.appendingPathComponent("cost-session-cache.json") }
    static var switchJournalURL: URL { self.codexBarRoot.appendingPathComponent("switch-journal.jsonl") }

    static var configBackupURL: URL { self.codexRoot.appendingPathComponent("config.toml.bak-codexbar-last") }
    static var authBackupURL: URL { self.codexRoot.appendingPathComponent("auth.json.bak-codexbar-last") }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: self.codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexBarRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.oauthFlowsDirectoryURL, withIntermediateDirectories: true)
    }

    static func writeSecureFile(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString + ".tmp")
        try data.write(to: tempURL, options: .atomic)
        try self.applySecurePermissions(to: tempURL)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
        try self.applySecurePermissions(to: url)
    }

    static func backupFileIfPresent(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        try self.writeSecureFile(data, to: destination)
    }

    private static func applySecurePermissions(to url: URL) throws {
        try FileManager.default.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: url.path)
    }
}
