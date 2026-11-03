import Foundation
import SQLite3

/// 自动续跑只使用 Codex 自己保存的轮次终态，不把日志静默或对话正文当作失败证据。
/// 所有连接均为只读；数据库版本或投影进度未知时保留展示信息，但禁止自动发送。
nonisolated struct CodexQuotaResumeObservationStore: Sendable {
    enum Phase: String, Codable, Sendable {
        case quotaBlocked, inProgress, completed, interrupted, failed, unknown, archived
    }

    struct Observation: Equatable, Sendable {
        let threadID: String
        let title: String
        let cwd: String
        let source: String
        let modelProvider: String?
        let model: String?
        /// 创建线程时的身份仅供展示，不能作为失败轮次使用该账号的证据。
        let creatorAccountID: String?
        let executionAccountID: String?
        let parentThreadID: String?
        let isSubagent: Bool
        let createdAt: Date
        let turnID: String?
        let phase: Phase
        let startedAt: Date?
        let completedAt: Date?
        let observedAt: Date
        let revision: String
        /// nil 表示无法读取队列，绝不等同于空队列。
        let queuedMessageCount: Int?
        let isCurrent: Bool
        let unavailableReason: String?
        var originator: String? = nil
        /// 仅从本轮首条用户输入读取，用于确认自身发送的续跑消息已被接收。
        var continuationOperationID: String? = nil
        var hasAgentProgress = false

        var quotaFailureAt: Date? { self.phase == .quotaBlocked ? self.completedAt : nil }
    }

    enum ReadError: Error, LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(message): message
            }
        }
    }

    private struct ThreadMetadata {
        let id: String
        let title: String
        let cwd: String
        let source: String
        let originator: String?
        let provider: String?
        let model: String?
        let creatorAccountID: String?
        let parentThreadID: String?
        let isSubagent: Bool
        let createdAt: Date
        let archived: Bool
        let historyMode: String
        let rolloutURL: URL
    }

    private struct TurnState {
        var id: String?
        var phase: Phase = .unknown
        var startedAt: Date?
        var completedAt: Date?
        var ordinal: Int64 = -1
        var endOffset: Int64?
        var projectedOffset: Int64?
        var isCurrent = false
        var diagnostic: String?
        var continuationOperationID: String?
        var hasUserInput = false
        var hasAgentProgress = false
    }

    private let codexRootURL: URL
    private static let maximumTailBytes = 2 * 1024 * 1024

    init(codexRootURL: URL) {
        self.codexRootURL = codexRootURL
    }

    func load(
        since: Date,
        includingThreadIDs: Set<String> = [],
        now: Date = Date()
    ) throws -> [Observation] {
        let state = try ReadConnection(url: self.databaseURL(basename: "state"))
        let metadata = try self.loadMetadata(from: state, since: since, ids: includingThreadIDs)
        return self.loadObservations(metadata, now: now)
    }

    func observation(threadID: String, now: Date = Date()) throws -> Observation? {
        let state = try ReadConnection(url: self.databaseURL(basename: "state"))
        let metadata = try self.loadMetadata(from: state, since: nil, ids: [threadID])
        return self.loadObservations(metadata, now: now).first
    }

    private func loadObservations(_ metadata: [ThreadMetadata], now: Date) -> [Observation] {
        let history = try? ReadConnection(url: self.databaseURL(basename: "thread_history"))
        let queue = try? ReadConnection(url: self.databaseURL(basename: "queue"))
        let goalsURL = try? self.databaseURL(basename: "goals")
        let goals = goalsURL.flatMap { try? ReadConnection(url: $0) }
        return metadata.map { thread in
            var turn = TurnState()
            var queueCount: Int?
            var queueRevision: Int64?
            var goalRevision = "none"
            do {
                guard let queue else { throw ReadError.unavailable("无法读取 Codex 消息队列") }
                (queueCount, queueRevision) = try self.readQueue(threadID: thread.id, database: queue)
            } catch { turn.diagnostic = "无法确认 Codex 消息队列是否为空" }

            do {
                let attributes = try self.rolloutAttributes(thread.rolloutURL)
                if thread.historyMode == "paginated" {
                    guard let history else { throw ReadError.unavailable("无法读取 Codex 轮次索引") }
                    let queueDiagnostic = turn.diagnostic
                    turn = try self.readProjectedTurn(threadID: thread.id, database: history)
                    turn.isCurrent = turn.projectedOffset == attributes.size
                    if !turn.isCurrent { turn.diagnostic = "Codex 轮次索引尚未同步" }
                    if turn.phase != .inProgress, turn.endOffset == nil {
                        turn.isCurrent = false
                        turn.diagnostic = "Codex 轮次缺少结束位置，无法排除后续操作"
                    }
                    if let endOffset = turn.endOffset, endOffset < 0 || endOffset > attributes.size {
                        turn.isCurrent = false
                        turn.diagnostic = "Codex 轮次位置与记录不一致"
                    }
                    if let endOffset = turn.endOffset, endOffset < attributes.size, turn.isCurrent {
                        try self.applyPostTurnEvents(url: thread.rolloutURL, offset: endOffset, size: attributes.size, turn: &turn)
                    }
                    turn.diagnostic = turn.diagnostic ?? queueDiagnostic
                } else if thread.historyMode == "legacy" {
                    let queueDiagnostic = turn.diagnostic
                    turn = try self.readLegacyTurn(url: thread.rolloutURL, size: attributes.size)
                    turn.diagnostic = turn.diagnostic ?? queueDiagnostic
                } else {
                    throw ReadError.unavailable("尚不支持此 Codex 历史格式")
                }
                let after = try self.rolloutAttributes(thread.rolloutURL)
                if after.size != attributes.size || after.modified != attributes.modified {
                    turn.isCurrent = false
                    turn.diagnostic = "读取期间线程发生变化，等待重新检查"
                }
                if let queue {
                    let afterQueue = try self.readQueue(threadID: thread.id, database: queue)
                    if afterQueue.0 != queueCount || afterQueue.1 != queueRevision {
                        turn.isCurrent = false
                        turn.diagnostic = "读取期间消息队列发生变化，等待重新检查"
                    }
                }
                if goalsURL != nil {
                    guard let goals else { throw ReadError.unavailable("无法读取 Codex 目标状态") }
                    let goal = try self.readGoal(threadID: thread.id, database: goals)
                    goalRevision = goal.revision
                    if goal.preventsContinuation {
                        turn.phase = .interrupted
                        turn.diagnostic = "目标已停止或需要用户处理"
                    }
                }
            } catch {
                turn.isCurrent = false
                turn.diagnostic = (error as? ReadError)?.errorDescription ?? "无法读取 Codex 线程状态"
            }

            return Observation(
                threadID: thread.id, title: thread.title, cwd: thread.cwd, source: thread.source,
                modelProvider: thread.provider, model: thread.model, creatorAccountID: thread.creatorAccountID,
                executionAccountID: nil, parentThreadID: thread.parentThreadID, isSubagent: thread.isSubagent,
                createdAt: thread.createdAt, turnID: turn.id, phase: thread.archived ? .archived : turn.phase,
                startedAt: turn.startedAt, completedAt: turn.completedAt, observedAt: now,
                revision: [turn.id ?? "unknown", turn.phase.rawValue, String(turn.ordinal),
                    String(turn.projectedOffset ?? -1), String(queueRevision ?? -1), goalRevision,
                    thread.archived ? "archived" : "visible", thread.provider ?? "", thread.model ?? "",
                    thread.cwd, thread.originator ?? ""].joined(separator: "\u{1F}"),
                queuedMessageCount: queueCount, isCurrent: turn.isCurrent && queueCount != nil,
                unavailableReason: turn.diagnostic, originator: thread.originator,
                continuationOperationID: turn.continuationOperationID, hasAgentProgress: turn.hasAgentProgress
            )
        }
    }

    private func databaseURL(basename: String) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: self.codexRootURL,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        let candidates = files.compactMap { url -> (Int, URL)? in
            let stem = url.deletingPathExtension().lastPathComponent
            let prefix = basename + "_"
            guard url.pathExtension == "sqlite", stem.hasPrefix(prefix),
                  let version = Int(stem.dropFirst(prefix.count)), version >= 0,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return (version, url)
        }
        guard let url = candidates.max(by: { $0.0 < $1.0 })?.1 else {
            throw ReadError.unavailable("缺少 Codex \(basename) 数据库")
        }
        return url
    }

    private func loadMetadata(from database: ReadConnection, since: Date?, ids: Set<String>) throws -> [ThreadMetadata] {
        let columns = try database.columns(table: "threads")
        guard Set(["id", "rollout_path", "source", "cwd", "title", "archived", "created_at", "updated_at"]).isSubset(of: columns) else {
            throw ReadError.unavailable("Codex 线程数据库格式不受支持")
        }
        let optional = ["model_provider", "model", "creator_account_id", "history_mode", "name", "attached_thread_parent_id", "originator"]
        let fields = ["id", "rollout_path", "source", "cwd", "title", "archived", "created_at"] + optional
        let select = fields.map { columns.contains($0) ? $0 : "NULL" }.joined(separator: ", ")
        let sortedIDs = ids.sorted()
        var conditions: [String] = []
        if since != nil { conditions.append("updated_at >= ?") }
        if !sortedIDs.isEmpty { conditions.append("id IN (\(Array(repeating: "?", count: sortedIDs.count).joined(separator: ",")))") }
        guard !conditions.isEmpty else { return [] }
        let statement = try database.prepare("SELECT \(select) FROM threads WHERE \(conditions.joined(separator: " OR ")) ORDER BY updated_at DESC, id")
        var index: Int32 = 1
        if let since {
            try statement.bind(Int64(floor(since.timeIntervalSince1970)), at: index)
            index += 1
        }
        for id in sortedIDs { try statement.bind(id, at: index); index += 1 }
        var result: [ThreadMetadata] = []
        while try statement.next() {
            guard let id = statement.text(0), let path = statement.text(1), let source = statement.text(2),
                  let cwd = statement.text(3), let created = statement.integer(6) else { continue }
            let sourceObject = source.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let subagent = sourceObject?["subagent"] as? [String: Any]
            let spawnedParent = (subagent?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
            let parent = statement.text(12) ?? spawnedParent
            result.append(ThreadMetadata(id: id, title: statement.text(11) ?? statement.text(4) ?? "未命名会话",
                cwd: cwd, source: source, originator: statement.text(13), provider: statement.text(7), model: statement.text(8),
                creatorAccountID: statement.text(9), parentThreadID: parent,
                isSubagent: sourceObject?["subagent"] != nil || parent != nil || source == "subagent",
                createdAt: Date(timeIntervalSince1970: TimeInterval(created)), archived: statement.integer(5) != 0,
                historyMode: statement.text(10) ?? "legacy", rolloutURL: URL(fileURLWithPath: path)))
        }
        return result
    }

    private func readProjectedTurn(threadID: String, database: ReadConnection) throws -> TurnState {
        let columns = try database.columns(table: "thread_turns")
        let required: Set<String> = ["thread_id", "turn_id", "status", "error_json", "started_at", "completed_at", "rollout_ordinal"]
        guard required.isSubset(of: columns),
              try database.columns(table: "thread_history_projection_state").isSuperset(of: ["thread_id", "next_rollout_byte_offset"]) else {
            throw ReadError.unavailable("Codex 轮次索引格式不受支持")
        }
        let endOffset = columns.contains("rollout_end_byte_offset") ? "t.rollout_end_byte_offset" : "NULL"
        let firstUserItem = columns.contains("first_user_item_id") ? "t.first_user_item_id" : "NULL"
        let statement = try database.prepare("""
            SELECT t.turn_id, t.status, t.error_json, t.started_at, t.completed_at, t.rollout_ordinal,
                \(endOffset), p.next_rollout_byte_offset, \(firstUserItem)
            FROM thread_turns t LEFT JOIN thread_history_projection_state p ON p.thread_id = t.thread_id
            WHERE t.thread_id = ? ORDER BY t.rollout_ordinal DESC LIMIT 1
            """)
        try statement.bind(threadID, at: 1)
        guard try statement.next() else { return TurnState(diagnostic: "线程尚无可确认的轮次") }
        let error = statement.text(2).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let status = statement.text(1)
        let completedAt = statement.integer(4).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let phase: Phase
        switch status {
        case "inProgress", "in_progress": phase = .inProgress
        case "completed": phase = .completed
        case "interrupted": phase = .interrupted
        case "failed": phase = Self.isQuotaError(error) && completedAt != nil ? .quotaBlocked : .failed
        default: phase = .unknown
        }
        let turnID = statement.text(0)
        let continuationOperationID: String?
        if let turnID, let firstUserItemID = statement.text(8) {
            continuationOperationID = try self.readContinuationOperationID(
                threadID: threadID, turnID: turnID, itemID: firstUserItemID, database: database
            )
        } else {
            continuationOperationID = nil
        }
        let hasAgentProgress = turnID.map {
            (try? self.readHasAgentProgress(threadID: threadID, turnID: $0, database: database)) ?? false
        } ?? false
        return TurnState(id: turnID, phase: phase,
            startedAt: statement.integer(3).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            completedAt: completedAt, ordinal: statement.integer(5) ?? -1, endOffset: statement.integer(6),
            projectedOffset: statement.integer(7), continuationOperationID: continuationOperationID,
            hasAgentProgress: hasAgentProgress)
    }

    private func readHasAgentProgress(threadID: String, turnID: String, database: ReadConnection) throws -> Bool {
        guard try database.columns(table: "thread_items").isSuperset(of: ["thread_id", "turn_id", "item_json"]) else {
            return false
        }
        // 只让 SQLite 返回存在性；不把正文、工具参数或结果读入观察快照。
        // JSON 能力或结构不受支持时由调用者返回 false，不以未知状态推断进展。
        let statement = try database.prepare("""
            SELECT 1 FROM thread_items
            WHERE thread_id = ? AND turn_id = ? AND
                CASE WHEN json_valid(item_json) THEN
                    (json_extract(item_json, '$.type') = 'agentMessage'
                        AND json_type(item_json, '$.text') = 'text'
                        AND length(trim(json_extract(item_json, '$.text'), char(9) || char(10) || char(13) || ' ')) > 0)
                    OR (json_extract(item_json, '$.type') IN
                            ('commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall', 'webSearch')
                        AND json_extract(item_json, '$.status') = 'completed')
                ELSE 0 END
            LIMIT 1
            """)
        try statement.bind(threadID, at: 1)
        try statement.bind(turnID, at: 2)
        return try statement.next()
    }

    private func readContinuationOperationID(
        threadID: String, turnID: String, itemID: String, database: ReadConnection
    ) throws -> String? {
        // 不读取工具结果或助手正文，也不在其他轮次中查找同名标记。
        guard try database.columns(table: "thread_items").isSuperset(of: ["thread_id", "turn_id", "item_id", "item_json"]) else {
            return nil
        }
        let statement = try database.prepare("""
            SELECT item_json FROM thread_items
            WHERE thread_id = ? AND turn_id = ? AND item_id = ? LIMIT 1
            """)
        try statement.bind(threadID, at: 1)
        try statement.bind(turnID, at: 2)
        try statement.bind(itemID, at: 3)
        guard try statement.next(), let json = statement.text(0), let data = json.data(using: .utf8),
              let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              item["type"] as? String == "userMessage" else { return nil }
        return Self.continuationMarker(in: Self.inputText(item["content"]))
    }

    private func readQueue(threadID: String, database: ReadConnection) throws -> (Int, Int64?) {
        guard try database.columns(table: "queued_items").contains("thread_id"),
              try database.columns(table: "queued_thread_revisions").isSuperset(of: ["thread_id", "revision"]) else {
            throw ReadError.unavailable("Codex 消息队列格式不受支持")
        }
        let query = try database.prepare("""
            SELECT (SELECT COUNT(*) FROM queued_items WHERE thread_id = ?),
                (SELECT revision FROM queued_thread_revisions WHERE thread_id = ?)
            """)
        try query.bind(threadID, at: 1)
        try query.bind(threadID, at: 2)
        guard try query.next(), let count = query.integer(0) else {
            throw ReadError.unavailable("无法读取 Codex 消息队列")
        }
        return (Int(count), query.integer(1))
    }

    private func readGoal(threadID: String, database: ReadConnection) throws -> (revision: String, preventsContinuation: Bool) {
        guard try database.columns(table: "thread_goals").isSuperset(of: ["thread_id", "goal_id", "status", "updated_at_ms"]) else {
            throw ReadError.unavailable("Codex 目标数据库格式不受支持")
        }
        let statement = try database.prepare("SELECT goal_id, status, updated_at_ms FROM thread_goals WHERE thread_id = ?")
        try statement.bind(threadID, at: 1)
        guard try statement.next() else { return ("none", false) }
        guard let id = statement.text(0), let status = statement.text(1), let updatedAt = statement.integer(2) else {
            throw ReadError.unavailable("无法确认 Codex 目标状态")
        }
        let stopped = ["paused", "blocked", "budget_limited", "budgetLimited", "complete"]
        guard stopped.contains(status) || ["active", "usage_limited", "usageLimited"].contains(status) else {
            throw ReadError.unavailable("Codex 目标状态尚不受支持")
        }
        return ([id, status, String(updatedAt)].joined(separator: ":"), stopped.contains(status))
    }

    private func rolloutAttributes(_ url: URL) throws -> (size: Int64, modified: Date) {
        let actual = url.resolvingSymlinksInPath().standardizedFileURL
        let root = self.codexRootURL.resolvingSymlinksInPath().standardizedFileURL
        guard ["sessions", "archived_sessions"].contains(where: {
            actual.path.hasPrefix(root.appendingPathComponent($0).path + "/")
        }), actual.pathExtension == "jsonl" else {
            throw ReadError.unavailable("线程记录路径或格式不受支持")
        }
        let values = try actual.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else {
            throw ReadError.unavailable("线程记录不可读取")
        }
        return (Int64(size), modified)
    }

    private static func isQuotaError(_ object: [String: Any]?) -> Bool {
        guard let object else { return false }
        // 通用 rateLimitExceeded 还可能是短时频率限制，不能据此推断五小时额度耗尽。
        let code = object["codexErrorInfo"] ?? object["codex_error_info"]
        return (code as? String).map { ["usageLimitExceeded", "usage_limit_exceeded"].contains($0) } ?? false
    }

    private func readLegacyTurn(url: URL, size: Int64) throws -> TurnState {
        let offset = max(0, size - Int64(Self.maximumTailBytes))
        let records = try self.readRecords(url: url, offset: offset, size: size, discardFirst: offset > 0)
        var turn = TurnState(projectedOffset: size, isCurrent: true)
        var quotaErrorTurnID: String?
        for record in records {
            guard let type = record["type"] as? String, let payload = record["payload"] as? [String: Any] else { continue }
            if type == "turn_context" {
                if let id = payload["turn_id"] as? String, id != turn.id {
                    turn = TurnState(id: id, phase: .inProgress, projectedOffset: size, isCurrent: true)
                    quotaErrorTurnID = nil
                }
                continue
            }
            if type == "response_item", payload["type"] as? String == "message",
               payload["role"] as? String == "user", turn.id != nil, !turn.hasUserInput {
                turn.continuationOperationID = Self.continuationMarker(in: Self.inputText(payload["content"]))
                turn.hasUserInput = true
                continue
            }
            guard type == "event_msg", let event = payload["type"] as? String else { continue }
            let id = payload["turn_id"] as? String
            let timestamp = Self.timestamp(record["timestamp"])
            switch event {
            case "task_started":
                turn = TurnState(id: id, phase: .inProgress, startedAt: timestamp, projectedOffset: size, isCurrent: true)
                quotaErrorTurnID = nil
            case "user_message":
                guard turn.phase == .inProgress, turn.id != nil else {
                    turn.isCurrent = false
                    turn.diagnostic = "线程收到新输入，等待明确轮次"
                    continue
                }
                if !turn.hasUserInput {
                    turn.continuationOperationID = Self.continuationMarker(in: payload["message"] as? String ?? "")
                    turn.hasUserInput = true
                }
            case "agent_message":
                // 旧版消息可能没有 turn_id，只能归入当前尚未结束的明确轮次。
                if turn.phase == .inProgress, turn.id != nil,
                   payload["turn_id"] == nil || payload["turn_id"] is NSNull || id == turn.id,
                   Self.hasNonemptyText(payload["message"]) {
                    turn.hasAgentProgress = true
                }
            case "item_completed":
                // raw rollout 使用 PascalCase；完成事件仍可能携带 failed 状态。
                // 只接受本轮已完成工作，不能把晚到的前轮事件或排队输入当作进展。
                if turn.phase == .inProgress, let id, id == turn.id,
                   let item = payload["item"] as? [String: Any], Self.hasCompletedLegacyProgress(item) {
                    turn.hasAgentProgress = true
                }
            case "error":
                // 错误通知本身不证明该轮已经停止，必须随后看到该轮的失败终态。
                if id != nil, id == turn.id, Self.isQuotaError(payload), payload["will_retry"] as? Bool != true {
                    quotaErrorTurnID = id
                }
            case "task_failed":
                guard let id, id == turn.id else { turn.isCurrent = false; continue }
                turn.phase = (Self.isQuotaError(payload["error"] as? [String: Any]) || Self.isQuotaError(payload)
                    || quotaErrorTurnID == id) ? .quotaBlocked : .failed
                turn.completedAt = timestamp
            case "task_complete":
                guard let id, id == turn.id else { turn.isCurrent = false; continue }
                turn.phase = .completed
                turn.completedAt = timestamp
            case "turn_aborted", "task_cancelled":
                guard let id, id == turn.id else { turn.isCurrent = false; continue }
                turn.phase = .interrupted
                turn.completedAt = timestamp
            default:
                Self.applyControlEvent(payload, turn: &turn)
            }
            turn.ordinal = (record["ordinal"] as? NSNumber)?.int64Value ?? turn.ordinal
        }
        if turn.id == nil { turn.isCurrent = false; turn.diagnostic = "旧版记录中缺少明确的轮次身份" }
        if turn.phase == .quotaBlocked && turn.completedAt == nil { turn.isCurrent = false }
        return turn
    }

    private static func hasCompletedLegacyProgress(_ item: [String: Any]) -> Bool {
        switch item["type"] as? String {
        case "AgentMessage":
            guard let content = item["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["type"] as? String == "Text" && Self.hasNonemptyText($0["text"]) }
        case "CommandExecution", "FileChange", "McpToolCall", "DynamicToolCall", "WebSearch":
            return item["status"] as? String == "completed"
        default:
            return false
        }
    }

    private static func hasNonemptyText(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func inputText(_ content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { item -> String? in
            guard ["text", "input_text"].contains(item["type"] as? String ?? "") else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
    }

    private static func continuationMarker(in text: String) -> String? {
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let expression = try? NSRegularExpression(pattern: "\\bcodexbar-resume:(\(uuid))\\b") else { return nil }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let ids = Set(matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text),
                  let id = UUID(uuidString: String(text[range])) else { return nil }
            return id.uuidString.lowercased()
        })
        return ids.count == 1 ? ids.first : nil
    }

    private func applyPostTurnEvents(url: URL, offset: Int64, size: Int64, turn: inout TurnState) throws {
        let records = try self.readRecords(url: url, offset: offset, size: size, discardFirst: false)
        for record in records {
            guard let payload = record["payload"] as? [String: Any] else { continue }
            if record["type"] as? String == "event_msg" {
                Self.applyControlEvent(payload, turn: &turn)
                if ["task_started", "user_message"].contains(payload["type"] as? String ?? "") {
                    turn.isCurrent = false
                    turn.diagnostic = "线程收到新输入，等待轮次索引同步"
                }
            }
        }
    }

    private static func applyControlEvent(_ payload: [String: Any], turn: inout TurnState) {
        let type = payload["type"] as? String
        if type == "thread_goal_updated", let goal = payload["goal"] as? [String: Any],
           let status = goal["status"] as? String,
           ["paused", "blocked", "complete", "completed", "budgetLimited", "budget_limited"].contains(status) {
            turn.phase = .interrupted
            turn.diagnostic = "目标已停止或需要用户处理"
        } else if ["turn_aborted", "task_cancelled"].contains(type ?? "") {
            turn.phase = .interrupted
        }
    }

    private func readRecords(url: URL, offset: Int64, size: Int64, discardFirst: Bool) throws -> [[String: Any]] {
        guard offset >= 0, size >= offset, size - offset <= Self.maximumTailBytes else {
            throw ReadError.unavailable("线程末尾记录过大，无法确认最新状态")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
        guard data.count == size - offset, data.isEmpty || data.last == 10 else {
            throw ReadError.unavailable("线程末尾记录尚未写完")
        }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if discardFirst && !lines.isEmpty { lines.removeFirst() }
        var records: [[String: Any]] = []
        for line in lines where !line.isEmpty {
            guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw ReadError.unavailable("线程记录格式不受支持")
            }
            records.append(record)
        }
        return records
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    private final class ReadConnection {
        private let handle: OpaquePointer

        init(url: URL) throws {
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                  let database else {
                if let database { sqlite3_close(database) }
                throw ReadError.unavailable("无法只读打开 Codex 数据库")
            }
            self.handle = database
            sqlite3_busy_timeout(database, 250)
        }

        deinit { sqlite3_close(self.handle) }

        func prepare(_ sql: String) throws -> ReadStatement { try ReadStatement(database: self.handle, sql: sql) }

        func columns(table: String) throws -> Set<String> {
            // 调用者只传入代码内固定表名，不接受数据库或用户传来的 SQL 标识符。
            let statement = try self.prepare("PRAGMA table_info(\(table))")
            var result: Set<String> = []
            while try statement.next() { if let name = statement.text(1) { result.insert(name) } }
            return result
        }
    }

    private final class ReadStatement {
        private let handle: OpaquePointer

        init(database: OpaquePointer, sql: String) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ReadError.unavailable("Codex 数据库查询不受支持")
            }
            self.handle = statement
        }

        deinit { sqlite3_finalize(self.handle) }

        func bind(_ text: String, at index: Int32) throws {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(self.handle, index, text, -1, transient) == SQLITE_OK else {
                throw ReadError.unavailable("无法绑定 Codex 查询参数")
            }
        }

        func bind(_ value: Int64, at index: Int32) throws {
            guard sqlite3_bind_int64(self.handle, index, value) == SQLITE_OK else {
                throw ReadError.unavailable("无法绑定 Codex 查询参数")
            }
        }

        func next() throws -> Bool {
            switch sqlite3_step(self.handle) {
            case SQLITE_ROW: true
            case SQLITE_DONE: false
            default: throw ReadError.unavailable("Codex 数据库暂时不可读")
            }
        }

        func text(_ column: Int32) -> String? {
            guard let value = sqlite3_column_text(self.handle, column) else { return nil }
            let text = String(cString: value)
            return text.isEmpty ? nil : text
        }

        func integer(_ column: Int32) -> Int64? {
            sqlite3_column_type(self.handle, column) == SQLITE_NULL ? nil : sqlite3_column_int64(self.handle, column)
        }
    }
}
