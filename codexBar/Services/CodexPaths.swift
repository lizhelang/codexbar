import Foundation

enum CodexPaths {
    private static let stateSQLiteDefaultVersion = 5
    private static let logsSQLiteDefaultVersion = 2

    static var realHome: URL {
        self.hostHomeRootURL
    }

    static var codexRoot: URL {
        self.directoryURL(self.storePathPlan().codexRoot)
    }

    static var codexBarRoot: URL {
        self.directoryURL(self.storePathPlan().codexbarRoot)
    }

    static var authURL: URL { self.fileURL(self.storePathPlan().authPath) }
    static var tokenPoolURL: URL { self.fileURL(self.storePathPlan().tokenPoolPath) }
    static var configTomlURL: URL { self.fileURL(self.storePathPlan().configTomlPath) }
    static var providerSecretsURL: URL { self.fileURL(self.storePathPlan().providerSecretsPath) }
    static var stateSQLiteURL: URL { self.fileURL(self.storePathPlan().stateSqlitePath) }
    static var logsSQLiteURL: URL { self.fileURL(self.storePathPlan().logsSqlitePath) }
    static var sessionsRootURL: URL { self.directoryURL(self.storePathPlan().sessionsRootPath) }
    static var archivedSessionsRootURL: URL { self.directoryURL(self.storePathPlan().archivedSessionsRootPath) }
    static var oauthFlowsDirectoryURL: URL { self.directoryURL(self.storePathPlan().oauthFlowsDirectoryPath) }
    static var menuHostRootURL: URL { self.directoryURL(self.storePathPlan().menuHostRootPath) }
    static var menuHostAppURL: URL { self.directoryURL(self.storePathPlan().menuHostAppPath) }
    static var menuHostLeaseURL: URL { self.fileURL(self.storePathPlan().menuHostLeasePath) }

    static var barConfigURL: URL { self.fileURL(self.storePathPlan().barConfigPath) }
    static var costCacheURL: URL { self.fileURL(self.storePathPlan().costCachePath) }
    static var costSessionCacheURL: URL { self.fileURL(self.storePathPlan().costSessionCachePath) }
    static var costEventLedgerURL: URL { self.fileURL(self.storePathPlan().costEventLedgerPath) }
    static var switchJournalURL: URL { self.fileURL(self.storePathPlan().switchJournalPath) }
    static var managedLaunchRootURL: URL { self.directoryURL(self.storePathPlan().managedLaunchRootPath) }
    static var managedLaunchBinURL: URL { self.directoryURL(self.storePathPlan().managedLaunchBinPath) }
    static var managedLaunchHitsURL: URL { self.directoryURL(self.storePathPlan().managedLaunchHitsPath) }
    static var managedLaunchStateURL: URL { self.fileURL(self.storePathPlan().managedLaunchStatePath) }
    static var openAIGatewayRootURL: URL { self.directoryURL(self.storePathPlan().openaiGatewayRootPath) }
    static var openAIGatewayStateURL: URL { self.fileURL(self.storePathPlan().openaiGatewayStatePath) }
    static var openAIGatewayRouteJournalURL: URL { self.fileURL(self.storePathPlan().openaiGatewayRouteJournalPath) }
    static var openRouterGatewayRootURL: URL { self.directoryURL(self.storePathPlan().openrouterGatewayRootPath) }
    static var openRouterGatewayStateURL: URL { self.fileURL(self.storePathPlan().openrouterGatewayStatePath) }

    static var configBackupURL: URL { self.fileURL(self.storePathPlan().configBackupPath) }
    static var authBackupURL: URL { self.fileURL(self.storePathPlan().authBackupPath) }

    static func ensureDirectories() throws {
        let plan = self.storePathPlan()
        try FileManager.default.createDirectory(at: self.directoryURL(plan.codexRoot), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.codexbarRoot), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.sessionsRootPath), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.archivedSessionsRootPath), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.oauthFlowsDirectoryPath), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.menuHostRootPath), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.managedLaunchBinPath), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.managedLaunchHitsPath), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.openaiGatewayRootPath), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.directoryURL(plan.openrouterGatewayRootPath), withIntermediateDirectories: true)
    }

    static func writeSecureFile(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString + ".tmp")
        try data.write(to: tempURL, options: .atomic)
        try FileManager.default.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: tempURL.path)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
        try FileManager.default.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: url.path)
    }

    static func backupFileIfPresent(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        try self.writeSecureFile(data, to: destination)
    }

    private static var hostHomeRootURL: URL {
        if let override = ProcessInfo.processInfo.environment["CODEXBAR_HOME"],
           override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pwDir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var rawCodexRootURL: URL {
        self.hostHomeRootURL.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func storePathPlan() -> PortableCoreStorePathPlan {
        func latestSQLiteVersion(basename: String) -> Int? {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: self.rawCodexRootURL,
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

        do {
            return try RustPortableCoreAdapter.shared.planStorePaths(
                PortableCoreStorePathPlanRequest(
                    homeRoot: self.hostHomeRootURL.path,
                    codexRoot: nil,
                    codexbarRoot: nil,
                    stateSqliteDefaultVersion: self.stateSQLiteDefaultVersion,
                    logsSqliteDefaultVersion: self.logsSQLiteDefaultVersion,
                    stateSqliteResolvedVersion: latestSQLiteVersion(basename: "state"),
                    logsSqliteResolvedVersion: latestSQLiteVersion(basename: "logs")
                ),
                buildIfNeeded: false
            )
        } catch {
            preconditionFailure("Rust path planner failed: \(error.localizedDescription)")
        }
    }

    private static func directoryURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }
}
