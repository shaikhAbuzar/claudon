import Foundation

public enum Formatters {
    /// 950, 12K, 4.1M, 3.7B.
    public static func tokens(_ value: Int64) -> String {
        compact(Double(value))
    }

    static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        // The 0.9995 keeps 999,960 from printing as "1000K".
        for (size, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where magnitude >= size * 0.9995 {
            return number(value / size) + suffix
        }
        return number(value, fractionDigits: 0)
    }

    /// One decimal below 10, none above: 4.1, 12, 123.
    static func number(_ value: Double, fractionDigits: Int? = nil) -> String {
        let digits = fractionDigits ?? (abs(value) < 9.95 ? 1 : 0)
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    /// 45m, 2h 35m, 126h.
    public static func duration(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(max(0, minutes))m" }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 100 || rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }

    /// Time until a reset: <1m, 39m, 4h 39m, 2d 4h. Rounds up, so it never shows 0m early.
    public static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, restMinutes = minutes % 60
        if hours < 24 { return restMinutes == 0 ? "\(hours)h" : "\(hours)h \(restMinutes)m" }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
    }

    public static func percent(_ value: Double) -> String {
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// $0.42, $38.20, $210, $1,234. `compact` shortens five figures and up to $12K.
    /// `exact` always shows cents.
    public static func money(_ amount: Double, currency: String = "USD", compact: Bool = false,
                             exact: Bool = false) -> String {
        if compact, abs(amount) >= 10_000 {
            return currencySymbol(currency) + Formatters.compact(amount)
        }
        let digits = exact || abs(amount) < 100 ? 2 : 0
        return amount.formatted(.currency(code: currency).precision(.fractionLength(digits)))
    }

    static func currencySymbol(_ code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.currencySymbol ?? code
    }

    /// Clock time in the user's 12 or 24 hour style.
    public static func clock(_ date: Date) -> String {
        formatter("jmm").string(from: date)
    }

    /// "15:39" today, "Thu 12:29" this week, "2 Oct 12:29" after that.
    public static func resetClock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date) }
        if date.timeIntervalSince(now) < 6 * 86_400 { return formatter("EEEjmm").string(from: date) }
        return formatter("dMMMjmm").string(from: date)
    }

    /// "Tue 23 Sep" in the user's locale.
    public static func dayLabel(_ date: Date) -> String {
        formatter("EEEdMMM").string(from: date)
    }

    /// "14:00" or "2 PM" for an hour of the day.
    public static func hourLabel(_ hour: Int, calendar: Calendar = .current) -> String {
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = 0
        let date = calendar.date(from: parts) ?? Date()
        return formatter(uses24HourClock ? "HHmm" : "j").string(from: date)
    }

    public static var uses24HourClock: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    private static let formatterLock = NSLock()
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ template: String) -> DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = formatters[template] { return cached }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[template] = formatter
        return formatter
    }
}
