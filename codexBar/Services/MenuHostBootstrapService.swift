import AppKit
import Foundation

struct MenuHostLegacyCleanupResult: Equatable {
    var terminatedRunningHelper = false
    var removedAppBundle = false
    var removedLease = false
    var removedRootDirectory = false

    var hadLegacyArtifacts: Bool {
        self.terminatedRunningHelper ||
            self.removedAppBundle ||
            self.removedLease ||
            self.removedRootDirectory
    }
}

@MainActor
final class MenuHostBootstrapService {
    static let shared = MenuHostBootstrapService()

    nonisolated static let helperBundleIdentifier = "lzhl.codexAppBar.menuhost"

    private let fileManager = FileManager.default
    private let menuHostRootURL: URL
    private let menuHostAppURL: URL
    private let menuHostLeaseURL: URL
    private let runningApplications: (String) -> [NSRunningApplication]

    convenience init() {
        self.init(
            menuHostRootURL: CodexPaths.menuHostRootURL,
            menuHostAppURL: CodexPaths.menuHostAppURL,
            menuHostLeaseURL: CodexPaths.menuHostLeaseURL
        )
    }

    init(
        menuHostRootURL: URL,
        menuHostAppURL: URL,
        menuHostLeaseURL: URL,
        runningApplications: @escaping (String) -> [NSRunningApplication] = {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
    ) {
        self.menuHostRootURL = menuHostRootURL
        self.menuHostAppURL = menuHostAppURL
        self.menuHostLeaseURL = menuHostLeaseURL
        self.runningApplications = runningApplications
    }

    @discardableResult
    func cleanupLegacyArtifacts() -> MenuHostLegacyCleanupResult {
        var result = MenuHostLegacyCleanupResult()

        let runningHelpers = self.runningApplications(Self.helperBundleIdentifier)
        if runningHelpers.isEmpty == false {
            result.terminatedRunningHelper = true
            runningHelpers.forEach { app in
                if app.terminate() == false {
                    _ = app.forceTerminate()
                }
            }
        }

        if self.fileManager.fileExists(atPath: self.menuHostAppURL.path) {
            try? self.fileManager.removeItem(at: self.menuHostAppURL)
            result.removedAppBundle = true
        }

        if self.fileManager.fileExists(atPath: self.menuHostLeaseURL.path) {
            try? self.fileManager.removeItem(at: self.menuHostLeaseURL)
            result.removedLease = true
        }

        if self.fileManager.fileExists(atPath: self.menuHostRootURL.path),
           let contents = try? self.fileManager.contentsOfDirectory(
                atPath: self.menuHostRootURL.path
           ),
           contents.isEmpty {
            try? self.fileManager.removeItem(at: self.menuHostRootURL)
            result.removedRootDirectory = true
        }

        return result
    }
}
