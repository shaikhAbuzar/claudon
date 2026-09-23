import Foundation

public enum Metric: String, CaseIterable, Sendable {
    case tokens, time
}

public struct DayStat: Sendable, Identifiable, Equatable {
    public var id: Date { date }
    /// Local midnight.
    public var date: Date
    public var tokens: Int64
    public var minutes: Int
    public var cost: Double
    public var messages: Int64
    public var topModel: String?

    public func value(_ metric: Metric) -> Double {
        metric == .tokens ? Double(tokens) : Double(minutes)
    }
}

public struct HourStat: Sendable, Equatable {
    /// 1 is Sunday, as in `Calendar`.
    public var weekday: Int
    public var hour: Int
    public var tokens: Int64
    public var minutes: Int

    public func value(_ metric: Metric) -> Double {
        metric == .tokens ? Double(tokens) : Double(minutes)
    }
}

public struct PeriodSummary: Sendable, Equatable {
    public var tokens: Int64 = 0
    public var minutes = 0
    public var cost: Double = 0
    public var messages: Int64 = 0
    public var topModel: String?

    public init() {}

    public static let empty = PeriodSummary()
}

public struct ShareRow: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var tokens: Int64
    public var cost: Double
    public var messages: Int64
    public var minutes: Int?
    /// Fraction of the range's tokens.
    public var share: Double

    public init(id: String, name: String, tokens: Int64, cost: Double, messages: Int64, minutes: Int?, share: Double) {
        self.id = id
        self.name = name
        self.tokens = tokens
        self.cost = cost
        self.messages = messages
        self.minutes = minutes
        self.share = share
    }
}

/// Answers the popover's questions (per day, per hour, per model, per project) from a rollup.
/// Immutable after init.
public final class UsageAggregator: @unchecked Sendable {
    public let rollup: UsageRollup
    public let calendar: Calendar
    /// Model display names. Ids that share a name ("claude-haiku-4-5" and
    /// "claude-haiku-4-5-20251001") form one group.
    public let groupNames: [String]

    private struct Entry {
        var start: Double
        var group: Int
        var project: Int
        var counts: TokenCounts
        var cost: Double
    }

    private let entries: [Entry]
    private let groupMinutes: [[Int32: MinuteSet]]
    private let allMinutes: [Int32: MinuteSet]

    public init(rollup: UsageRollup, calendar: Calendar = .current) {
        self.rollup = rollup
        self.calendar = calendar

        var names: [String] = []
        var nameIndex: [String: Int] = [:]
        var groupOfModel: [Int] = []
        var prices: [ModelPrice?] = []
        for key in rollup.models {
            let info = ModelCatalog.info(for: key)
            if let known = nameIndex[info.displayName] {
                groupOfModel.append(known)
            } else {
                nameIndex[info.displayName] = names.count
                groupOfModel.append(names.count)
                names.append(info.displayName)
            }
            prices.append(info.price)
        }
        groupNames = names

        var entries: [Entry] = []
        entries.reserveCapacity(rollup.buckets.count)
        for bucket in rollup.buckets {
            let model = Int(bucket.key.model)
            guard groupOfModel.indices.contains(model) else { continue }
            entries.append(Entry(start: Double(bucket.key.quarter) * 900, group: groupOfModel[model],
                                 project: Int(bucket.key.project), counts: bucket.counts,
                                 cost: prices[model]?.cost(of: bucket.counts) ?? 0))
        }
        entries.sort { $0.start < $1.start }
        self.entries = entries

        var perGroup = Array(repeating: [Int32: MinuteSet](), count: names.count)
        var all: [Int32: MinuteSet] = [:]
        for row in rollup.minutes {
            let model = Int(row.model)
            guard groupOfModel.indices.contains(model) else { continue }
            perGroup[groupOfModel[model]][row.day, default: MinuteSet()].formUnion(row.set)
            all[row.day, default: MinuteSet()].formUnion(row.set)
        }
        groupMinutes = perGroup
        allMinutes = all
    }

    public func groupIndex(named name: String) -> Int? {
        groupNames.firstIndex(of: name)
    }

    /// Model names ordered by all-time tokens, for the model filter.
    public var groupsByUsage: [String] {
        var totals = Array(repeating: Int64(0), count: groupNames.count)
        for entry in entries { totals[entry.group] += entry.counts.total }
        return groupNames.indices.filter { totals[$0] > 0 }
            .sorted { totals[$0] > totals[$1] }
            .map { groupNames[$0] }
    }

    public var isEmpty: Bool { entries.isEmpty && allMinutes.isEmpty }

    // MARK: Periods

    public func summary(from start: Date, to end: Date) -> PeriodSummary {
        var summary = PeriodSummary()
        var perGroup = Array(repeating: Int64(0), count: groupNames.count)
        let lo = lowerBound(start.timeIntervalSince1970)
        let hi = max(lo, lowerBound(end.timeIntervalSince1970))
        for entry in entries[lo..<hi] {
            summary.tokens += entry.counts.total
            summary.cost += entry.cost
            summary.messages += entry.counts.messages
            perGroup[entry.group] += entry.counts.total
        }
        summary.minutes = activeMinutes(from: start, to: end)
        summary.topModel = top(perGroup)
        return summary
    }

    /// Active minutes in `start..<end`.
    public func activeMinutes(from start: Date, to end: Date, group: Int? = nil) -> Int {
        Self.countMinutes(from: minute(start), to: minute(end), in: minuteSets(group))
    }

    // MARK: Calendar

    /// One entry per local day, from the first day of the week `weeks - 1` weeks ago through today.
    public func days(weeks: Int, group: Int?, now: Date) -> [DayStat] {
        let today = calendar.startOfDay(for: now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        guard weeks > 0, let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }

        var starts: [Date] = []
        var day = first
        while day <= today {
            starts.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard !starts.isEmpty else { return [] }
        let bounds = starts.map(\.timeIntervalSince1970) + [tomorrow.timeIntervalSince1970]

        var tokens = Array(repeating: Int64(0), count: starts.count)
        var costs = Array(repeating: 0.0, count: starts.count)
        var messages = Array(repeating: Int64(0), count: starts.count)
        var perGroup = Array(repeating: Array(repeating: Int64(0), count: groupNames.count), count: starts.count)
        var i = lowerBound(bounds[0])
        var k = 0
        while i < entries.count, entries[i].start < bounds[starts.count] {
            let entry = entries[i]
            i += 1
            while entry.start >= bounds[k + 1] { k += 1 }
            guard group == nil || entry.group == group else { continue }
            tokens[k] += entry.counts.total
            costs[k] += entry.cost
            messages[k] += entry.counts.messages
            perGroup[k][entry.group] += entry.counts.total
        }

        let sets = minuteSets(group)
        let nowMinute = minute(now)
        return starts.indices.map { k in
            let minutes = Self.countMinutes(from: Int(bounds[k] / 60), to: min(Int(bounds[k + 1] / 60), nowMinute),
                                            in: sets)
            return DayStat(date: starts[k], tokens: tokens[k], minutes: minutes, cost: costs[k],
                           messages: messages[k], topModel: top(perGroup[k]))
        }
    }

    /// Tokens and active minutes by weekday and hour over the last `days` days, today included.
    /// Rows start at the calendar's first weekday; each row holds hours 0 to 23.
    public func hours(days: Int, group: Int?, now: Date) -> [HourStat] {
        let today = calendar.startOfDay(for: now)
        guard days > 0, let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var tokens = Array(repeating: Array(repeating: Int64(0), count: 24), count: 8)
        var minutes = Array(repeating: Array(repeating: 0, count: 24), count: 8)

        var lastStart = -1.0
        var slot = (weekday: 1, hour: 0)
        var i = lowerBound(start.timeIntervalSince1970)
        let end = now.timeIntervalSince1970
        while i < entries.count, entries[i].start <= end {
            let entry = entries[i]
            i += 1
            guard group == nil || entry.group == group else { continue }
            if entry.start != lastStart {
                let parts = calendar.dateComponents([.weekday, .hour], from: Date(timeIntervalSince1970: entry.start))
                slot = (parts.weekday ?? 1, parts.hour ?? 0)
                lastStart = entry.start
            }
            tokens[slot.weekday][slot.hour] += entry.counts.total
        }

        let sets = minuteSets(group)
        let nowMinute = minute(now)
        var hourStart = start
        while hourStart < now {
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { break }
            let parts = calendar.dateComponents([.weekday, .hour], from: hourStart)
            if let weekday = parts.weekday, let hour = parts.hour {
                minutes[weekday][hour] += Self.countMinutes(from: minute(hourStart),
                                                            to: min(minute(next), nowMinute), in: sets)
            }
            hourStart = next
        }

        var out: [HourStat] = []
        for row in 0..<7 {
            let weekday = (calendar.firstWeekday - 1 + row) % 7 + 1
            for hour in 0..<24 {
                out.append(HourStat(weekday: weekday, hour: hour, tokens: tokens[weekday][hour],
                                    minutes: minutes[weekday][hour]))
            }
        }
        return out
    }

    // MARK: Breakdowns

    /// Per model since `start` (all time when nil), largest first.
    public func modelShares(since start: Date?, now: Date) -> [ShareRow] {
        var tokens = Array(repeating: Int64(0), count: groupNames.count)
        var costs = Array(repeating: 0.0, count: groupNames.count)
        var messages = Array(repeating: Int64(0), count: groupNames.count)
        for entry in entries[firstIndex(since: start)...] where entry.start <= now.timeIntervalSince1970 {
            tokens[entry.group] += entry.counts.total
            costs[entry.group] += entry.cost
            messages[entry.group] += entry.counts.messages
        }
        let total = tokens.reduce(0, +)
        return groupNames.indices.filter { tokens[$0] > 0 }.map { g in
            let minutes = start.map { activeMinutes(from: $0, to: now, group: g) }
                ?? groupMinutes[g].values.reduce(0) { $0 + $1.count }
            return ShareRow(id: groupNames[g], name: groupNames[g], tokens: tokens[g], cost: costs[g],
                            messages: messages[g], minutes: minutes,
                            share: total > 0 ? Double(tokens[g]) / Double(total) : 0)
        }
        .sorted { $0.tokens > $1.tokens }
    }

    /// Per project since `start` (all time when nil), largest first.
    public func projectShares(since start: Date?, now: Date) -> [ShareRow] {
        let count = rollup.projects.count
        var tokens = Array(repeating: Int64(0), count: count)
        var costs = Array(repeating: 0.0, count: count)
        var messages = Array(repeating: Int64(0), count: count)
        for entry in entries[firstIndex(since: start)...]
        where entry.start <= now.timeIntervalSince1970 && rollup.projects.indices.contains(entry.project) {
            tokens[entry.project] += entry.counts.total
            costs[entry.project] += entry.cost
            messages[entry.project] += entry.counts.messages
        }
        let total = tokens.reduce(0, +)
        return (0..<count).filter { tokens[$0] > 0 }.map { p in
            ShareRow(id: rollup.projects[p].folder, name: rollup.projects[p].name, tokens: tokens[p],
                     cost: costs[p], messages: messages[p], minutes: nil,
                     share: total > 0 ? Double(tokens[p]) / Double(total) : 0)
        }
        .sorted { $0.tokens > $1.tokens }
    }

    // MARK: Helpers

    private func minuteSets(_ group: Int?) -> [Int32: MinuteSet] {
        guard let group, groupMinutes.indices.contains(group) else { return allMinutes }
        return groupMinutes[group]
    }

    private func minute(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    private func top(_ perGroup: [Int64]) -> String? {
        guard let best = perGroup.indices.max(by: { perGroup[$0] < perGroup[$1] }), perGroup[best] > 0 else { return nil }
        return groupNames[best]
    }

    private func firstIndex(since start: Date?) -> Int {
        start.map { lowerBound($0.timeIntervalSince1970) } ?? 0
    }

    /// Index of the first entry starting at or after `time`.
    private func lowerBound(_ time: Double) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].start < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func countMinutes(from a: Int, to b: Int, in sets: [Int32: MinuteSet]) -> Int {
        guard b > a, !sets.isEmpty else { return 0 }
        var total = 0
        var day = TranscriptIndex.floorDiv(a, 1440)
        let lastDay = TranscriptIndex.floorDiv(b - 1, 1440)
        while day <= lastDay {
            if let set = sets[Int32(day)] {
                let dayStart = day * 1440
                total += set.count(from: a - dayStart, to: b - dayStart)
            }
            day += 1
        }
        return total
    }
}

/// Maps values to heatmap levels 0 to 4 by quartiles of the non-zero values, like GitHub.
public struct QuantileScale: Sendable {
    public let cuts: [Double]
    private let maximum: Double
    private let useQuartiles: Bool

    public init(values: [Double]) {
        let nonZero = values.filter { $0 > 0 }.sorted()
        maximum = nonZero.last ?? 0
        useQuartiles = nonZero.count >= 8
        guard useQuartiles else { cuts = []; return }
        func quantile(_ p: Double) -> Double {
            nonZero[min(nonZero.count - 1, Int((Double(nonZero.count - 1) * p).rounded()))]
        }
        cuts = [quantile(0.25), quantile(0.5), quantile(0.75)]
    }

    public func level(_ value: Double) -> Int {
        guard value > 0, maximum > 0 else { return 0 }
        guard useQuartiles else {
            // Too few days for quartiles: scale linearly against the busiest one.
            return max(1, min(4, Int((value / maximum * 4).rounded(.up))))
        }
        if value <= cuts[0] { return 1 }
        if value <= cuts[1] { return 2 }
        if value <= cuts[2] { return 3 }
        return 4
    }
}
