import Foundation

enum CodexPaths {
    private static let stateSQLiteDefaultVersion = 5
    private static let logsSQLiteDefaultVersion = 2

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
    static var stateSQLiteURL: URL {
        self.versionedSQLiteURL(
            basename: "state",
            defaultVersion: self.stateSQLiteDefaultVersion
        )
    }
    static var logsSQLiteURL: URL {
        self.versionedSQLiteURL(
            basename: "logs",
            defaultVersion: self.logsSQLiteDefaultVersion
        )
    }
    static var oauthFlowsDirectoryURL: URL { self.codexBarRoot.appendingPathComponent("oauth-flows", isDirectory: true) }
    static var menuHostRootURL: URL { self.codexBarRoot.appendingPathComponent("menu-host", isDirectory: true) }
    static var menuHostAppURL: URL { self.menuHostRootURL.appendingPathComponent("codexbar.app", isDirectory: true) }

    static var barConfigURL: URL { self.codexBarRoot.appendingPathComponent("config.json") }
    static var costCacheURL: URL { self.codexBarRoot.appendingPathComponent("cost-cache.json") }
    static var costSessionCacheURL: URL { self.codexBarRoot.appendingPathComponent("cost-session-cache.json") }
    static var switchJournalURL: URL { self.codexBarRoot.appendingPathComponent("switch-journal.jsonl") }
    static var managedLaunchRootURL: URL { self.codexBarRoot.appendingPathComponent("managed-launch", isDirectory: true) }
    static var managedLaunchBinURL: URL { self.managedLaunchRootURL.appendingPathComponent("bin", isDirectory: true) }
    static var managedLaunchHitsURL: URL { self.managedLaunchRootURL.appendingPathComponent("hits", isDirectory: true) }
    static var managedLaunchStateURL: URL { self.managedLaunchRootURL.appendingPathComponent("last-launch.json") }
    static var openAIGatewayRootURL: URL { self.codexBarRoot.appendingPathComponent("openai-gateway", isDirectory: true) }
    static var openAIGatewayStateURL: URL { self.openAIGatewayRootURL.appendingPathComponent("state.json") }

    static var configBackupURL: URL { self.codexRoot.appendingPathComponent("config.toml.bak-codexbar-last") }
    static var authBackupURL: URL { self.codexRoot.appendingPathComponent("auth.json.bak-codexbar-last") }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: self.codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexBarRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.oauthFlowsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.menuHostRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.managedLaunchBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.managedLaunchHitsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.openAIGatewayRootURL, withIntermediateDirectories: true)
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

    private static func versionedSQLiteURL(
        basename: String,
        defaultVersion: Int
    ) -> URL {
        let version = self.latestSQLiteVersion(basename: basename) ?? defaultVersion
        return self.codexRoot.appendingPathComponent("\(basename)_\(version).sqlite")
    }

    private static func latestSQLiteVersion(basename: String) -> Int? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: self.codexRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let prefix = "\(basename)_"
        return urls.compactMap { url -> Int? in
            guard url.pathExtension == "sqlite" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }

            let filename = url.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix(prefix) else { return nil }
            let suffix = String(filename.dropFirst(prefix.count))
            return Int(suffix)
        }
        .max()
    }
}
