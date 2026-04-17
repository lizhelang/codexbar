import AppKit
import Foundation

enum CodexBarInterprocess {
    static let reloadStateNotification = Notification.Name("lzl.codexbar.reload-state")
    static let terminatePrimaryNotification = Notification.Name("lzl.codexbar.terminate-primary")

    static func postReloadState() {
        DistributedNotificationCenter.default().post(
            name: self.reloadStateNotification,
            object: nil
        )
    }

    static func postTerminatePrimary() {
        DistributedNotificationCenter.default().post(
            name: self.terminatePrimaryNotification,
            object: nil
        )
    }
}

@MainActor
final class MenuHostBootstrapService {
    static let shared = MenuHostBootstrapService()

    nonisolated static let helperBundleIdentifier = "lzhl.codexAppBar.menuhost"
    nonisolated static let helperMarkerInfoKey = "CodexBarMenuHost"
    nonisolated static let helperSourceVersionKey = "CodexBarMenuHostSourceVersion"
    nonisolated static let helperSourceSignatureKey = "CodexBarMenuHostSourceSignature"

    static var isMenuHostProcess: Bool {
        if Bundle.main.object(forInfoDictionaryKey: self.helperMarkerInfoKey) as? Bool == true {
            return true
        }
        return Bundle.main.bundleIdentifier == self.helperBundleIdentifier
    }

    private let fileManager = FileManager.default

    private init() {}

    func ensureMenuHostRunning() {
        guard Self.isMenuHostProcess == false else { return }

        do {
            let helperURL = try self.prepareMenuHostApp()
            if self.helperIsRunning() == false {
                try self.launchHelper(at: helperURL)
            }
        } catch {
            NSLog("codexbar menu host bootstrap failed: %@", error.localizedDescription)
        }
    }

    private func prepareMenuHostApp() throws -> URL {
        try CodexPaths.ensureDirectories()

        let helperURL = CodexPaths.menuHostAppURL
        let sourceURL = Bundle.main.bundleURL

        if self.helperNeedsRefresh(at: helperURL) {
            try self.replaceHelperBundle(at: helperURL, from: sourceURL)
        }

        return helperURL
    }

    private func helperNeedsRefresh(at helperURL: URL) -> Bool {
        guard self.fileManager.fileExists(atPath: helperURL.path) else { return true }
        guard let helperBundle = Bundle(url: helperURL) else {
            return true
        }

        return Self.helperNeedsRefresh(
            helperBundle: helperBundle,
            sourceBundle: Bundle.main
        )
    }

    private func replaceHelperBundle(at helperURL: URL, from sourceURL: URL) throws {
        if self.helperIsRunning(),
           let runningHelper = NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.helperBundleIdentifier
           ).first {
            runningHelper.terminate()
            Thread.sleep(forTimeInterval: 0.5)
        }

        if self.fileManager.fileExists(atPath: helperURL.path) {
            try self.fileManager.removeItem(at: helperURL)
        }

        try self.fileManager.copyItem(at: sourceURL, to: helperURL)
        try self.patchHelperInfoPlist(at: helperURL.appendingPathComponent("Contents/Info.plist"))
        try self.resignHelperBundle(at: helperURL)
    }

    private func patchHelperInfoPlist(at plistURL: URL) throws {
        let data = try Data(contentsOf: plistURL)
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(domain: "codexbar.helper", code: 1)
        }

        plist["CFBundleIdentifier"] = Self.helperBundleIdentifier
        plist["CFBundleDisplayName"] = "codexbar"
        plist["CFBundleName"] = "codexbar"
        plist[Self.helperMarkerInfoKey] = true
        plist[Self.helperSourceVersionKey] = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        )
        plist[Self.helperSourceSignatureKey] = Self.helperSourceSignature(
            for: Bundle.main
        )
        plist.removeValue(forKey: "CFBundleURLTypes")

        let patched = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try patched.write(to: plistURL, options: .atomic)
    }

    private func helperIsRunning() -> Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.helperBundleIdentifier
        ).isEmpty == false
    }

    private func launchHelper(at helperURL: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            if let error {
                NSLog("codexbar failed to launch menu host: %@", error.localizedDescription)
            }
        }
    }

    private func resignHelperBundle(at helperURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--sign", "-",
            "--deep",
            helperURL.path,
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            throw NSError(
                domain: "codexbar.helper",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message as Any
                        : "codesign failed for menu host helper",
                ]
            )
        }
    }

    nonisolated static func helperNeedsRefresh(helperBundle: Bundle, sourceBundle: Bundle) -> Bool {
        guard let sourceSignature = self.helperSourceSignature(for: sourceBundle) else {
            guard let sourceVersion = sourceBundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                  ) as? String,
                  let storedSourceVersion = helperBundle.object(
                    forInfoDictionaryKey: self.helperSourceVersionKey
                  ) as? String else {
                return true
            }

            return storedSourceVersion != sourceVersion
        }

        if let storedSourceSignature = helperBundle.object(
            forInfoDictionaryKey: self.helperSourceSignatureKey
        ) as? String {
            return storedSourceSignature != sourceSignature
        }

        return true
    }

    nonisolated static func helperSourceSignature(for bundle: Bundle) -> String? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let shortVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let executableURL = bundle.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: executableURL.path
              ),
              let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }

        return "\(version)|\(shortVersion)|\(size.int64Value)|\(Int(modificationDate.timeIntervalSince1970))"
    }
}
