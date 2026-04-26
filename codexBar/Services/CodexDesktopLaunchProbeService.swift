import AppKit
import Foundation

struct CodexDesktopResolvedAppLocation: Equatable {
    enum Source: Equatable {
        case preferredPath
        case bundleIdentifierLookup
        case applicationsFallback
    }

    let url: URL
    let source: Source
}

enum CodexDesktopPreferredAppPathStatus: Equatable {
    case automatic
    case manualValid(String)
    case manualInvalid(String)
}

struct CodexDesktopLaunchProbeState: Codable, Equatable {
    let runID: String
    let launchedAt: Date
}

struct CodexDesktopLaunchProbeHit: Codable, Equatable {
    let runID: String
    let recordedAt: Date
    let argc: Int
}

enum CodexDesktopLaunchProbeError: LocalizedError {
    case codexAppNotFound
    case bundledCodexExecutableMissing
    case launchTimedOut
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexAppNotFound:
            return L.codexLaunchProbeAppNotFound
        case .bundledCodexExecutableMissing:
            return L.codexLaunchProbeExecutableMissing
        case .launchTimedOut:
            return L.codexLaunchProbeTimedOut
        case .launchFailed(let message):
            return L.codexLaunchProbeFailed(message)
        }
    }
}

@MainActor
final class CodexDesktopLaunchProbeService {
    static let shared = CodexDesktopLaunchProbeService()
    private static let localProxyBypassHosts = ["localhost", "127.0.0.1", "::1"]

    typealias PreferredAppPathProvider = @MainActor () -> String?
    typealias AppLocator = @MainActor () -> CodexDesktopResolvedAppLocation?
    typealias Launcher = @MainActor (_ appURL: URL, _ environment: [String: String]) async throws -> NSRunningApplication?

    private let preferredAppPathProvider: PreferredAppPathProvider
    private let locateCodexApp: AppLocator
    private let launchApp: Launcher
    private let fileManager: FileManager
    private let environment: [String: String]
    private let now: () -> Date
    private let makeUUID: () -> UUID

    init(
        preferredAppPathProvider: @escaping PreferredAppPathProvider = {
            TokenStore.shared.config.desktop.preferredCodexAppPath
        },
        locateCodexApp: @escaping AppLocator = {
            CodexDesktopLaunchProbeService.resolveAutomaticCodexAppLocation(
                bundleIdentifierLookup: {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
                }
            )
        },
        launchApp: @escaping Launcher = { appURL, environment in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            configuration.environment = environment
            do {
                return try await withThrowingTaskGroup(of: NSRunningApplication?.self) { group in
                    group.addTask {
                        try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(10))
                        throw CodexDesktopLaunchProbeError.launchTimedOut
                    }

                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw CodexDesktopLaunchProbeError.launchTimedOut
                    }
                    return result
                }
            } catch let error as CodexDesktopLaunchProbeError {
                throw error
            } catch {
                throw CodexDesktopLaunchProbeError.launchFailed(error.localizedDescription)
            }
        },
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.preferredAppPathProvider = preferredAppPathProvider
        self.locateCodexApp = locateCodexApp
        self.launchApp = launchApp
        self.fileManager = fileManager
        self.environment = environment
        self.now = now
        self.makeUUID = makeUUID
    }

    func resolvedCodexAppLocation() -> CodexDesktopResolvedAppLocation? {
        if let preferredURL = Self.validatedPreferredCodexAppURL(
            from: self.preferredAppPathProvider(),
            fileManager: self.fileManager
        ) {
            return CodexDesktopResolvedAppLocation(
                url: preferredURL,
                source: .preferredPath
            )
        }

        return self.locateCodexApp()
    }

    func preferredAppPathStatus() -> CodexDesktopPreferredAppPathStatus {
        Self.preferredAppPathStatus(
            for: self.preferredAppPathProvider(),
            fileManager: self.fileManager
        )
    }

    func launchProbe() async throws -> CodexDesktopLaunchProbeState {
        guard let appURL = self.resolvedCodexAppLocation()?.url else {
            throw CodexDesktopLaunchProbeError.codexAppNotFound
        }

        let codexExecutableURL = Self.codexExecutableURL(for: appURL)

        guard self.fileManager.fileExists(atPath: codexExecutableURL.path) else {
            throw CodexDesktopLaunchProbeError.bundledCodexExecutableMissing
        }

        try CodexPaths.ensureDirectories()

        let runID = self.makeUUID().uuidString.lowercased()
        let state = CodexDesktopLaunchProbeState(
            runID: runID,
            launchedAt: self.now()
        )

        let wrapperURL = CodexPaths.managedLaunchBinURL.appendingPathComponent("codex")
        try self.writeWrapper(
            to: wrapperURL,
            originalCodexExecutableURL: codexExecutableURL
        )
        try self.writeState(state)

        var launchEnvironment = self.environment
        let currentPATH = launchEnvironment["PATH"] ?? ""
        let prefixedPATH = currentPATH.isEmpty
            ? CodexPaths.managedLaunchBinURL.path
            : CodexPaths.managedLaunchBinURL.path + ":" + currentPATH
        launchEnvironment["PATH"] = prefixedPATH
        launchEnvironment["CODEXBAR_DESKTOP_PROBE_RUN_ID"] = runID
        launchEnvironment["CODEXBAR_DESKTOP_PROBE_HITS_DIR"] = CodexPaths.managedLaunchHitsURL.path
        launchEnvironment = Self.appendingLocalProxyBypass(to: launchEnvironment)

        _ = try await self.launchApp(appURL, launchEnvironment)
        return state
    }

    func launchNewInstance() async throws -> NSRunningApplication? {
        guard let appURL = self.resolvedCodexAppLocation()?.url else {
            throw CodexDesktopLaunchProbeError.codexAppNotFound
        }

        var launchEnvironment = self.environment
        launchEnvironment.removeValue(forKey: "CODEXBAR_DESKTOP_PROBE_RUN_ID")
        launchEnvironment.removeValue(forKey: "CODEXBAR_DESKTOP_PROBE_HITS_DIR")
        launchEnvironment = Self.appendingLocalProxyBypass(to: launchEnvironment)

        return try await self.launchApp(appURL, launchEnvironment)
    }

    func latestLaunchState() -> CodexDesktopLaunchProbeState? {
        guard let data = try? Data(contentsOf: CodexPaths.managedLaunchStateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexDesktopLaunchProbeState.self, from: data)
    }

    func latestHit() -> CodexDesktopLaunchProbeHit? {
        guard let urls = try? self.fileManager.contentsOfDirectory(
            at: CodexPaths.managedLaunchHitsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let sorted = urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        for url in sorted where url.pathExtension == "json" {
            if let hit = self.readHit(at: url) {
                return hit
            }
        }

        return nil
    }

    func hit(for runID: String) -> CodexDesktopLaunchProbeHit? {
        let url = CodexPaths.managedLaunchHitsURL.appendingPathComponent("\(runID).json")
        return self.readHit(at: url)
    }

    nonisolated static func preferredAppPathStatus(
        for preferredAppPath: String?,
        fileManager: FileManager = .default
    ) -> CodexDesktopPreferredAppPathStatus {
        let trimmedPath = preferredAppPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedPath.isEmpty == false else { return .automatic }

        if let validURL = self.validatedPreferredCodexAppURL(
            from: trimmedPath,
            fileManager: fileManager
        ) {
            return .manualValid(validURL.path)
        }

        return .manualInvalid(trimmedPath)
    }

    nonisolated static func validatedPreferredCodexAppURL(
        from preferredAppPath: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmedPath = preferredAppPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedPath.isEmpty == false else { return nil }
        guard (trimmedPath as NSString).isAbsolutePath else { return nil }

        let appURL = URL(fileURLWithPath: trimmedPath, isDirectory: true).standardizedFileURL
        guard self.isValidCodexAppURL(appURL, fileManager: fileManager) else { return nil }
        return appURL
    }

    nonisolated static func resolveAutomaticCodexAppLocation(
        bundleIdentifierLookup: () -> URL?,
        fileManager: FileManager = .default,
        applicationsFallbackURL: URL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
    ) -> CodexDesktopResolvedAppLocation? {
        if let bundleLookupURL = bundleIdentifierLookup()?.standardizedFileURL,
           self.isValidCodexAppURL(bundleLookupURL, fileManager: fileManager) {
            return CodexDesktopResolvedAppLocation(
                url: bundleLookupURL,
                source: .bundleIdentifierLookup
            )
        }

        let fallbackURL = applicationsFallbackURL.standardizedFileURL
        guard self.isValidCodexAppURL(fallbackURL, fileManager: fileManager) else {
            return nil
        }

        return CodexDesktopResolvedAppLocation(
            url: fallbackURL,
            source: .applicationsFallback
        )
    }

    nonisolated static func isValidCodexAppURL(
        _ appURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard appURL.isFileURL else { return false }
        guard (appURL.path as NSString).isAbsolutePath else { return false }
        guard appURL.pathExtension == "app" else { return false }
        guard appURL.lastPathComponent == "Codex.app" else { return false }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let codexExecutableURL = self.codexExecutableURL(for: appURL)
        return fileManager.fileExists(atPath: codexExecutableURL.path)
    }

    nonisolated static func codexExecutableURL(for appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex")
    }

    private func readHit(at url: URL) -> CodexDesktopLaunchProbeHit? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexDesktopLaunchProbeHit.self, from: data)
    }

    private func writeState(_ state: CodexDesktopLaunchProbeState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try CodexPaths.writeSecureFile(data, to: CodexPaths.managedLaunchStateURL)
    }

    private func writeWrapper(
        to wrapperURL: URL,
        originalCodexExecutableURL: URL
    ) throws {
        let hitsDirectory = self.shellSingleQuoted(CodexPaths.managedLaunchHitsURL.path)
        let originalExecutable = self.shellSingleQuoted(originalCodexExecutableURL.path)
        let script = """
        #!/bin/sh
        set -eu
        HITS_DIR="${CODEXBAR_DESKTOP_PROBE_HITS_DIR:-}"
        if [ -z "$HITS_DIR" ]; then
          HITS_DIR=\(hitsDirectory)
        fi
        RUN_ID="${CODEXBAR_DESKTOP_PROBE_RUN_ID:-unknown}"
        mkdir -p "$HITS_DIR"
        RECORDED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        cat > "$HITS_DIR/$RUN_ID.json" <<EOF
        {"runID":"$RUN_ID","recordedAt":"$RECORDED_AT","argc":$#}
        EOF
        exec \(originalExecutable) "$@"
        """

        try self.fileManager.createDirectory(
            at: wrapperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: wrapperURL, options: .atomic)
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: wrapperURL.path
        )
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appendingLocalProxyBypass(
        to environment: [String: String]
    ) -> [String: String] {
        var updated = environment
        for key in ["NO_PROXY", "no_proxy"] {
            updated[key] = self.mergedNoProxyValue(existing: updated[key])
        }
        return updated
    }

    private static func mergedNoProxyValue(existing: String?) -> String {
        let existingEntries = (existing ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        if existingEntries.contains("*") {
            return existingEntries.joined(separator: ",")
        }

        var merged = existingEntries
        let normalized = Set(existingEntries.map { $0.lowercased() })
        for host in self.localProxyBypassHosts where normalized.contains(host.lowercased()) == false {
            merged.append(host)
        }
        return merged.joined(separator: ",")
    }
}
