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

        let request = try ResponsesChatCompletionsTranslator.chatRequestBody(
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

        let request = try ResponsesChatCompletionsTranslator.chatRequestBody(
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
        let request = try ResponsesChatCompletionsTranslator.chatRequestBody(
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
        let request = try ResponsesChatCompletionsTranslator.chatRequestBody(
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

        let request = try ResponsesChatCompletionsTranslator.chatRequestBody(
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

        let request = try ResponsesChatCompletionsTranslator.chatRequestBody(
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
        let reasoningEvents = try converter.consume(chunk: reasoningChunk)
        XCTAssertEqual(reasoningEvents.first?["type"] as? String, "response.reasoning_text.delta")
        XCTAssertEqual(reasoningEvents.first?["item_id"] as? String, reasoningEvents.first?["item_id"] as? String)

        let emptyReasoning: [String: Any] = [
            "choices": [["delta": ["reasoning_content": ""]]],
        ]
        XCTAssertTrue(try converter.consume(chunk: emptyReasoning).isEmpty, "empty reasoning must be filtered")
    }

    func testStreamConverterAccumulatesTextAndCompletes() throws {
        let converter = ResponsesChatCompletionsTranslator.StreamConverter(
            model: "deepseek-chat",
            responseID: "resp_text",
            reasoningEffort: nil
        )
        _ = converter.startEvents()

        let e1 = try converter.consume(chunk: ["choices": [["delta": ["content": "Hello "]]]])
        XCTAssertEqual(e1.first?["type"] as? String, "response.output_text.delta")
        XCTAssertEqual(e1.first?["delta"] as? String, "Hello ")
        _ = try converter.consume(chunk: ["choices": [["delta": ["content": "world"], "finish_reason": "stop"]]])

        let finish = try converter.finishEvents()
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

        let events = try converter.consume(chunk: [
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

        _ = try converter.consume(chunk: [
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0,
                    "id": "call_42",
                    "function": ["name": "run", "arguments": ""],
                ]]],
            ]],
        ])
        _ = try converter.consume(chunk: [
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
        XCTAssertTrue(try converter.consume(chunk: finishChunk).isEmpty)
        let events = try converter.finishEvents()
        let types = events.map { $0["type"] as? String }
        XCTAssertTrue(types.contains("response.function_call_arguments.done"))
        XCTAssertTrue(types.contains("response.output_item.done"))

        let done = try XCTUnwrap(events.first { $0["type"] as? String == "response.function_call_arguments.done" })
        XCTAssertEqual(done["arguments"] as? String, "{\"cmd\":\"ls\"}")
    }

    func testCustomToolsPreserveDefinitionChoiceAndHistory() throws {
        let input = "print(\"你好\")\n"
        let body: [String: Any] = [
            "tools": [["type": "custom", "name": "exec", "description": "Run code",
                       "format": ["type": "grammar", "syntax": "lark", "definition": "start: /.+/"]]],
            "tool_choice": ["type": "custom", "name": "exec"],
            "input": [
                ["type": "custom_tool_call", "call_id": "c1", "name": "exec", "input": input],
                ["type": "custom_tool_call_output", "call_id": "c1", "output": "你好"],
            ],
        ]
        let request = try ResponsesChatCompletionsTranslator.chatRequestBody(fromResponses: body, model: "m", quirks: .standard)
        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertTrue((function["description"] as? String)?.contains("start: /.+/") == true)
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["input"])
        let choice = try XCTUnwrap(request["tool_choice"] as? [String: Any])
        XCTAssertEqual((choice["function"] as? [String: Any])?["name"] as? String, "exec")
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(messages.first?["tool_calls"] as? [[String: Any]])
        let arguments = try XCTUnwrap((calls.first?["function"] as? [String: Any])?["arguments"] as? String)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["input"] as? String, input)
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "c1")
        XCTAssertEqual(messages.last?["content"] as? String, "你好")
    }

    func testUnsupportedToolsAndChoicesFailInsteadOfBeingDropped() throws {
        for tool: [String: Any] in [
            ["type": "web_search"],
            ["type": "namespace", "name": "multi_agent_v1", "tools": [["type": "function", "name": "spawn_agent"]]],
            ["type": "custom", "name": "exec", "format": ["type": "unknown"]],
            ["type": "custom", "name": "exec", "format": "invalid"],
        ] {
            XCTAssertThrowsError(try ResponsesChatCompletionsTranslator.chatRequestBody(
                fromResponses: ["tools": [tool]], model: "m", quirks: .standard
            ))
        }
        XCTAssertThrowsError(try ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: ["tools": [["type": "function", "name": "exec"]], "tool_choice": ["type": "unknown"]],
            model: "m", quirks: .standard
        ))
        let request = try ResponsesChatCompletionsTranslator.chatRequestBody(
            fromResponses: ["tools": [["type": "function", "name": "exec"]], "tool_choice": "none"],
            model: "m", quirks: CodexBarChatQuirks(toolChoiceDowngradeToAuto: true)
        )
        XCTAssertEqual(request["tool_choice"] as? String, "none")
    }

    func testCustomToolStreamBuffersEscapedInputAndKeepsParallelFunctionCall() throws {
        let converter = ResponsesChatCompletionsTranslator.StreamConverter(
            model: "m", responseID: "r", reasoningEffort: nil, customToolNames: ["exec"]
        )
        _ = converter.startEvents()
        let input = "print(\"你好\")\n"
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["input": input]), as: UTF8.self)
        let split = arguments.index(arguments.startIndex, offsetBy: 12)
        let first = try converter.consume(chunk: ["choices": [["delta": ["tool_calls": [
            ["index": 0, "id": "custom_1", "function": ["name": "exec", "arguments": String(arguments[..<split])]],
            ["index": 1, "id": "func_1", "function": ["name": "ls", "arguments": "{}"]],
        ]]]]])
        XCTAssertTrue(first.isEmpty, "Do not expose partial escaped JSON as executable input")
        _ = try converter.consume(chunk: ["choices": [["delta": ["tool_calls": [
            ["index": 0, "function": ["arguments": String(arguments[split...])]],
        ]]]]])
        XCTAssertTrue(try converter.consume(chunk: ["choices": [["delta": [:], "finish_reason": "tool_calls"]]]).isEmpty)
        let events = try converter.finishEvents()
        let done = try XCTUnwrap(events.first { $0["type"] as? String == "response.custom_tool_call_input.done" })
        XCTAssertEqual(done["input"] as? String, input)
        XCTAssertEqual(done["item_id"] as? String, "custom_1")
        XCTAssertTrue(events.contains { $0["type"] as? String == "response.function_call_arguments.done" })
        let response = try XCTUnwrap(events.last?["response"] as? [String: Any])
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        XCTAssertEqual(output.filter { $0["type"] as? String == "custom_tool_call" }.first?["input"] as? String, input)
        XCTAssertEqual(output.filter { $0["type"] as? String == "function_call" }.first?["name"] as? String, "ls")
    }

    func testMalformedCustomArgumentsFailInBothResponseModes() throws {
        for arguments in ["sw_vers", #"{"input":12}"#, #"{"input":"sw_vers","extra":true}"#] {
            let call: [String: Any] = ["id": "c1", "index": 0, "function": ["name": "exec", "arguments": arguments]]
            XCTAssertThrowsError(try ResponsesChatCompletionsTranslator.responsesEnvelope(
                fromChatCompletion: ["choices": [["message": ["tool_calls": [call]], "finish_reason": "tool_calls"]]],
                model: "m", responseID: "r", reasoningEffort: nil, customToolNames: ["exec"]
            ))
            let converter = ResponsesChatCompletionsTranslator.StreamConverter(
                model: "m", responseID: "r", reasoningEffort: nil, customToolNames: ["exec"]
            )
            _ = try converter.consume(chunk: ["choices": [["delta": ["tool_calls": [call]], "finish_reason": "tool_calls"]]])
            XCTAssertThrowsError(try converter.finishEvents())
        }
    }

    func testNonStreamingCustomCallRoundTripAndProseStaysText() throws {
        let prose = "<tool_call>sw_vers</tool_call>"
        let envelope = try ResponsesChatCompletionsTranslator.responsesEnvelope(
            fromChatCompletion: ["choices": [["message": [
                "content": prose,
                "tool_calls": [["id": "c1", "function": ["name": "exec", "arguments": #"{"input":"sw_vers"}"#]]],
            ], "finish_reason": "tool_calls"]]], model: "m", responseID: "r", reasoningEffort: nil, customToolNames: ["exec"]
        )
        let output = try XCTUnwrap(envelope["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output.last?["type"] as? String, "custom_tool_call")
        XCTAssertEqual(output.last?["input"] as? String, "sw_vers")
        XCTAssertEqual(output.last?["call_id"] as? String, "c1")
        XCTAssertNil(output.last?["arguments"])
        XCTAssertEqual((output.first?["content"] as? [[String: Any]])?.first?["text"] as? String, prose)
    }

    func testStreamDoesNotReleaseToolsWhenFinishIsMissingTruncatedOrFiltered() throws {
        for finishReason: String? in [nil, "length", "content_filter", "unknown", "stop"] {
            let converter = ResponsesChatCompletionsTranslator.StreamConverter(
                model: "m", responseID: "r", reasoningEffort: nil, customToolNames: ["exec"]
            )
            let events = try converter.consume(chunk: ["choices": [["delta": ["tool_calls": [[
                "index": 0, "id": "c1", "function": ["name": "exec", "arguments": #"{"input":"sw_vers"}"#],
            ]]]]]])
            XCTAssertTrue(events.isEmpty)
            if let finishReason {
                XCTAssertThrowsError(try converter.consume(chunk: ["choices": [["delta": [:], "finish_reason": finishReason]]]))
            }
            XCTAssertThrowsError(try converter.finishEvents())
        }
    }

    func testStreamRejectsErrorAndMalformedFramesEvenAfterNormalFinish() throws {
        let invalidFrames: [[String: Any]] = [
            ["error": ["message": "upstream failed"]], [:], ["choices": "invalid"],
            ["choices": []], ["choices": [["delta": "invalid"]]],
        ]
        for frame in invalidFrames {
            let converter = ResponsesChatCompletionsTranslator.StreamConverter(model: "m", responseID: "r", reasoningEffort: nil)
            XCTAssertTrue(try converter.consume(chunk: ["choices": [[
                "delta": ["tool_calls": [["index": 0, "id": "c1", "function": ["name": "run", "arguments": "{}"]]]],
                "finish_reason": "tool_calls",
            ]]]).isEmpty)
            XCTAssertThrowsError(try converter.consume(chunk: frame))
            XCTAssertThrowsError(try converter.finishEvents())
        }
    }

    func testNonStreamingRejectsErrorMissingFinishAndIncompleteGeneration() throws {
        var responses: [[String: Any]] = [["error": ["message": "upstream failed"]], [:]]
        for finishReason: String? in [nil, "length", "content_filter", "unknown", "stop"] {
            var choice: [String: Any] = ["message": ["tool_calls": [[
                "id": "c1", "function": ["name": "run", "arguments": "{}"],
            ]]]]
            if let finishReason { choice["finish_reason"] = finishReason }
            responses.append(["choices": [choice]])
        }
        for response in responses {
            XCTAssertThrowsError(try ResponsesChatCompletionsTranslator.responsesEnvelope(
                fromChatCompletion: response, model: "m", responseID: "r", reasoningEffort: nil
            ))
        }
    }

    // MARK: - Non-streaming envelope

    func testNonStreamingEnvelopeWrapsChatCompletion() throws {
        let chatResponse: [String: Any] = [
            "choices": [["message": ["content": "answer", "role": "assistant"], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
        ]
        let envelope = try ResponsesChatCompletionsTranslator.responsesEnvelope(
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
