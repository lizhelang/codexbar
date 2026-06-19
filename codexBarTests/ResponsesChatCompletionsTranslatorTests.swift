import Foundation
import XCTest

final class ResponsesChatCompletionsTranslatorTests: XCTestCase {
    // MARK: - Request conversion

    func testRequestMapsInstructionsInputToolsAndMaxTokens() throws {
        let body: [String: Any] = [
            "model": "gpt-5",
            "instructions": "You are helpful.",
            "max_output_tokens": 256,
            "temperature": 0.5,
            "input": [
                ["type": "message", "role": "user", "content": "hi"],
                ["type": "function_call", "call_id": "call_1", "name": "ls", "arguments": "{}"],
                ["type": "function_call_output", "call_id": "call_1", "output": "files"],
                ["type": "message", "role": "developer", "content": "be terse"],
            ],
            "tools": [
                ["type": "function", "name": "ls", "description": "list", "parameters": ["type": "object"]],
            ],
            "tool_choice": "auto",
        ]

        let request = ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: body,
            model: "deepseek-chat",
            quirks: .standard
        )

        XCTAssertEqual(request["model"] as? String, "deepseek-chat")
        XCTAssertEqual(request["stream"] as? Bool, true)
        XCTAssertEqual(request["max_tokens"] as? Int, 256)
        XCTAssertNil(request["max_completion_tokens"])

        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are helpful.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        let toolCalls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call_1")
        XCTAssertEqual((toolCalls.first?["function"] as? [String: Any])?["name"] as? String, "ls")
        XCTAssertEqual(messages[3]["role"] as? String, "tool")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages[3]["content"] as? String, "files")
        XCTAssertEqual(messages[4]["role"] as? String, "system", "developer role must map to system")

        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "ls")
    }

    func testRequestHonoursMaxCompletionTokensAndToolChoiceDowngradeQuirks() throws {
        let quirks = CodexBarChatQuirks(
            maxTokensField: "max_completion_tokens",
            toolChoiceDowngradeToAuto: true
        )
        let body: [String: Any] = [
            "max_output_tokens": 128,
            "input": "hi",
            "tools": [["type": "function", "name": "f", "parameters": [:]]],
            "tool_choice": ["type": "function", "name": "f"],
        ]

        let request = ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: body,
            model: "glm-4.6",
            quirks: quirks
        )

        XCTAssertEqual(request["max_completion_tokens"] as? Int, 128)
        XCTAssertNil(request["max_tokens"])
        XCTAssertEqual(request["tool_choice"] as? String, "auto")
    }

    func testRequestUnwrapsResponseCreateEnvelope() throws {
        let body: [String: Any] = [
            "type": "response.create",
            "response": ["input": "hello", "model": "x"],
        ]
        let request = ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: body,
            model: "kimi",
            quirks: .standard
        )
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "hello")
    }

    func testRequestSkipsReasoningInputItems() throws {
        let body: [String: Any] = [
            "input": [
                ["type": "reasoning", "summary": []],
                ["type": "message", "role": "user", "content": "go"],
            ],
        ]
        let request = ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: body,
            model: "m",
            quirks: .standard
        )
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    func testRequestPreservesStructuredContentUnlessFlattenQuirkIsEnabled() throws {
        let body: [String: Any] = [
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": "describe"],
                        ["type": "input_image", "image_url": "https://example.invalid/image.png"],
                    ],
                ],
            ],
        ]

        let request = ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: body,
            model: "m",
            quirks: .standard
        )

        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "describe")
        XCTAssertEqual(content.last?["type"] as? String, "image_url")
    }

    func testRequestFlattensStructuredContentWhenQuirkRequiresIt() throws {
        let body: [String: Any] = [
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": "describe"],
                        ["type": "input_image", "image_url": "https://example.invalid/image.png"],
                    ],
                ],
            ],
        ]

        let request = ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: body,
            model: "glm-4.6",
            quirks: CodexBarChatQuirks(flattenContent: true)
        )

        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "describe\n[image]")
    }

    // MARK: - Streaming conversion

    func testStreamConverterEmitsMessageItemBeforeReasoningDelta() throws {
        let converter = ResponsesChatCompletionsTranslator.StreamConverter(
            model: "deepseek-reasoner",
            responseID: "resp_test",
            reasoningEffort: "high"
        )

        let start = converter.startEvents()
        let startTypes = start.map { $0["type"] as? String }
        XCTAssertEqual(startTypes.first, "response.created")
        XCTAssertTrue(startTypes.contains("response.output_item.added"))
        XCTAssertTrue(startTypes.contains("response.content_part.added"))

        let reasoningChunk: [String: Any] = [
            "choices": [["delta": ["reasoning_content": "thinking"]]],
        ]
        let reasoningEvents = converter.consume(chunk: reasoningChunk)
        XCTAssertEqual(reasoningEvents.first?["type"] as? String, "response.reasoning_text.delta")
        XCTAssertEqual(reasoningEvents.first?["item_id"] as? String, reasoningEvents.first?["item_id"] as? String)

        let emptyReasoning: [String: Any] = [
            "choices": [["delta": ["reasoning_content": ""]]],
        ]
        XCTAssertTrue(converter.consume(chunk: emptyReasoning).isEmpty, "empty reasoning must be filtered")
    }

    func testStreamConverterAccumulatesTextAndCompletes() throws {
        let converter = ResponsesChatCompletionsTranslator.StreamConverter(
            model: "deepseek-chat",
            responseID: "resp_text",
            reasoningEffort: nil
        )
        _ = converter.startEvents()

        let e1 = converter.consume(chunk: ["choices": [["delta": ["content": "Hello "]]]])
        XCTAssertEqual(e1.first?["type"] as? String, "response.output_text.delta")
        XCTAssertEqual(e1.first?["delta"] as? String, "Hello ")
        _ = converter.consume(chunk: ["choices": [["delta": ["content": "world"]]]])

        let finish = converter.finishEvents()
        let types = finish.map { $0["type"] as? String }
        XCTAssertEqual(Array(types.prefix(3)), [
            "response.output_text.done",
            "response.content_part.done",
            "response.output_item.done",
        ])
        XCTAssertEqual(types.last, "response.completed")

        let completed = try XCTUnwrap(finish.first { $0["type"] as? String == "response.completed" })
        let response = try XCTUnwrap(completed["response"] as? [String: Any])
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        let message = try XCTUnwrap(output.first { $0["type"] as? String == "message" })
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Hello world")

        let textDone = try XCTUnwrap(finish.first { $0["type"] as? String == "response.output_text.done" })
        XCTAssertEqual(textDone["text"] as? String, "Hello world")
    }

    func testStreamConverterSuppressesReasoningWhenProviderDoesNotSupportIt() throws {
        let converter = ResponsesChatCompletionsTranslator.StreamConverter(
            model: "plain-chat",
            responseID: "resp_plain",
            reasoningEffort: "high",
            supportsReasoning: false
        )

        let events = converter.consume(chunk: [
            "choices": [["delta": ["reasoning_content": "thinking"]]],
        ])

        XCTAssertTrue(events.isEmpty)
    }

    func testStreamConverterEmitsFunctionCallItems() throws {
        let converter = ResponsesChatCompletionsTranslator.StreamConverter(
            model: "deepseek-chat",
            responseID: "resp_tool",
            reasoningEffort: nil
        )
        _ = converter.startEvents()

        _ = converter.consume(chunk: [
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0,
                    "id": "call_42",
                    "function": ["name": "run", "arguments": ""],
                ]]],
            ]],
        ])
        _ = converter.consume(chunk: [
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0,
                    "function": ["arguments": "{\"cmd\":\"ls\"}"],
                ]]],
            ]],
        ])
        let finishChunk: [String: Any] = [
            "choices": [["delta": [:], "finish_reason": "tool_calls"]],
        ]
        let events = converter.consume(chunk: finishChunk)
        let types = events.map { $0["type"] as? String }
        XCTAssertTrue(types.contains("response.function_call_arguments.done"))
        XCTAssertTrue(types.contains("response.output_item.done"))

        let done = try XCTUnwrap(events.first { $0["type"] as? String == "response.function_call_arguments.done" })
        XCTAssertEqual(done["arguments"] as? String, "{\"cmd\":\"ls\"}")
    }

    // MARK: - Non-streaming envelope

    func testNonStreamingEnvelopeWrapsChatCompletion() throws {
        let chatResponse: [String: Any] = [
            "choices": [["message": ["content": "answer", "role": "assistant"]]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
        ]
        let envelope = ResponsesChatCompletionsTranslator.responsesEnvelope(
            fromChatCompletion: chatResponse,
            model: "deepseek-chat",
            responseID: "resp_env",
            reasoningEffort: nil
        )
        XCTAssertEqual(envelope["status"] as? String, "completed")
        let output = try XCTUnwrap(envelope["output"] as? [[String: Any]])
        let message = try XCTUnwrap(output.first)
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "answer")
        let usage = try XCTUnwrap(envelope["usage"] as? [String: Any])
        XCTAssertEqual(usage["total_tokens"] as? Int, 15)
    }
}
