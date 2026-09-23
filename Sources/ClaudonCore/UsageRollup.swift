import Foundation

/// The minutes of one UTC day in which Claude was active.
public struct MinuteSet: Hashable, Sendable {
    /// 23 words of 64 bits cover the 1,440 minutes of a day.
    public static let wordCount = 23

    public private(set) var words: [UInt64]

    public init() {
        words = Array(repeating: 0, count: Self.wordCount)
    }

    public init(words: [UInt64]) {
        var padded = Array(words.prefix(Self.wordCount))
        padded += Array(repeating: 0, count: Self.wordCount - padded.count)
        self.words = padded
    }

    /// Marks `minute` (0..<1440). Returns true if it was not marked before.
    @discardableResult
    public mutating func insert(_ minute: Int) -> Bool {
        let bit = UInt64(1) << UInt64(minute & 63)
        let word = minute >> 6
        guard words[word] & bit == 0 else { return false }
        words[word] |= bit
        return true
    }

    public func contains(_ minute: Int) -> Bool {
        words[minute >> 6] & (UInt64(1) << UInt64(minute & 63)) != 0
    }

    public mutating func formUnion(_ other: MinuteSet) {
        for i in 0..<Self.wordCount { words[i] |= other.words[i] }
    }

    public var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// Number of marked minutes in `lo..<hi`, clamped to the day.
    public func count(from lo: Int, to hi: Int) -> Int {
        let lo = max(lo, 0), hi = min(hi, 1440)
        guard hi > lo else { return 0 }
        var total = 0
        var word = lo >> 6
        while word <= (hi - 1) >> 6 {
            var bits = words[word]
            let start = word << 6
            if lo > start { bits &= ~UInt64(0) << UInt64(lo - start) }
            if hi < start + 64 { bits &= (UInt64(1) << UInt64(hi - start)) - 1 }
            total += bits.nonzeroBitCount
            word += 1
        }
        return total
    }
}

public struct BucketKey: Hashable, Sendable {
    /// Seconds since 1970 divided by 900: every UTC offset in use is a multiple of 15 minutes,
    /// so quarter hours map exactly onto local days and hours anywhere.
    public var quarter: Int32
    public var model: Int32
    public var project: Int32

    public init(quarter: Int32, model: Int32, project: Int32) {
        self.quarter = quarter
        self.model = model
        self.project = project
    }
}

public struct ProjectInfo: Codable, Hashable, Sendable {
    /// Folder name under `~/.claude/projects`, which Claude Code derives from the project path.
    public var folder: String
    public var name: String
    /// 0: guessed from the folder, 1: from a directory inside the project, 2: from the project directory.
    public var nameQuality: Int

    public init(folder: String, name: String, nameQuality: Int) {
        self.folder = folder
        self.name = name
        self.nameQuality = nameQuality
    }
}

/// Everything Claudon knows about local usage, as plain values.
public struct UsageRollup: Sendable {
    public struct Bucket: Sendable {
        public var key: BucketKey
        public var counts: TokenCounts

        public init(key: BucketKey, counts: TokenCounts) {
            self.key = key
            self.counts = counts
        }
    }

    public struct Minutes: Sendable {
        /// Days since 1970, UTC.
        public var day: Int32
        public var model: Int32
        public var set: MinuteSet

        public init(day: Int32, model: Int32, set: MinuteSet) {
            self.day = day
            self.model = model
            self.set = set
        }
    }

    public var models: [String]
    public var projects: [ProjectInfo]
    public var buckets: [Bucket]
    public var minutes: [Minutes]
    public var lastActivity: Date?
    public var transcriptCount: Int

    public init(models: [String], projects: [ProjectInfo], buckets: [Bucket], minutes: [Minutes],
                lastActivity: Date?, transcriptCount: Int) {
        self.models = models
        self.projects = projects
        self.buckets = buckets
        self.minutes = minutes
        self.lastActivity = lastActivity
        self.transcriptCount = transcriptCount
    }

    public static let empty = UsageRollup(models: [], projects: [], buckets: [], minutes: [],
                                          lastActivity: nil, transcriptCount: 0)
}
