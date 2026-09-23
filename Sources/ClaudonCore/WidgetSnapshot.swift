import Foundation

/// What the widget shows, prepared by the app. The widget runs sandboxed and can't read the
/// transcripts or the keychain, so the app writes this file and the widget only reads it.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Totals: Codable, Sendable, Equatable {
        public var tokens: Int64
        public var minutes: Int
        public var cost: Double

        public init(tokens: Int64, minutes: Int, cost: Double) {
            self.tokens = tokens
            self.minutes = minutes
            self.cost = cost
        }
    }

    public struct MonthLabel: Codable, Sendable, Equatable {
        /// Calendar column (week) where the month starts.
        public var column: Int
        public var text: String

        public init(column: Int, text: String) {
            self.column = column
            self.text = text
        }
    }

    public var generatedAt: Date
    public var limits: LimitsSnapshot?
    /// The latest limits check failed, so `limits` holds older values.
    public var limitsStale: Bool
    public var metric: Metric
    public var today: Totals
    public var week: Totals
    /// Heatmap level (0 to 4) per day, oldest first, in columns of 7 starting on the
    /// calendar's first weekday. The last entry is today.
    public var dayLevels: [Int]
    public var monthLabels: [MonthLabel]
    /// Heatmap level per weekday and hour, 7 rows of 24, rows in `hourRowNames` order.
    public var hourLevels: [Int]
    public var hourRowNames: [String]

    public init(generatedAt: Date, limits: LimitsSnapshot?, limitsStale: Bool, metric: Metric, today: Totals,
                week: Totals, dayLevels: [Int], monthLabels: [MonthLabel], hourLevels: [Int],
                hourRowNames: [String]) {
        self.generatedAt = generatedAt
        self.limits = limits
        self.limitsStale = limitsStale
        self.metric = metric
        self.today = today
        self.week = week
        self.dayLevels = dayLevels
        self.monthLabels = monthLabels
        self.hourLevels = hourLevels
        self.hourRowNames = hourRowNames
    }

    /// `~/Library/Application Support/Claudon/widget.json`, under the real home folder even
    /// inside the widget's sandbox, where `NSHomeDirectory()` points into its container.
    public static var fileURL: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Claudon", isDirectory: true)
            .appendingPathComponent("widget.json")
    }

    public static func load(from url: URL = fileURL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// The limits worth an immediate widget reload when they change: whole percents, reset
    /// times and whether they're current. Token totals can wait for the next scheduled reload.
    public var limitsSignature: String {
        let windows = (limits?.windows ?? []).map {
            "\($0.id)=\(Int($0.percent)):\(Int($0.resetsAt?.timeIntervalSince1970 ?? 0) / 60)"
        }
        return (windows + ["stale=\(limitsStale)"]).joined(separator: ",")
    }
}

extension Metric: Codable {}
