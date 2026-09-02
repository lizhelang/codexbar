import XCTest

final class LocalCostIncrementalScannerTests: XCTestCase {
    func testInitialScanCreatesSQLiteAggregates() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )

        try self.writeSession(
            home: home,
            fileName: "initial.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"initial","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            ]
        )

        let result = try scanner.scan()
        let summary = try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary

        XCTAssertEqual(result.parsedFiles, 1)
        XCTAssertEqual(summary.todayTokens, 120)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.00101, accuracy: 1e-12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codexbar/cost-usage.sqlite").path))
    }

    func testUnchangedFilesAreSkippedOnSecondScan() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        try self.writeSession(
            home: home,
            fileName: "unchanged.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"unchanged","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            ]
        )

        _ = try scanner.scan()
        let second = try scanner.scan()

        XCTAssertEqual(second.parsedFiles, 0)
        XCTAssertEqual(second.bytesRead, 0)
    }

    func testAppendOnlyScanReadsOnlyNewTailAndKeepsPreviousEvents() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let fileURL = try self.writeSession(
            home: home,
            fileName: "append.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"append","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            ]
        )
        _ = try scanner.scan()
        let originalSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        let appended = #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let second = try scanner.scan()
        let summary = try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary

        XCTAssertEqual(second.parsedFiles, 1)
        XCTAssertLessThan(second.bytesRead, Int64(originalSize))
        XCTAssertEqual(summary.todayTokens, 200)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.001615, accuracy: 1e-12)
    }

    func testPartialLineDoesNotAdvanceCursorUntilCompleted() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let fileURL = try self.writeSession(
            home: home,
            fileName: "partial.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"partial","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            ]
        )
        let partial = #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(partial.utf8))
        try handle.close()

        let firstScan = try scanner.scan()
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 0)
        XCTAssertEqual(firstScan.progress.state, .idle)
        XCTAssertEqual(try store.indexedFile(path: fileURL.standardizedFileURL.path)?.isComplete, true)

        let newlineHandle = try FileHandle(forWritingTo: fileURL)
        try newlineHandle.seekToEnd()
        try newlineHandle.write(contentsOf: Data("\n".utf8))
        try newlineHandle.close()

        _ = try scanner.scan()
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 120)
    }

    func testLargeIrrelevantResponseItemDoesNotPreventLinearScan() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let padding = String(repeating: "x", count: 16 * 1024 * 1024)
        try self.writeSession(
            home: home,
            fileName: "large-response-item.jsonl",
            lines: [
                #"{"type":"response_item","payload":{"content":"\#(padding)"}}"#,
                #"{"payload":{"type":"session_meta","id":"large-response-item","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            ]
        )

        let startedAt = Date()
        _ = try scanner.scan()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 120)
        XCTAssertLessThan(elapsed, 2)
    }

    func testBudgetStopsWithinFileAtCommittedLineBoundaryAndResumes() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        var lines = [
            #"{"payload":{"type":"session_meta","id":"budget","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
        ]
        for index in 0..<50 {
            let input = 100 + index
            lines.append(
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":20},"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0}}}}"#
            )
        }
        let fileURL = try self.writeSession(home: home, fileName: "budget.jsonl", lines: lines)
        let fileSize = Int64(try XCTUnwrap(fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize))

        let first = try scanner.scan(budget: LocalCostScanBudget(maxBytes: 1, maxDuration: nil))
        let indexedAfterFirst = try XCTUnwrap(store.indexedFile(path: fileURL.standardizedFileURL.path))
        XCTAssertEqual(first.progress.state, .partial)
        XCTAssertGreaterThan(indexedAfterFirst.parsedBytes, 0)
        XCTAssertLessThan(indexedAfterFirst.parsedBytes, fileSize)

        let second = try scanner.scan()
        XCTAssertEqual(second.progress.state, .idle)
        XCTAssertEqual(try store.indexedFile(path: fileURL.standardizedFileURL.path)?.parsedBytes, fileSize)
    }

    func testTruncatedFileReplacesOldEvents() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let fileURL = try self.writeSession(
            home: home,
            fileName: "truncate.jsonl",
            lines: self.sessionLines(
                id: "truncate",
                totalInput: 300,
                cachedInput: 20,
                output: 40,
                lastInput: 300,
                lastCachedInput: 20,
                lastOutput: 40
            )
        )
        _ = try scanner.scan()
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 340)

        try self.overwrite(fileURL, with: self.sessionLines(
            id: "truncate",
            totalInput: 50,
            cachedInput: 0,
            output: 10,
            lastInput: 50,
            lastCachedInput: 0,
            lastOutput: 10
        ))

        _ = try scanner.scan()
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 60)
    }

    func testSameSizeReplacementAnchorMismatchRebuildsFile() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let originalLines = self.sessionLines(
            id: "same-size",
            totalInput: 100,
            cachedInput: 0,
            output: 20,
            lastInput: 100,
            lastCachedInput: 0,
            lastOutput: 20
        )
        let fileURL = try self.writeSession(home: home, fileName: "same-size.jsonl", lines: originalLines)
        _ = try scanner.scan()
        let originalData = try Data(contentsOf: fileURL)

        let replacementLines = self.sessionLines(
            id: "same-size",
            totalInput: 240,
            cachedInput: 0,
            output: 60,
            lastInput: 240,
            lastCachedInput: 0,
            lastOutput: 60
        )
        var replacement = Data((replacementLines.joined(separator: "\n") + "\n").utf8)
        if replacement.count < originalData.count {
            replacement.append(Data(repeating: UInt8(ascii: " "), count: originalData.count - replacement.count))
        } else if replacement.count > originalData.count {
            replacement = replacement.prefix(originalData.count)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.close()

        _ = try scanner.scan()
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 300)
    }

    func testArchivedDuplicateEventKeyIsNotDoubleCounted() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let active = try self.writeSession(
            home: home,
            fileName: "duplicate.jsonl",
            lines: self.sessionLines(
                id: "duplicate",
                totalInput: 100,
                cachedInput: 0,
                output: 20,
                lastInput: 100,
                lastCachedInput: 0,
                lastOutput: 20
            )
        )
        let archived = home.appendingPathComponent(".codex/archived_sessions/duplicate.jsonl")
        try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: active, to: archived)

        _ = try scanner.scan()

        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 120)
    }

    func testSubagentReplayCountsOnlyExecutionAfterMarker() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        try self.writeSession(
            home: home,
            fileName: "subagent.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"subagent","timestamp":"2026-04-05T08:00:00Z","source":"subagent"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20}}}}"#,
                #"{"payload":{"type":"session_meta","id":"subagent","timestamp":"2026-04-05T08:00:00Z","source":"subagent"}}"#,
                #"{"type":"inter_agent_communication_metadata","payload":{"kind":"start"}}"#,
                #"{"timestamp":"2026-04-05T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":130,"cached_input_tokens":0,"output_tokens":30}}}}"#,
            ]
        )

        _ = try scanner.scan()

        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 40)
    }

    func testLaterReplayMarkerReplacesPreviouslyAmbiguousSubagentEvents() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let fileURL = try self.writeSession(
            home: home,
            fileName: "late-subagent-replay.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"late-subagent","timestamp":"2026-04-05T08:00:00Z","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"timestamp":"2026-04-05T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20}}}}"#,
            ]
        )

        _ = try scanner.scan()
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 120)

        let appended = [
            #"{"payload":{"type":"session_meta","id":"late-subagent","timestamp":"2026-04-05T08:00:00Z","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
            #"{"type":"inter_agent_communication_metadata","payload":{"kind":"start"}}"#,
            #"{"timestamp":"2026-04-05T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":130,"cached_input_tokens":0,"output_tokens":30}}}}"#,
        ].joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        _ = try scanner.scan()

        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 40)
    }

    func testOrdinaryForkWithoutInitialIncrementDoesNotRecountParentBaseline() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        try self.writeSession(
            home: home,
            fileName: "fork.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"fork","timestamp":"2026-04-05T08:00:00Z","forked_from_id":"parent"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":200}}}}"#,
                #"{"timestamp":"2026-04-05T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1030,"cached_input_tokens":100,"output_tokens":210}}}}"#,
            ]
        )

        let first = try scanner.scan()
        let second = try scanner.scan()

        XCTAssertEqual(first.progress.state, .idle)
        XCTAssertEqual(second.parsedFiles, 0)
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 40)
    }

    func testInvalidUsageLineDoesNotFreezeCompletedFile() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let fileURL = try self.writeSession(
            home: home,
            fileName: "warning.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"warning","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":"#,
                #"{"timestamp":"2026-04-05T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20}}}}"#,
            ]
        )

        let first = try scanner.scan()
        let second = try scanner.scan()

        XCTAssertEqual(first.progress.state, .idle)
        XCTAssertEqual(second.parsedFiles, 0)
        XCTAssertEqual(try store.indexedFile(path: fileURL.standardizedFileURL.path)?.isComplete, true)
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 120)
    }

    func testSQLiteReopenResumesPartialScan() throws {
        let home = try self.makeHome()
        let databaseURL = home.appendingPathComponent(".codexbar/cost-usage.sqlite")
        let firstStore = try LocalCostIndexStore(databaseURL: databaseURL)
        let firstScanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: firstStore
        )
        var lines = [
            #"{"payload":{"type":"session_meta","id":"reopen","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
        ]
        for index in 0..<50 {
            lines.append(
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(100 + index),"cached_input_tokens":0,"output_tokens":20},"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0}}}}"#
            )
        }
        let fileURL = try self.writeSession(home: home, fileName: "reopen.jsonl", lines: lines)
        let fileSize = Int64(try XCTUnwrap(fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        _ = try firstScanner.scan(budget: LocalCostScanBudget(maxBytes: 1, maxDuration: nil))

        let reopenedStore = try LocalCostIndexStore(databaseURL: databaseURL)
        let reopenedScanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: reopenedStore
        )
        _ = try reopenedScanner.scan()

        XCTAssertEqual(try reopenedStore.indexedFile(path: fileURL.standardizedFileURL.path)?.parsedBytes, fileSize)
        XCTAssertEqual(try reopenedStore.progress().state, .idle)
    }

    func testPricingOverrideRecomputesSummaryWithoutReadingFiles() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        try self.writeSession(
            home: home,
            fileName: "pricing.jsonl",
            lines: self.sessionLines(
                id: "pricing",
                totalInput: 100,
                cachedInput: 20,
                output: 20,
                lastInput: 100,
                lastCachedInput: 20,
                lastOutput: 20
            )
        )
        _ = try scanner.scan()
        let defaultCost = try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeCostUSD
        let overriddenCost = try store.summary(
            now: self.date("2026-04-05T12:00:00Z"),
            modelPricingOverrides: [
                "gpt-5.5": CodexBarModelPricing(
                    inputUSDPerToken: 10,
                    cachedInputUSDPerToken: 1,
                    outputUSDPerToken: 20
                ),
            ]
        ).summary.lifetimeCostUSD
        let second = try scanner.scan()

        XCTAssertGreaterThan(overriddenCost, defaultCost)
        XCTAssertEqual(second.bytesRead, 0)
        XCTAssertEqual(second.parsedFiles, 0)
    }

    func testBudgetCanCheckpointInsideLargeIrrelevantLine() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        let padding = String(repeating: "x", count: 2 * 1024 * 1024)
        let fileURL = try self.writeSession(
            home: home,
            fileName: "large-response-item-budget.jsonl",
            lines: [
                #"{"type":"response_item","payload":{"content":"\#(padding)"}}"#,
                #"{"payload":{"type":"session_meta","id":"large-response-item-budget","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            ]
        )
        let fileSize = Int64(try XCTUnwrap(fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize))

        let first = try scanner.scan(budget: LocalCostScanBudget(maxBytes: 64 * 1024, maxDuration: nil))
        let indexedAfterFirst = try XCTUnwrap(store.indexedFile(path: fileURL.standardizedFileURL.path))
        let second = try scanner.scan()

        XCTAssertEqual(first.progress.state, .partial)
        XCTAssertGreaterThan(indexedAfterFirst.parsedBytes, 4096)
        XCTAssertLessThan(indexedAfterFirst.parsedBytes, fileSize)
        XCTAssertEqual(second.progress.state, .idle)
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 120)
    }

    func testLegitimateSameTimestampAndDeltaEventsRemainDistinct() throws {
        let home = try self.makeHome()
        let store = try self.makeStore(home: home)
        let scanner = LocalCostIncrementalScanner(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            store: store
        )
        try self.writeSession(
            home: home,
            fileName: "same-timestamp.jsonl",
            lines: [
                #"{"payload":{"type":"session_meta","id":"same-timestamp","timestamp":"2026-04-05T08:00:00Z"}}"#,
                #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-04-05T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20}}}}"#,
                #"{"timestamp":"2026-04-05T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":40},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20}}}}"#,
            ]
        )

        _ = try scanner.scan()

        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 240)
    }

    private func makeHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cost-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".codex/sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".codexbar", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeStore(home: URL) throws -> LocalCostIndexStore {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return try LocalCostIndexStore(
            databaseURL: home.appendingPathComponent(".codexbar/cost-usage.sqlite"),
            calendar: calendar
        )
    }

    @discardableResult
    private func writeSession(home: URL, fileName: String, lines: [String]) throws -> URL {
        let fileURL = home.appendingPathComponent(".codex/sessions/\(fileName)")
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func overwrite(_ fileURL: URL, with lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    private func sessionLines(
        id: String,
        totalInput: Int,
        cachedInput: Int,
        output: Int,
        lastInput: Int,
        lastCachedInput: Int,
        lastOutput: Int
    ) -> [String] {
        [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":\#(cachedInput),"output_tokens":\#(output)},"last_token_usage":{"input_tokens":\#(lastInput),"cached_input_tokens":\#(lastCachedInput),"output_tokens":\#(lastOutput)}}}}"#,
        ]
    }

    private func date(_ value: String) -> Date {
        ISO8601Parsing.parse(value) ?? Date(timeIntervalSince1970: 0)
    }
}
