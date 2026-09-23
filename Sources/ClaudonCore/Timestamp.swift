import Foundation

enum Timestamp {
    /// Parses ISO 8601 timestamps such as "2026-09-23T05:27:27.146Z" or
    /// "2026-09-23T10:09:59.532362+00:00" into seconds since 1970.
    ///
    /// Transcripts hold tens of thousands of these, so the common shapes are parsed by hand.
    static func parse(_ text: String) -> Double? {
        let u = Array(text.utf8)
        guard u.count >= 19, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54 || u[10] == 0x20,
              u[13] == 0x3A, u[16] == 0x3A else { return fallback(text) }

        func digits(_ from: Int, _ to: Int) -> Int? {
            guard to <= u.count else { return nil }
            var value = 0
            for i in from..<to {
                guard u[i] >= 0x30, u[i] <= 0x39 else { return nil }
                value = value * 10 + Int(u[i] - 0x30)
            }
            return value
        }

        guard let year = digits(0, 4), let month = digits(5, 7), let day = digits(8, 10),
              let hour = digits(11, 13), let minute = digits(14, 16), let second = digits(17, 19),
              (1...12).contains(month), (1...31).contains(day) else { return fallback(text) }

        var i = 19
        var fraction = 0.0
        if i < u.count, u[i] == 0x2E {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 0x30, u[i] <= 0x39 {
                fraction += Double(u[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
        }

        var offset = 0
        if i < u.count {
            switch u[i] {
            case 0x5A: // Z
                i += 1
            case 0x2B, 0x2D: // + or -
                let sign = u[i] == 0x2B ? 1 : -1
                guard let hh = digits(i + 1, i + 3) else { return fallback(text) }
                var j = i + 3
                if j < u.count, u[j] == 0x3A { j += 1 }
                guard let mm = digits(j, j + 2) else { return fallback(text) }
                offset = sign * (hh * 3600 + mm * 60)
                i = j + 2
            default:
                return fallback(text)
            }
        }
        guard i == u.count else { return fallback(text) }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Double(seconds) + fraction
    }

    static func date(_ text: String) -> Date? {
        parse(text).map { Date(timeIntervalSince1970: $0) }
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func fallback(_ text: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)?.timeIntervalSince1970
    }
}
