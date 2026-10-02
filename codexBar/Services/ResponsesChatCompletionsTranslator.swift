import Foundation

/// Pure, testable translation between OpenAI Responses API (used by Codex) and the
/// classic Chat Completions API (used by most domestic and OpenAI-compatible providers).
///
/// Ported and adapted from the reference bridges `talkcozy/api2codex`,
/// `lihuanshuai/codex-relay` and `soddygo/codex-convert-proxy`. The streaming converter
/// always emits the message output item before any reasoning delta so Codex never sees a
/// delta referencing an item that does not yet exist (the `sub2api` #2875 ordering bug).
enum ResponsesChatCompletionsTranslator {
    enum TranslationError: LocalizedError {
        case unsupported(String)
        case invalidCustomInput
        case invalidUpstream(String)

        var errorDescription: String? {
            switch self {
            case let .unsupported(detail):
                return "Chat Completions compatibility gateway cannot translate \(detail). Use a Responses API provider for this capability."
            case .invalidCustomInput:
                return "The upstream custom tool call must contain a JSON object with exactly one string field named input."
            case let .invalidUpstream(detail):
                return "The upstream Chat Completions response could not be completed: \(detail). No pending tool calls were released."
            }
        }
    }

    static func customToolNames(fromResponses body: [String: Any]) -> Set<String> {
        let source = self.unwrapResponseCreateEnvelope(body)
        let tools = source["tools"] as? [[String: Any]] ?? []
        return Set(tools.filter { $0["type"] as? String == "custom" }.compactMap { $0["name"] as? String })
    }

    // MARK: - Request: Responses -> Chat Completions

    static func chatRequestBody(
        fromResponses body: [String: Any],
        model: String,
        quirks: CodexBarChatQuirks,
        forceStream: Bool = true
    ) throws -> [String: Any] {
        let source = self.unwrapResponseCreateEnvelope(body)

        var request: [String: Any] = [
            "model": model,
            "messages": try self.messages(from: source, quirks: quirks),
            "stream": forceStream || (source["stream"] as? Bool ?? false),
        ]

        if let temperature = source["temperature"], temperature is NSNull == false {
            request["temperature"] = temperature
        }
        if let topP = source["top_p"], topP is NSNull == false {
            request["top_p"] = topP
        }
        if let maxOutputTokens = source["max_output_tokens"], maxOutputTokens is NSNull == false {
            request[quirks.maxTokensField] = maxOutputTokens
        }
        if let parallel = source["parallel_tool_calls"], parallel is NSNull == false {
            request["parallel_tool_calls"] = parallel
        }

        let tools = try self.tools(from: source["tools"])
        if tools.isEmpty == false {
            request["tools"] = tools
            if let toolChoice = try self.toolChoice(
                from: source["tool_choice"],
                tools: tools,
                quirks: quirks
            ) {
                request["tool_choice"] = toolChoice
            }
        }

        return request
    }

    private static func unwrapResponseCreateEnvelope(_ json: [String: Any]) -> [String: Any] {
        guard json["input"] == nil,
              (json["type"] as? String) == "response.create",
              let response = json["response"] as? [String: Any] else {
            return json
        }
        return response
    }

    private static func messages(from body: [String: Any], quirks: CodexBarChatQuirks) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []

        if let instructions = (body["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           instructions.isEmpty == false {
            messages.append(["role": "system", "content": instructions])
        }

        let input = body["input"]
        if let text = input as? String {
            messages.append(["role": "user", "content": text])
            return messages
        }

        guard let items = input as? [Any] else {
            return messages
        }

        var pendingToolCalls: [[String: Any]] = []
        func flushToolCalls() {
            guard pendingToolCalls.isEmpty == false else { return }
            messages.append([
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": pendingToolCalls,
            ])
            pendingToolCalls = []
        }

        for item in items {
            if let text = item as? String {
                flushToolCalls()
                messages.append(["role": "user", "content": text])
                continue
            }
            guard let object = item as? [String: Any] else { continue }
            let itemType = object["type"] as? String ?? ""

            switch itemType {
            case "function_call", "custom_tool_call":
                let callID = (object["call_id"] as? String) ?? (object["id"] as? String) ?? ""
                pendingToolCalls.append([
                    "id": callID,
                    "type": "function",
                    "function": [
                        "name": object["name"] as? String ?? "",
                        "arguments": itemType == "custom_tool_call"
                            ? try self.encodeCustomInput(object["input"])
                            : object["arguments"] as? String ?? "{}",
                    ],
                ])
            case "function_call_output", "custom_tool_call_output":
                flushToolCalls()
                messages.append([
                    "role": "tool",
                    "tool_call_id": object["call_id"] as? String ?? "",
                    "content": self.toolOutputContent(object["output"]),
                ])
            case "reasoning":
                // Reasoning items from prior turns are not representable in Chat Completions.
                continue
            default:
                // Regular message (user / assistant / system / developer) or a bare role object.
                guard object["role"] != nil || itemType == "message" else {
                    throw TranslationError.unsupported("input item type \(itemType)")
                }
                flushToolCalls()
                var role = (object["role"] as? String) ?? "user"
                if role == "developer" {
                    role = "system"
                }
                let content = self.messageContent(object["content"], quirks: quirks)
                messages.append(["role": role, "content": content])
            }
        }

        flushToolCalls()
        return messages
    }

    private static func toolOutputContent(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let value, value is NSNull == false,
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    private static func messageContent(_ content: Any?, quirks: CodexBarChatQuirks) -> Any {
        if quirks.flattenContent {
            return self.flattenContent(content)
        }
        if let text = content as? String {
            return text
        }
        guard let parts = content as? [Any] else {
            return ""
        }

        let compatibleParts = parts.compactMap(self.compatibleChatContentPart)
        if compatibleParts.count == parts.count {
            return compatibleParts
        }
        return self.flattenContent(content)
    }

    private static func compatibleChatContentPart(_ part: Any) -> [String: Any]? {
        guard let object = part as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "input_text", "output_text", "text":
            return ["type": "text", "text": object["text"] as? String ?? ""]
        case "input_image", "image_url":
            if let imageURL = object["image_url"] as? String {
                return ["type": "image_url", "image_url": ["url": imageURL]]
            }
            if let imageURL = object["image_url"] {
                return ["type": "image_url", "image_url": imageURL]
            }
            if let imageURL = object["url"] as? String {
                return ["type": "image_url", "image_url": ["url": imageURL]]
            }
            return nil
        default:
            return nil
        }
    }

    private static func flattenContent(_ content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        guard let parts = content as? [Any] else {
            return ""
        }
        var pieces: [String] = []
        for part in parts {
            guard let object = part as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "input_text", "output_text", "text":
                pieces.append(object["text"] as? String ?? "")
            case "input_image", "image_url":
                pieces.append("[image]")
            default:
                if let text = object["text"] as? String {
                    pieces.append(text)
                }
            }
        }
        return pieces.joined(separator: "\n")
    }

    private static func encodeCustomInput(_ value: Any?) throws -> String {
        guard let input = value as? String else { throw TranslationError.invalidCustomInput }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["input": input]), as: UTF8.self)
    }

    private static func decodeCustomInput(_ arguments: String) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any],
              object.count == 1, let input = object["input"] as? String else {
            throw TranslationError.invalidCustomInput
        }
        return input
    }

    private static func tools(from value: Any?) throws -> [[String: Any]] {
        guard let value, value is NSNull == false else { return [] }
        guard let items = value as? [[String: Any]] else { throw TranslationError.unsupported("tools") }
        var names = Set<String>()
        return try items.map { tool in
            let type = tool["type"] as? String ?? ""
            guard type == "function" || type == "custom" else {
                throw TranslationError.unsupported("tool type \(type)")
            }
            let function = (tool["function"] as? [String: Any]) ?? tool
            guard let name = function["name"] as? String, !name.isEmpty, names.insert(name).inserted else {
                throw TranslationError.unsupported("missing or duplicate tool names")
            }
            var description = function["description"] as? String ?? ""
            var definition: [String: Any] = ["name": name, "description": description]
            if type == "custom" {
                if let formatValue = tool["format"] {
                    guard let format = formatValue as? [String: Any] else {
                        throw TranslationError.unsupported("custom tool format")
                    }
                    switch format["type"] as? String {
                    case "text": break
                    case "grammar":
                        guard let syntax = format["syntax"] as? String, ["lark", "regex"].contains(syntax),
                              let grammar = format["definition"] as? String else {
                            throw TranslationError.unsupported("custom tool grammar")
                        }
                        // Chat APIs cannot enforce Responses grammars. Preserve the requirements as
                        // instructions; the tool receiver must still validate the actual input.
                        description += "\nThe input string must follow this \(syntax) grammar:\n\(grammar)"
                    default: throw TranslationError.unsupported("custom tool format")
                    }
                }
                definition["description"] = description + "\nProvide the complete raw tool input in the input string field."
                definition["parameters"] = [
                    "type": "object", "properties": ["input": ["type": "string"]],
                    "required": ["input"], "additionalProperties": false,
                ]
            } else {
                definition["parameters"] = function["parameters"] ?? [String: Any]()
                if let strict = function["strict"] { definition["strict"] = strict }
            }
            return ["type": "function", "function": definition]
        }
    }

    private static func toolChoice(
        from value: Any?,
        tools: [[String: Any]],
        quirks: CodexBarChatQuirks
    ) throws -> Any? {
        guard !tools.isEmpty else { return nil }
        guard let value, value is NSNull == false else { return "auto" }
        if let choice = value as? String, ["auto", "none", "required"].contains(choice) {
            // Never downgrade "none": it explicitly forbids tool execution.
            return quirks.toolChoiceDowngradeToAuto && choice == "required" ? "auto" : choice
        }
        if let object = value as? [String: Any],
           ["function", "custom"].contains(object["type"] as? String ?? ""),
           let name = (object["name"] as? String) ?? ((object["function"] as? [String: Any])?["name"] as? String),
           tools.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == name }) {
            return quirks.toolChoiceDowngradeToAuto ? "auto" : ["type": "function", "function": ["name": name]]
        }
        throw TranslationError.unsupported("tool_choice")
    }

    private static func toolCallItem(id: String, name: String, arguments: String, customToolNames: Set<String>) throws -> [String: Any] {
        guard !name.isEmpty else { throw TranslationError.unsupported("upstream tool call without a name") }
        let isCustom = customToolNames.contains(name)
        return [
            "id": id, "call_id": id, "name": name, "status": "completed",
            "type": isCustom ? "custom_tool_call" : "function_call",
            isCustom ? "input" : "arguments": isCustom ? try self.decodeCustomInput(arguments) : arguments,
        ]
    }

    // MARK: - Non-streaming response: Chat Completions -> Responses

    static func responsesEnvelope(
        fromChatCompletion chatResponse: [String: Any],
        model: String,
        responseID: String,
        reasoningEffort: String?,
        customToolNames: Set<String> = []
    ) throws -> [String: Any] {
        guard chatResponse["error"] == nil else { throw TranslationError.invalidUpstream("provider returned an error") }
        guard let choices = chatResponse["choices"] as? [[String: Any]],
              let firstChoice = choices.first, let message = firstChoice["message"] as? [String: Any] else {
            throw TranslationError.invalidUpstream("missing completion message")
        }
        let hasToolCalls = (message["tool_calls"] as? [Any])?.isEmpty == false
        try self.validateFinishReason(firstChoice["finish_reason"] as? String, hasToolCalls: hasToolCalls)
        let contentText = (message["content"] as? String) ?? ""

        var output: [[String: Any]] = []
        if contentText.isEmpty == false {
            output.append([
                "id": Self.makeID("msg"),
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [["type": "output_text", "text": contentText, "annotations": []]],
            ])
        }
        if let rawToolCalls = message["tool_calls"], !(rawToolCalls is NSNull) {
            guard let toolCalls = rawToolCalls as? [[String: Any]] else {
                throw TranslationError.invalidUpstream("invalid tool calls")
            }
            for toolCall in toolCalls {
                let function = toolCall["function"] as? [String: Any] ?? [:]
                let callID = (toolCall["id"] as? String) ?? Self.makeID("call")
                output.append(try self.toolCallItem(
                    id: callID,
                    name: function["name"] as? String ?? "",
                    arguments: function["arguments"] as? String ?? "{}",
                    customToolNames: customToolNames
                ))
            }
        }

        let usage = chatResponse["usage"] as? [String: Any] ?? [:]
        return self.responseObject(
            id: responseID,
            createdAt: Int(Date().timeIntervalSince1970),
            status: "completed",
            model: model,
            output: output,
            usage: self.usageObject(from: usage),
            reasoningEffort: reasoningEffort
        )
    }

    private static func validateFinishReason(_ reason: String?, hasToolCalls: Bool) throws {
        guard let reason else { throw TranslationError.invalidUpstream("missing finish_reason") }
        guard reason == "stop" || reason == "tool_calls" else {
            throw TranslationError.invalidUpstream("the generation ended without a complete result")
        }
        guard (reason == "tool_calls") == hasToolCalls else {
            throw TranslationError.invalidUpstream("finish_reason does not match the generated tool calls")
        }
    }

    // MARK: - Streaming response: Chat Completions SSE -> Responses SSE

    final class StreamConverter {
        private let model: String
        private let responseID: String
        private let reasoningEffort: String?
        private let supportsReasoning: Bool
        private let customToolNames: Set<String>
        private let messageID: String
        private let createdAt: Int

        private var fullText = ""
        private var outputIndex = 0
        private var messageClosed = false
        private var activeToolCalls: [Int: ToolCallState] = [:]
        private var completedToolCalls: [[String: Any]] = []
        private var inputTokens = 0
        private var outputTokens = 0
        private var finishReason: String?
        private var streamFailure: TranslationError?

        private struct ToolCallState {
            let id: String
            var name: String
            var arguments: String
        }

        init(
            model: String,
            responseID: String,
            reasoningEffort: String?,
            supportsReasoning: Bool = true,
            customToolNames: Set<String> = []
        ) {
            self.model = model
            self.responseID = responseID
            self.reasoningEffort = reasoningEffort
            self.supportsReasoning = supportsReasoning
            self.customToolNames = customToolNames
            self.messageID = ResponsesChatCompletionsTranslator.makeID("msg")
            self.createdAt = Int(Date().timeIntervalSince1970)
        }

        /// Events emitted before consuming any upstream chunk.
        func startEvents() -> [[String: Any]] {
            let emptyResponse: [String: Any] = [
                "id": self.responseID,
                "object": "response",
                "created_at": self.createdAt,
                "status": "in_progress",
                "model": self.model,
                "output": [],
                "usage": NSNull(),
            ]
            return [
                ["type": "response.created", "response": emptyResponse],
                ["type": "response.in_progress", "response": emptyResponse],
                [
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": [
                        "id": self.messageID,
                        "type": "message",
                        "role": "assistant",
                        "status": "in_progress",
                        "content": [],
                    ],
                ],
                [
                    "type": "response.content_part.added",
                    "item_id": self.messageID,
                    "output_index": 0,
                    "content_index": 0,
                    "part": ["type": "output_text", "text": "", "annotations": []],
                ],
            ]
        }

        /// Convert a single upstream Chat Completions chunk into zero or more Responses events.
        func consume(chunk: [String: Any]) throws -> [[String: Any]] {
            if let streamFailure = self.streamFailure { throw streamFailure }
            do {
                return try self.consumeValidChunk(chunk)
            } catch let error as TranslationError {
                self.streamFailure = error
                throw error
            }
        }

        private func consumeValidChunk(_ chunk: [String: Any]) throws -> [[String: Any]] {
            var events: [[String: Any]] = []
            guard chunk["error"] == nil else { throw TranslationError.invalidUpstream("provider returned an error") }
            guard let choices = chunk["choices"] as? [[String: Any]] else {
                throw TranslationError.invalidUpstream("missing choices in stream frame")
            }
            if choices.isEmpty {
                guard chunk["usage"] is [String: Any] else {
                    throw TranslationError.invalidUpstream("empty stream frame")
                }
                self.captureUsage(chunk["usage"])
                return []
            }
            guard self.finishReason == nil else {
                throw TranslationError.invalidUpstream("completion data received after finish_reason")
            }
            let choice = choices[0]
            guard let delta = choice["delta"] as? [String: Any] else {
                throw TranslationError.invalidUpstream("missing delta in stream frame")
            }
            let finishReason = choice["finish_reason"] as? String
            if let value = choice["finish_reason"], !(value is NSNull), finishReason == nil {
                throw TranslationError.invalidUpstream("invalid finish_reason")
            }

            if self.supportsReasoning,
               let reasoning = delta["reasoning_content"] as? String,
               reasoning.isEmpty == false {
                events.append([
                    "type": "response.reasoning_text.delta",
                    "item_id": self.messageID,
                    "output_index": 0,
                    "content_index": 0,
                    "delta": reasoning,
                ])
            }

            if let text = delta["content"] as? String, text.isEmpty == false {
                self.fullText += text
                events.append([
                    "type": "response.output_text.delta",
                    "item_id": self.messageID,
                    "output_index": 0,
                    "content_index": 0,
                    "delta": text,
                ])
            }

            if let rawToolCalls = delta["tool_calls"], !(rawToolCalls is NSNull) {
                guard let toolCalls = rawToolCalls as? [[String: Any]] else {
                    throw TranslationError.invalidUpstream("invalid streamed tool calls")
                }
                for toolCall in toolCalls {
                    events.append(contentsOf: self.handleToolCallDelta(toolCall))
                }
            }

            if let finishReason {
                try ResponsesChatCompletionsTranslator.validateFinishReason(
                    finishReason, hasToolCalls: !self.activeToolCalls.isEmpty
                )
                self.finishReason = finishReason
            }

            self.captureUsage(chunk["usage"])
            return events
        }

        /// Events emitted after the upstream stream ends.
        func finishEvents() throws -> [[String: Any]] {
            if let streamFailure = self.streamFailure { throw streamFailure }
            try ResponsesChatCompletionsTranslator.validateFinishReason(
                self.finishReason, hasToolCalls: !self.activeToolCalls.isEmpty
            )
            var events: [[String: Any]] = []
            events.append(contentsOf: self.closeMessageItem())
            events.append(contentsOf: try self.completeActiveToolCalls())

            // Keep output index 0 consistent with the message item already emitted,
            // including tool-only responses whose message text is empty.
            var output: [[String: Any]] = [[
                "id": self.messageID,
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [["type": "output_text", "text": self.fullText, "annotations": []]],
            ]]
            output.append(contentsOf: self.completedToolCalls)

            events.append([
                "type": "response.completed",
                "response": ResponsesChatCompletionsTranslator.responseObject(
                    id: self.responseID,
                    createdAt: self.createdAt,
                    status: "completed",
                    model: self.model,
                    output: output,
                    usage: [
                        "input_tokens": self.inputTokens,
                        "output_tokens": self.outputTokens,
                        "total_tokens": self.inputTokens + self.outputTokens,
                    ],
                    reasoningEffort: self.reasoningEffort
                ),
            ])
            return events
        }

        func failureEvent(message: String) -> [String: Any] {
            [
                "type": "response.failed",
                "response": [
                    "id": self.responseID,
                    "status": "failed",
                    "error": ["code": "server_error", "message": message],
                ],
            ]
        }

        private func handleToolCallDelta(_ toolCall: [String: Any]) -> [[String: Any]] {
            let index = toolCall["index"] as? Int ?? 0
            let function = toolCall["function"] as? [String: Any] ?? [:]
            var state = self.activeToolCalls[index] ?? ToolCallState(
                id: toolCall["id"] as? String ?? ResponsesChatCompletionsTranslator.makeID("call"),
                name: "", arguments: ""
            )
            if let name = function["name"] as? String { state.name += name }
            if let arguments = function["arguments"] as? String { state.arguments += arguments }
            self.activeToolCalls[index] = state
            // Buffer tool data until its complete shape is known. In particular, partial
            // JSON string escaping cannot safely be emitted as freeform custom input.
            return []
        }

        private func completeActiveToolCalls() throws -> [[String: Any]] {
            var events: [[String: Any]] = []
            let items = try self.activeToolCalls.keys.sorted().compactMap { index -> [String: Any]? in
                guard let state = self.activeToolCalls[index] else { return nil }
                return try ResponsesChatCompletionsTranslator.toolCallItem(
                    id: state.id, name: state.name, arguments: state.arguments,
                    customToolNames: self.customToolNames
                )
            }
            for item in items {
                let index = self.outputIndex + self.completedToolCalls.count
                let isCustom = item["type"] as? String == "custom_tool_call"
                let field = isCustom ? "input" : "arguments"
                let eventPrefix = isCustom ? "response.custom_tool_call_input" : "response.function_call_arguments"
                var started = item
                started["status"] = "in_progress"
                started[field] = ""
                events.append(["type": "response.output_item.added", "output_index": index, "item": started])
                events.append([
                    "type": eventPrefix + ".delta", "item_id": item["id"]!,
                    "output_index": index, "delta": item[field]!,
                ])
                events.append([
                    "type": eventPrefix + ".done", "item_id": item["id"]!,
                    "output_index": index, field: item[field]!,
                ])
                events.append(["type": "response.output_item.done", "output_index": index, "item": item])
                self.completedToolCalls.append(item)
            }
            self.activeToolCalls.removeAll()
            return events
        }

        private func closeMessageItem() -> [[String: Any]] {
            guard self.messageClosed == false else { return [] }
            self.messageClosed = true
            let events: [[String: Any]] = [
                [
                    "type": "response.output_text.done",
                    "item_id": self.messageID,
                    "output_index": 0,
                    "content_index": 0,
                    "text": self.fullText,
                ],
                [
                    "type": "response.content_part.done",
                    "item_id": self.messageID,
                    "output_index": 0,
                    "content_index": 0,
                    "part": ["type": "output_text", "text": self.fullText, "annotations": []],
                ],
                [
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": [
                        "id": self.messageID,
                        "type": "message",
                        "role": "assistant",
                        "status": "completed",
                        "content": [["type": "output_text", "text": self.fullText, "annotations": []]],
                    ],
                ],
            ]
            self.outputIndex = 1
            return events
        }

        private func captureUsage(_ value: Any?) {
            guard let usage = value as? [String: Any] else { return }
            if let prompt = usage["prompt_tokens"] as? Int {
                self.inputTokens = prompt
            }
            if let completion = usage["completion_tokens"] as? Int {
                self.outputTokens = completion
            }
        }
    }

    // MARK: - Shared helpers

    static func makeID(_ prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))"
    }

    static func sseData(for event: [String: Any]) -> Data {
        guard JSONSerialization.isValidJSONObject(event),
              let json = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: json, encoding: .utf8) else {
            return Data("data: {}\n\n".utf8)
        }
        return Data("data: \(jsonString)\n\n".utf8)
    }

    static var sseDoneData: Data {
        Data("data: [DONE]\n\n".utf8)
    }

    private static func usageObject(from usage: [String: Any]) -> [String: Any] {
        let input = usage["prompt_tokens"] as? Int ?? 0
        let output = usage["completion_tokens"] as? Int ?? 0
        return [
            "input_tokens": input,
            "output_tokens": output,
            "total_tokens": usage["total_tokens"] as? Int ?? (input + output),
        ]
    }

    private static func responseObject(
        id: String,
        createdAt: Int,
        status: String,
        model: String,
        output: [[String: Any]],
        usage: [String: Any],
        reasoningEffort: String?
    ) -> [String: Any] {
        [
            "id": id,
            "object": "response",
            "created_at": createdAt,
            "status": status,
            "model": model,
            "output": output,
            "usage": usage,
            "parallel_tool_calls": true,
            "previous_response_id": NSNull(),
            "reasoning": ["effort": reasoningEffort ?? "medium", "summary": "auto"],
            "text": ["format": ["type": "text"]],
            "tools": [],
            "truncation": "disabled",
        ]
    }
}
