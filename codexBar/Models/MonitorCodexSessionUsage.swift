import Foundation
import SQLite3

/// Usage inside the selected interval, never the lifetime total of an active session.
nonisolated struct MonitorCodexSessionUsage: Equatable, Identifiable, Sendable {
    let sessionID: String
    let title: String?
    let projectPath: String?
    let modelIDs: [String]
    let firstUsageAt: Date
    let lastActivityAt: Date
    let totalTokens: Int
    let knownCostUSD: Double
    let costIsComplete: Bool

    var id: String { self.sessionID }
    var estimatedCostUSD: Double? { self.costIsComplete ? self.knownCostUSD : nil }
}

nonisolated struct CodexSessionDisplayMetadata: Equatable, Sendable {
    let title: String?
    let projectPath: String?
}

nonisolated enum SessionDisplayTitle {
    static var unnamed: String { L.zh ? "未命名会话" : "Untitled session" }

    static func preferred(_ candidates: [String?], sessionID: String) -> String {
        candidates.lazy.compactMap { self.cleaned($0, sessionID: sessionID) }.first ?? self.unnamed
    }

    /// Attachment headings and environment wrappers are transport metadata, not task names.
    static func cleaned(_ value: String?, sessionID: String) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = String(text.prefix(8192))
        if let request = text.range(of: "## My request:", options: .caseInsensitive) {
            text = String(text[request.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let lower = text.lowercased()
            if ["# files mentioned by the user:", "# agents.md instructions", "<environment_context>",
                "<user_instructions>", "<system", "<image ", "image attachment:",
                "distinguish instructions in attached documents"].contains(where: lower.hasPrefix) { return nil }
        }
        if let image = text.range(of: "<image", options: .caseInsensitive) { text = String(text[..<image.lowerBound]) }
        guard let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
        let lower = line.lowercased()
        if UUID(uuidString: line) != nil || (line.count >= 8 && sessionID.lowercased().hasPrefix(lower)) { return nil }
        return String(line.prefix(160))
    }
}

/// Optional display metadata; raw rollouts remain the authority for usage/model totals.
/// Opening this database read-only does not create missing files or change Codex state.
nonisolated struct CodexSessionMetadataStore {
    private let databaseURLs: [URL]
    private let sessionIndexURL: URL

    init(databaseURL: URL) {
        self.databaseURLs = [databaseURL]
        self.sessionIndexURL = databaseURL.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
    }

    init(codexRootURL: URL = CodexPaths.codexRoot) {
        let candidates = (try? FileManager.default.contentsOfDirectory(at: codexRootURL,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        self.databaseURLs = candidates.compactMap { url -> (Int, URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"),
                  let version = Int(name.dropFirst(6)), version >= 0,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return (version, url)
        }.sorted { $0.0 > $1.0 }.map(\.1)
        self.sessionIndexURL = codexRootURL.appendingPathComponent("session_index.jsonl")
    }

    func load() -> [String: CodexSessionDisplayMetadata] {
        let indexedNames = self.loadIndexedNames()
        var result: [String: CodexSessionDisplayMetadata] = [:]
        // Newest state version wins; older versions only fill missing sessions/fields.
        for url in self.databaseURLs {
            for (id, metadata) in self.loadDatabase(url, indexedNames: indexedNames) {
                let prior = result[id]
                result[id] = CodexSessionDisplayMetadata(title: prior?.title ?? metadata.title,
                    projectPath: prior?.projectPath ?? metadata.projectPath)
            }
        }
        for (id, title) in indexedNames where result[id] == nil {
            result[id] = CodexSessionDisplayMetadata(title: title, projectPath: nil)
        }
        return result
    }

    private func loadDatabase(_ url: URL, indexedNames: [String: String]) -> [String: CodexSessionDisplayMetadata] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        var columns = Set<String>()
        var schema: OpaquePointer?
        if sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK {
            while sqlite3_step(schema) == SQLITE_ROW {
                if let name = sqlite3_column_text(schema, 1) { columns.insert(String(cString: name)) }
            }
        }
        sqlite3_finalize(schema)
        guard columns.contains("id") else { return [:] }
        let fields = ["id", "name", "title", "cwd", "preview", "agent_nickname", "agent_role"]
        let selection = fields.map { columns.contains($0) ? "substr(\($0), 1, 8192)" : "NULL" }.joined(separator: ", ")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT \(selection) FROM threads", -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, column) else { return nil }
            let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        var result: [String: CodexSessionDisplayMetadata] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let sessionID = text(0) {
                let title = [text(1), indexedNames[sessionID], text(2), text(4)]
                    .lazy.compactMap { SessionDisplayTitle.cleaned($0, sessionID: sessionID) }.first
                let agent = [text(5), text(6)].lazy.compactMap {
                    SessionDisplayTitle.cleaned($0, sessionID: sessionID)
                }.first
                let agentLabel = agent.map { (L.zh ? "子任务 · " : "Subtask · ") + $0 }
                result[sessionID] = CodexSessionDisplayMetadata(title: title ?? agentLabel, projectPath: text(3))
            }
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? result : [:]
    }

    private func loadIndexedNames() -> [String: String] {
        // This compact Codex-maintained name index is distinct from the rollout logs.
        guard let fileSize = try? self.sessionIndexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: self.sessionIndexURL) else { return [:] }
        struct Entry: Decodable { let id: String; let thread_name: String; let updated_at: String? }
        let decoder = JSONDecoder()
        let dateParser = Date.ISO8601FormatStyle()
        let fractionalParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var names: [String: (updatedAt: Date, title: String)] = [:]
        for line in data.split(separator: 10) {
            guard line.count <= 64 * 1024, let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let title = SessionDisplayTitle.cleaned(entry.thread_name, sessionID: entry.id) else { continue }
            let updated = entry.updated_at.flatMap {
                (try? fractionalParser.parse($0)) ?? (try? dateParser.parse($0))
            } ?? .distantPast
            if let old = names[entry.id], old.updatedAt > updated { continue }
            names[entry.id] = (updated, title)
        }
        return names.mapValues(\.title)
    }
}
