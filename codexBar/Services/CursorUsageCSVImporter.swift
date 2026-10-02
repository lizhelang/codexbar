import Foundation

enum CursorUsageCSVImportError: LocalizedError, Equatable {
    case empty
    case malformedCSV
    case missingDate
    case missingTokens
    case noUsageRows
    case invalidUsageRow(Int)

    var errorDescription: String? {
        switch self {
        case .empty: "Cursor CSV is empty."
        case .malformedCSV: "Cursor CSV contains an invalid quoted field."
        case .missingDate: "Cursor CSV is missing a Date column."
        case .missingTokens: "Cursor CSV is missing token columns."
        case .noUsageRows: "Cursor CSV has no dated token usage rows."
        case .invalidUsageRow(let row): "Cursor CSV row \(row) has an invalid date or token count."
        }
    }
}

/// Imports the per-request export from Cursor's Usage page. Import replaces the
/// previous Cursor snapshot, so overlapping exports cannot be counted twice.
struct CursorUsageCSVImporter {
    func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws -> ToolUsageSnapshot {
        let rows = try self.csvRows(text)
        guard let header = rows.first, header.isEmpty == false else {
            throw CursorUsageCSVImportError.empty
        }
        var columns: [String: Int] = [:]
        for (index, rawHeader) in header.enumerated() {
            let name = self.normalizedHeader(rawHeader)
            if columns[name] == nil { columns[name] = index }
        }
        guard let dateIndex = columns["date"] ?? columns["timestamp"] else {
            throw CursorUsageCSVImportError.missingDate
        }
        let modelIndex = columns["model"]
        let sessionIndex = columns["conversationid"] ?? columns["sessionid"]
        let totalIndex = columns["totaltokens"]
        let inputWithWriteIndex = columns["inputwcachewrite"]
        let inputWithoutWriteIndex = columns["inputwocachewrite"] ?? columns["inputwithoutcachewrite"]
        let inputIndex = columns["inputtokens"]
        let outputIndex = columns["outputtokens"]
        let cacheReadIndex = columns["cacheread"] ?? columns["cachereadtokens"]
        let costIndex = columns["cost"] ?? columns["chargedcost"]
        guard totalIndex != nil || inputIndex != nil || inputWithoutWriteIndex != nil || outputIndex != nil else {
            throw CursorUsageCSVImportError.missingTokens
        }

        struct Bucket {
            var input = 0
            var output = 0
            var cacheRead = 0
            var cacheWrite = 0
            var total = 0
            var knownCost = 0.0
            var hasUnknownCost = false
        }
        var byDay: [Date: Bucket] = [:]
        var latestUsageAt: Date?
        var usageRecords: [ToolUsageRecord] = []
        var validRows = 0
        var skippedZeroTokenRows = 0
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardISO = ISO8601DateFormatter()
        standardISO.formatOptions = [.withInternetDateTime]
        let dateFormats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "MMM d, yyyy h:mm a", "MMM d, yyyy, h:mm a"]
            .map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = format
                return formatter
            }
        for (offset, row) in rows.dropFirst().enumerated() {
            let rowNumber = offset + 2
            guard let rawDate = self.value(row, at: dateIndex),
                  let date = self.parseDate(rawDate, fractionalISO: fractionalISO, standardISO: standardISO, dateFormats: dateFormats) else {
                throw CursorUsageCSVImportError.invalidUsageRow(rowNumber)
            }
            guard date <= now else { continue }
            for index in [totalIndex, inputWithWriteIndex, inputWithoutWriteIndex, inputIndex, outputIndex, cacheReadIndex].compactMap({ $0 }) {
                if let rawValue = self.value(row, at: index),
                   rawValue.isEmpty == false,
                   self.integer(rawValue) == nil {
                    throw CursorUsageCSVImportError.invalidUsageRow(rowNumber)
                }
            }
            let total = self.integer(self.value(row, at: totalIndex))
            let inputWithWrite = self.integer(self.value(row, at: inputWithWriteIndex))
            let inputWithoutWrite = self.integer(self.value(row, at: inputWithoutWriteIndex))
            let input = inputWithoutWrite ?? self.integer(self.value(row, at: inputIndex)) ?? 0
            let output = self.integer(self.value(row, at: outputIndex)) ?? 0
            let cacheRead = self.integer(self.value(row, at: cacheReadIndex)) ?? 0
            // Cursor's two input columns are disjoint buckets: their sum,
            // cache reads and outputs make the reported total.
            let cacheWrite = inputWithWrite ?? 0
            guard let inferredTotal = self.safeSum([input, output, cacheRead, cacheWrite]),
                  [total, inputWithWrite, inputWithoutWrite, input, output, cacheRead].allSatisfy({ $0.map { $0 >= 0 } ?? true }) else {
                throw CursorUsageCSVImportError.invalidUsageRow(rowNumber)
            }
            let resolvedTotal = total ?? inferredTotal
            if resolvedTotal == 0 {
                skippedZeroTokenRows += 1
                continue
            }

            let day = calendar.startOfDay(for: date)
            var bucket = byDay[day] ?? Bucket()
            guard let nextInput = self.safeSum([bucket.input, input]),
                  let nextOutput = self.safeSum([bucket.output, output]),
                  let nextCacheRead = self.safeSum([bucket.cacheRead, cacheRead]),
                  let nextCacheWrite = self.safeSum([bucket.cacheWrite, cacheWrite]),
                  let nextTotal = self.safeSum([bucket.total, resolvedTotal]) else {
                throw CursorUsageCSVImportError.invalidUsageRow(rowNumber)
            }
            bucket.input = nextInput
            bucket.output = nextOutput
            bucket.cacheRead = nextCacheRead
            bucket.cacheWrite = nextCacheWrite
            bucket.total = nextTotal
            if let cost = self.money(self.value(row, at: costIndex)) {
                let sum = bucket.knownCost + cost
                guard sum.isFinite else { throw CursorUsageCSVImportError.invalidUsageRow(rowNumber) }
                bucket.knownCost = sum
            } else {
                bucket.hasUnknownCost = true
            }
            byDay[day] = bucket
            usageRecords.append(ToolUsageRecord(
                id: "cursor-csv:\(rowNumber)", timestamp: date,
                modelID: self.value(row, at: modelIndex), sessionID: self.value(row, at: sessionIndex),
                inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite, totalTokens: resolvedTotal,
                costUSD: self.money(self.value(row, at: costIndex)),
                billedCostUSD: self.money(self.value(row, at: columns["chargedcost"]))
            ))
            validRows += 1
            if latestUsageAt.map({ date > $0 }) ?? true { latestUsageAt = date }
        }
        guard validRows > 0 else { throw CursorUsageCSVImportError.noUsageRows }

        let dailyEntries = byDay.keys.sorted().compactMap { day -> ToolUsageDailyEntry? in
            guard let bucket = byDay[day] else { return nil }
            return ToolUsageDailyEntry(
                date: day,
                inputTokens: bucket.input,
                outputTokens: bucket.output,
                cacheReadTokens: bucket.cacheRead,
                cacheWriteTokens: bucket.cacheWrite,
                totalTokens: bucket.total,
                costUSD: bucket.hasUnknownCost ? nil : bucket.knownCost
            )
        }
        return ToolCostEstimator.reprice(ToolUsageSnapshot(
            client: .cursor,
            availability: .ready,
            evidence: .imported,
            dailyEntries: dailyEntries,
            usageRecords: usageRecords,
            latestUsageAt: latestUsageAt,
            refreshedAt: now,
            statusDetail: "Imported \(validRows) usage rows; skipped \(skippedZeroTokenRows) zero-token rows"
        ), calendar: calendar)
    }

    private func normalizedHeader(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func value(_ row: [String], at index: Int?) -> String? {
        guard let index, row.indices.contains(index) else { return nil }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func integer(_ text: String?) -> Int? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(cleaned)
    }

    private func money(_ text: String?) -> Double? {
        guard let text, text.isEmpty == false else { return nil }
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(cleaned).flatMap { $0.isFinite ? max(0, $0) : nil }
    }

    private func safeSum(_ values: [Int]) -> Int? {
        var sum = 0
        for value in values {
            let (next, overflow) = sum.addingReportingOverflow(value)
            if overflow { return nil }
            sum = next
        }
        return sum
    }

    private func parseDate(
        _ text: String,
        fractionalISO: ISO8601DateFormatter,
        standardISO: ISO8601DateFormatter,
        dateFormats: [DateFormatter]
    ) -> Date? {
        if let date = fractionalISO.date(from: text) { return date }
        if let date = standardISO.date(from: text) { return date }
        for formatter in dateFormats {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private func csvRows(_ text: String) throws -> [[String]] {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CursorUsageCSVImportError.empty
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted && next < text.endIndex && text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == "," && quoted == false {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r") && quoted == false {
                if character == "\r" {
                    let next = text.index(after: index)
                    if next < text.endIndex && text[next] == "\n" { index = next }
                }
                row.append(field)
                if row.contains(where: { $0.isEmpty == false }) { rows.append(row) }
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        guard quoted == false else { throw CursorUsageCSVImportError.malformedCSV }
        row.append(field)
        if row.contains(where: { $0.isEmpty == false }) { rows.append(row) }
        return rows
    }
}
