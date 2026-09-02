import Foundation

enum ISO8601Parsing {
    nonisolated static func parse(_ value: String) -> Date? {
        if let date = self.fastUTCDate(from: value) {
            return date
        }
        if let date = self.fractional.date(from: value) {
            return date
        }
        return self.basic.date(from: value)
    }

    /// Codex JSONL timestamps overwhelmingly use the canonical
    /// `YYYY-MM-DDTHH:mm:ss[.fraction]Z` shape. `ISO8601DateFormatter` is
    /// comparatively expensive in a multi-gigabyte scan, so parse that hot path
    /// directly and retain Foundation as the compatibility fallback for offsets.
    nonisolated private static func fastUTCDate(from value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes[10] == 0x54,
              bytes[13] == 0x3A,
              bytes[16] == 0x3A,
              bytes.last == 0x5A else {
            return nil
        }

        func number(_ start: Int, _ length: Int) -> Int? {
            guard start >= 0, start + length <= bytes.count else { return nil }
            var result = 0
            for byte in bytes[start..<(start + length)] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                result = result * 10 + Int(byte - 0x30)
            }
            return result
        }

        guard let year = number(0, 4),
              let month = number(5, 2),
              let day = number(8, 2),
              let hour = number(11, 2),
              let minute = number(14, 2),
              let second = number(17, 2),
              (1...12).contains(month),
              day >= 1,
              day <= self.daysInMonth(month, year: year),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second) else {
            return nil
        }

        var fraction = 0.0
        if bytes.count > 20 {
            guard bytes.count >= 22, bytes[19] == 0x2E else { return nil }
            var divisor = 1.0
            for byte in bytes[20..<(bytes.count - 1)] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                divisor *= 10
                fraction += Double(byte - 0x30) / divisor
            }
        } else if bytes[19] != 0x5A {
            return nil
        }

        var utc = tm()
        utc.tm_year = Int32(year - 1900)
        utc.tm_mon = Int32(month - 1)
        utc.tm_mday = Int32(day)
        utc.tm_hour = Int32(hour)
        utc.tm_min = Int32(minute)
        utc.tm_sec = Int32(second)
        utc.tm_isdst = 0
        let seconds = timegm(&utc)
        guard seconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }

    nonisolated private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = year.isMultiple(of: 400) ||
                (year.isMultiple(of: 4) && year.isMultiple(of: 100) == false)
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
