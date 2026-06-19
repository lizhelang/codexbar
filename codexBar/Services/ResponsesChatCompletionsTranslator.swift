import Foundation

/// Pure, testable translation between OpenAI Responses API (used by Codex) and the
/// classic Chat Completions API (used by most domestic and OpenAI-compatible providers).
///
/// Ported and adapted from the reference bridges `talkcozy/api2codex`,
/// `lihuanshuai/codex-relay` and `soddygo/codex-convert-proxy`. The streaming converter
/// always emits the message output item before any reasoning delta so Codex never sees a
/// delta referencing an item that does not yet exist (the `sub2api` #2875 ordering bug).
enum ResponsesChatCompletionsTranslator {
    // MARK: - Request: Responses -> Chat Completions

    static func chatRequestBody(
        fromResponses body: [String: Any],
        model: String,
        quirks: CodexBarChatQuirks,
        forceStream: Bool = true
    ) -> [String: Any] {
        let source = self.unwrapResponseCreateEnvelope(body)

        var request: [String: Any] = [
            "model": model,
            "messages": self.messages(from: source, quirks: quirks),
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

        let tools = self.tools(from: source["tools"])
        if tools.isEmpty == false {
            request["tools"] = tools
            if let toolChoice = self.toolChoice(
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

    private static func messages(from body: [String: Any], quirks: CodexBarChatQuirks) -> [[String: Any]] {
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
            case "function_call":
                let callID = (object["call_id"] as? String) ?? (object["id"] as? String) ?? ""
                pendingToolCalls.append([
                    "id": callID,
                    "type": "function",
                    "function": [
                        "name": object["name"] as? String ?? "",
                        "arguments": object["arguments"] as? String ?? "{}",
                    ],
                ])
            case "function_call_output":
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
                guard object["role"] != nil || itemType == "message" else { continue }
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

    private static func tools(from value: Any?) -> [[String: Any]] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item -> [String: Any]? in
            guard let tool = item as? [String: Any],
                  (tool["type"] as? String) == "function" else {
                return nil
            }
            let function = (tool["function"] as? [String: Any]) ?? tool
            return [
                "type": "function",
                "function": [
                    "name": function["name"] as? String ?? "",
                    "description": function["description"] as? String ?? "",
                    "parameters": function["parameters"] ?? [String: Any](),
                ],
            ]
        }
    }

    private static func toolChoice(
        from value: Any?,
        tools: [[String: Any]],
        quirks: CodexBarChatQuirks
    ) -> Any? {
        guard tools.isEmpty == false else { return nil }
        if quirks.toolChoiceDowngradeToAuto {
            return "auto"
        }
        guard let value, value is NSNull == false else {
            return "auto"
        }
        if let choice = value as? String {
            switch choice {
            case "auto", "none", "required":
                return choice
            default:
                return "auto"
            }
        }
        guard let object = value as? [String: Any] else {
            return "auto"
        }
        if (object["type"] as? String) == "function" {
            let name = (object["name"] as? String)
                ?? ((object["function"] as? [String: Any])?["name"] as? String)
            if let name, name.isEmpty == false {
                return ["type": "function", "function": ["name": name]]
            }
        }
        return "auto"
    }

    // MARK: - Non-streaming response: Chat Completions -> Responses

    static func responsesEnvelope(
        fromChatCompletion chatResponse: [String: Any],
        model: String,
        responseID: String,
        reasoningEffort: String?
    ) -> [String: Any] {
        let choices = chatResponse["choices"] as? [Any]
        let firstChoice = choices?.first as? [String: Any]
        let message = firstChoice?["message"] as? [String: Any] ?? [:]
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
        if let toolCalls = message["tool_calls"] as? [Any] {
            for case let toolCall as [String: Any] in toolCalls {
                let function = toolCall["function"] as? [String: Any] ?? [:]
                let callID = (toolCall["id"] as? String) ?? Self.makeID("call")
                output.append([
                    "id": callID,
                    "type": "function_call",
                    "call_id": callID,
                    "name": function["name"] as? String ?? "",
                    "arguments": function["arguments"] as? String ?? "{}",
                    "status": "completed",
                ])
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

    // MARK: - Streaming response: Chat Completions SSE -> Responses SSE

    final class StreamConverter {
        private let model: String
        private let responseID: String
        private let reasoningEffort: String?
        private let supportsReasoning: Bool
        private let messageID: String
        private let createdAt: Int

        private var fullText = ""
        private var outputIndex = 0
        private var messageClosed = false
        private var activeToolCalls: [Int: ToolCallState] = [:]
        private var completedToolCalls: [ToolCallState] = []
        private var inputTokens = 0
        private var outputTokens = 0

        private struct ToolCallState {
            let id: String
            var name: String
            var arguments: String
        }

        init(
            model: String,
            responseID: String,
            reasoningEffort: String?,
            supportsReasoning: Bool = true
        ) {
            self.model = model
            self.responseID = responseID
            self.reasoningEffort = reasoningEffort
            self.supportsReasoning = supportsReasoning
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
        func consume(chunk: [String: Any]) -> [[String: Any]] {
            var events: [[String: Any]] = []

            guard let choices = chunk["choices"] as? [Any], choices.isEmpty == false else {
                self.captureUsage(chunk["usage"])
                return events
            }
            guard let choice = choices.first as? [String: Any] else { return events }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let finishReason = choice["finish_reason"] as? String

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

            if let toolCalls = delta["tool_calls"] as? [Any] {
                for case let toolCall as [String: Any] in toolCalls {
                    events.append(contentsOf: self.handleToolCallDelta(toolCall))
                }
            }

            if finishReason == "tool_calls" {
                events.append(contentsOf: self.closeMessageItem())
                events.append(contentsOf: self.completeActiveToolCalls())
            }

            self.captureUsage(chunk["usage"])
            return events
        }

        /// Events emitted after the upstream stream ends.
        func finishEvents() -> [[String: Any]] {
            var events: [[String: Any]] = []
            events.append(contentsOf: self.closeMessageItem())
            events.append(contentsOf: self.completeActiveToolCalls())

            var output: [[String: Any]] = []
            if self.fullText.isEmpty == false {
                output.append([
                    "id": self.messageID,
                    "type": "message",
                    "role": "assistant",
                    "status": "completed",
                    "content": [["type": "output_text", "text": self.fullText, "annotations": []]],
                ])
            }
            for toolCall in self.completedToolCalls {
                output.append([
                    "id": toolCall.id,
                    "type": "function_call",
                    "call_id": toolCall.id,
                    "name": toolCall.name,
                    "arguments": toolCall.arguments,
                    "status": "completed",
                ])
            }

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
            var events: [[String: Any]] = []
            let index = (toolCall["index"] as? Int) ?? 0
            let function = toolCall["function"] as? [String: Any] ?? [:]
            let toolID = toolCall["id"] as? String

            let knownIDs = Set(self.activeToolCalls.values.map { $0.id })
            if let toolID, toolID.isEmpty == false, knownIDs.contains(toolID) == false {
                events.append(contentsOf: self.closeMessageItem())
                let name = function["name"] as? String ?? ""
                let arguments = function["arguments"] as? String ?? ""
                self.activeToolCalls[index] = ToolCallState(id: toolID, name: name, arguments: arguments)
                events.append([
                    "type": "response.output_item.added",
                    "output_index": self.outputIndex + index,
                    "item": [
                        "id": toolID,
                        "type": "function_call",
                        "call_id": toolID,
                        "name": name,
                        "arguments": "",
                        "status": "in_progress",
                    ],
                ])
                if let argsDelta = function["arguments"] as? String, argsDelta.isEmpty == false {
                    events.append([
                        "type": "response.function_call_arguments.delta",
                        "item_id": toolID,
                        "output_index": self.outputIndex + index,
                        "delta": argsDelta,
                    ])
                }
            } else if var state = self.activeToolCalls[index] {
                let argsDelta = function["arguments"] as? String ?? ""
                if argsDelta.isEmpty == false {
                    state.arguments += argsDelta
                    self.activeToolCalls[index] = state
                    events.append([
                        "type": "response.function_call_arguments.delta",
                        "item_id": state.id,
                        "output_index": self.outputIndex + index,
                        "delta": argsDelta,
                    ])
                }
            }
            return events
        }

        private func completeActiveToolCalls() -> [[String: Any]] {
            var events: [[String: Any]] = []
            for index in self.activeToolCalls.keys.sorted() {
                guard let state = self.activeToolCalls[index] else { continue }
                self.completedToolCalls.append(state)
                events.append([
                    "type": "response.function_call_arguments.done",
                    "item_id": state.id,
                    "output_index": self.outputIndex + index,
                    "arguments": state.arguments,
                ])
                events.append([
                    "type": "response.output_item.done",
                    "output_index": self.outputIndex + index,
                    "item": [
                        "id": state.id,
                        "type": "function_call",
                        "call_id": state.id,
                        "name": state.name,
                        "arguments": state.arguments,
                        "status": "completed",
                    ],
                ])
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
