import AppKit
import Foundation

private struct AppSessionState: Codable {
    let sessionID: String
    let pid: Int32
    let startedAt: Date
    var cleanExit: Bool
    var endedAt: Date?
    var endReason: String?
}

final class AppLifecycleDiagnostics {
    static let shared = AppLifecycleDiagnostics()

    private let queue = DispatchQueue(label: "lzl.codexbar.lifecycle-diagnostics")
    private let stateURL = CodexPaths.codexBarRoot.appendingPathComponent("app-lifecycle-state.json")
    private let eventsURL = CodexPaths.codexBarRoot.appendingPathComponent("app-lifecycle.jsonl")

    private init() {}

    func beginSession() {
        self.queue.sync {
            try? CodexPaths.ensureDirectories()

            if let previous = self.loadState(), previous.cleanExit == false {
                self.appendEvent(
                    type: "previous_session_unfinished",
                    fields: [
                        "sessionID": previous.sessionID,
                        "pid": previous.pid,
                        "startedAt": previous.startedAt,
                        "endedAt": previous.endedAt as Any,
                        "endReason": previous.endReason as Any,
                    ]
                )
            }

            let state = AppSessionState(
                sessionID: UUID().uuidString,
                pid: getpid(),
                startedAt: Date(),
                cleanExit: false,
                endedAt: nil,
                endReason: nil
            )
            self.saveState(state)
            self.appendEvent(
                type: "launch",
                fields: [
                    "sessionID": state.sessionID,
                    "pid": state.pid,
                    "startedAt": state.startedAt,
                ]
            )
        }
    }

    func markTermination(reason: String) {
        self.queue.sync {
            guard var state = self.loadState(), state.cleanExit == false else { return }
            state.cleanExit = true
            state.endedAt = Date()
            state.endReason = reason
            self.saveState(state)
            self.appendEvent(
                type: "terminate",
                fields: [
                    "sessionID": state.sessionID,
                    "pid": state.pid,
                    "startedAt": state.startedAt,
                    "endedAt": state.endedAt as Any,
                    "endReason": reason,
                ]
            )
        }
    }

    private func loadState() -> AppSessionState? {
        guard let data = try? Data(contentsOf: self.stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppSessionState.self, from: data)
    }

    private func saveState(_ state: AppSessionState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.stateURL)
    }

    private func appendEvent(type: String, fields: [String: Any]) {
        var payload: [String: Any] = [:]
        for (key, value) in fields {
            payload[key] = self.jsonValue(value)
        }
        payload["type"] = type
        payload["recordedAt"] = ISO8601DateFormatter().string(from: Date())

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: self.eventsURL.path) == false {
            try? CodexPaths.writeSecureFile(Data((line + "\n").utf8), to: self.eventsURL)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: self.eventsURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func jsonValue(_ value: Any) -> Any {
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return self.jsonValue(child.value)
        }

        return value
    }
}

final class AppLifecycleObserver: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLifecycleDiagnostics.shared.beginSession()
        Task { @MainActor in
            OpenAIUsagePollingService.shared.start()
            UpdateCoordinator.shared.start()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                CodexBarURLRouter.handle(url)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            OpenAIUsagePollingService.shared.stop()
            UpdateCoordinator.shared.stop()
        }
        AppLifecycleDiagnostics.shared.markTermination(reason: "applicationWillTerminate")
    }
}
