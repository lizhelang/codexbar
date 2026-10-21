import Foundation

nonisolated enum CursorBillingCSVError: Error, Equatable {
    case empty
    case malformedCSV
    case invalidHeader
    case invalidRow(Int)
    case duplicateConflict(Int)
}

/// Parses the account billing export without retaining email, principal IDs or account metadata.
/// The contracted price is additional billing, not the API-equivalent value of included usage.
nonisolated struct CursorBillingCSVParser {
    private static let requiredHeaders = [
        "Billing Item ID", "Event Time", "Product", "Charge Category", "Usage Type",
        "Principal Type", "Principal ID", "Usage", "Pricing Currency", "Pricing Contracted",
        "Model", "User Email",
    ]

    func parse(_ text: String, now: Date = Date()) throws -> [ToolUsageRecord] {
        let rows = try Self.csvRows(text)
        guard let header = rows.first else { throw CursorBillingCSVError.empty }
        var columns: [String: Int] = [:]
        for (index, value) in header.enumerated() {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, columns.updateValue(index, forKey: name) == nil else {
                throw CursorBillingCSVError.invalidHeader
            }
        }
        guard Self.requiredHeaders.allSatisfy({ columns[$0.lowercased()] != nil }) else {
            throw CursorBillingCSVError.invalidHeader
        }
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardISO = ISO8601DateFormatter()
        standardISO.formatOptions = [.withInternetDateTime]
        var seen: [String: [String]] = [:]
        var records: [ToolUsageRecord] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            let rowNumber = offset + 2
            guard row.count == header.count else { throw CursorBillingCSVError.invalidRow(rowNumber) }
            func field(_ name: String) -> String {
                row[columns[name.lowercased()]!].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let identifier = field("Billing Item ID")
            let product = field("Product")
            let model = field("Model")
            guard ["cursor", "grok-bot", "grok-chat"].contains(product),
                  Self.isSafeMetadata(identifier), model.isEmpty || Self.isSafeMetadata(model),
                  let timestamp = Self.date(field("Event Time"), fractional: fractionalISO, standard: standardISO),
                  let usage = try? JSONDecoder().decode([String: TokenCounter].self, from: Data(field("Usage").utf8)),
                  usage.count <= 128 else {
                throw CursorBillingCSVError.invalidRow(rowNumber)
            }
            var input = 0
            var output = 0
            var cacheRead = 0
            var cacheWrite = 0
            var canonicalCounters: [String: Int] = [:]
            for (key, counter) in usage {
                let canonical = key.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).joined(separator: "-")
                if let previous = canonicalCounters[canonical] {
                    guard previous == counter.value else { throw CursorBillingCSVError.invalidRow(rowNumber) }
                    continue
                }
                canonicalCounters[canonical] = counter.value
                switch canonical {
                case "prompt-text-tokens": input = counter.value
                case "completion-text-tokens": output = counter.value
                case "cached-prompt-text-tokens": cacheRead = counter.value
                case "cache-write-text-tokens": cacheWrite = counter.value
                default:
                    // Unknown token buckets must not silently disappear from account totals.
                    if key.localizedCaseInsensitiveContains("token") {
                        throw CursorBillingCSVError.invalidRow(rowNumber)
                    }
                }
            }
            let total = try Self.sum([input, output, cacheRead, cacheWrite], row: rowNumber)
            let contracted = field("Pricing Contracted")
            let billedAmount: Double?
            if contracted.isEmpty {
                billedAmount = nil
            } else {
                guard contracted.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                      let amount = Double(contracted), amount.isFinite, amount >= 0 else {
                    throw CursorBillingCSVError.invalidRow(rowNumber)
                }
                billedAmount = amount
            }
            if let previous = seen[identifier] {
                guard previous == row else { throw CursorBillingCSVError.duplicateConflict(rowNumber) }
                continue
            }
            seen[identifier] = row
            guard timestamp <= now else { continue }
            records.append(ToolUsageRecord(
                id: "cursor-billing:\(product):\(identifier)", timestamp: timestamp,
                modelID: model.isEmpty ? nil : model,
                inputTokens: input, outputTokens: output,
                cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, totalTokens: total,
                costUSD: nil, costEvidence: nil,
                billedCostUSD: field("Pricing Currency").uppercased() == "USD" ? billedAmount : nil
            ))
        }
        return records
    }

    private struct TokenCounter: Decodable {
        let value: Int

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let count: Int
            if let text = try? container.decode(String.self) {
                guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(text) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid token count")
                }
                count = parsed
            } else {
                count = try container.decode(Int.self)
            }
            guard count >= 0 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid token count")
            }
            self.value = count
        }
    }

    private static func isSafeMetadata(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 512 && text.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func date(_ text: String, fractional: ISO8601DateFormatter, standard: ISO8601DateFormatter) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                         options: .regularExpression) != nil else { return nil }
        return fractional.date(from: text) ?? standard.date(from: text)
    }

    private static func sum(_ values: [Int], row: Int) throws -> Int {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw CursorBillingCSVError.invalidRow(row) }
            total = next
        }
        return total
    }

    private enum FieldState { case start, unquoted, quoted, closed }

    private static func csvRows(_ original: String) throws -> [[String]] {
        let text = original.first == "\u{FEFF}" ? String(original.dropFirst()) : original
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CursorBillingCSVError.empty
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var state = FieldState.start
        func endField() {
            row.append(field)
            field = ""
            state = .start
        }
        func endRow() {
            endField()
            if row.count != 1 || !row[0].isEmpty { rows.append(row) }
            row = []
        }
        for character in text {
            let newline = character == "\n" || character == "\r" || character == "\r\n"
            switch state {
            case .quoted:
                if character == "\"" { state = .closed }
                else { field.append(character) }
            case .closed:
                if character == "\"" { field.append(character); state = .quoted }
                else if character == "," { endField() }
                else if newline { endRow() }
                else { throw CursorBillingCSVError.malformedCSV }
            case .start, .unquoted:
                if character == "\"" {
                    guard state == .start else { throw CursorBillingCSVError.malformedCSV }
                    state = .quoted
                } else if character == "," { endField() }
                else if newline { endRow() }
                else { field.append(character); state = .unquoted }
            }
        }
        guard state != .quoted else { throw CursorBillingCSVError.malformedCSV }
        if !row.isEmpty || !field.isEmpty || state == .closed { endRow() }
        return rows
    }
}
