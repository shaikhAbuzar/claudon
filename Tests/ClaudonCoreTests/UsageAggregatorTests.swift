import Foundation
import Testing
@testable import ClaudonCore

/// India is UTC+5:30, so local hours straddle UTC hours: a good test of quarter-hour buckets.
private var india: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    calendar.firstWeekday = 1
    return calendar
}

private func quarter(_ iso: String) -> Int32 {
    Int32(Timestamp.parse(iso)! / 900)
}

private func minutes(from iso: String, count: Int) -> [UsageRollup.Minutes] {
    let start = Int(Timestamp.parse(iso)! / 60)
    var sets: [Int32: MinuteSet] = [:]
    for m in start..<(start + count) {
        sets[Int32(m / 1440), default: MinuteSet()].insert(m % 1440)
    }
    return sets.map { UsageRollup.Minutes(day: $0.key, model: 0, set: $0.value) }
}

private let rollup = UsageRollup(
    models: ["claude-opus-5", "claude-haiku-4-5", "claude-haiku-4-5-20251001"],
    projects: [ProjectInfo(folder: "-a", name: "alpha", nameQuality: 2),
               ProjectInfo(folder: "-b", name: "beta", nameQuality: 2)],
    buckets: [
        // Tue 22 Sep 10:00 IST
        .init(key: BucketKey(quarter: quarter("2026-09-22T04:30:00Z"), model: 0, project: 0),
              counts: TokenCounts(input: 1_000_000, output: 0, messages: 2)),
        // Tue 22 Sep 23:45 IST, still Tuesday locally though Tuesday 18:15 UTC
        .init(key: BucketKey(quarter: quarter("2026-09-22T18:15:00Z"), model: 1, project: 1),
              counts: TokenCounts(input: 100, output: 0, messages: 1)),
        // Wed 23 Sep 00:15 IST, Tuesday 18:45 UTC; the dated Haiku id joins the Haiku group
        .init(key: BucketKey(quarter: quarter("2026-09-22T18:45:00Z"), model: 2, project: 1),
              counts: TokenCounts(input: 50, output: 0, messages: 1)),
    ],
    minutes: minutes(from: "2026-09-22T04:30:00Z", count: 90),
    lastActivity: nil, transcriptCount: 1)

private let now = Timestamp.date("2026-09-23T06:30:00Z")! // Wed 23 Sep 12:00 IST

@Test func groupsModelIdsByDisplayName() {
    let aggregator = UsageAggregator(rollup: rollup, calendar: india)
    #expect(aggregator.groupNames == ["Opus 5", "Haiku 4.5"])
    #expect(aggregator.groupsByUsage == ["Opus 5", "Haiku 4.5"])
}

@Test func daysFollowLocalMidnight() throws {
    let aggregator = UsageAggregator(rollup: rollup, calendar: india)
    let days = aggregator.days(weeks: 2, group: nil, now: now)
    // Two weeks starting on a Sunday, through Wednesday: 7 + 4 days.
    #expect(days.count == 11)
    #expect(india.component(.weekday, from: days[0].date) == 1)
    let tuesday = try #require(days.first { india.isDate($0.date, inSameDayAs: Timestamp.date("2026-09-22T06:00:00Z")!) })
    #expect(tuesday.tokens == 1_000_100)
    #expect(tuesday.minutes == 90)
    #expect(tuesday.topModel == "Opus 5")
    let wednesday = try #require(days.last)
    #expect(wednesday.tokens == 50)
    #expect(wednesday.topModel == "Haiku 4.5")

    let haiku = aggregator.groupIndex(named: "Haiku 4.5")
    let filtered = aggregator.days(weeks: 2, group: haiku, now: now)
    #expect(filtered.reduce(0) { $0 + $1.tokens } == 150)
    #expect(filtered.reduce(0) { $0 + $1.minutes } == 0)
}

@Test func hoursUseLocalWeekdayAndHour() throws {
    let aggregator = UsageAggregator(rollup: rollup, calendar: india)
    let hours = aggregator.hours(days: 30, group: nil, now: now)
    #expect(hours.count == 168)
    #expect(hours.first?.weekday == 1)
    let tuesdayTen = try #require(hours.first { $0.weekday == 3 && $0.hour == 10 })
    #expect(tuesdayTen.tokens == 1_000_000)
    #expect(tuesdayTen.minutes == 60)
    #expect(hours.first { $0.weekday == 3 && $0.hour == 11 }?.minutes == 30)
    #expect(hours.first { $0.weekday == 3 && $0.hour == 23 }?.tokens == 100)
    #expect(hours.first { $0.weekday == 4 && $0.hour == 0 }?.tokens == 50)
}

@Test func summariesAndSharesAddUp() throws {
    let aggregator = UsageAggregator(rollup: rollup, calendar: india)
    let today = india.startOfDay(for: now)
    let todaySummary = aggregator.summary(from: today, to: now)
    #expect(todaySummary.tokens == 50)
    #expect(todaySummary.messages == 1)

    let week = aggregator.summary(from: india.date(byAdding: .day, value: -6, to: today)!, to: now)
    #expect(week.tokens == 1_000_150)
    #expect(week.minutes == 90)
    #expect(abs(week.cost - 5.00015) < 1e-9) // Opus 5 at $5 plus Haiku 4.5 at $1 per million input tokens

    let models = aggregator.modelShares(since: nil, now: now)
    #expect(models.map(\.name) == ["Opus 5", "Haiku 4.5"])
    #expect(abs(models.map(\.share).reduce(0, +) - 1) < 1e-9)
    #expect(models.first?.minutes == 90)

    let projects = aggregator.projectShares(since: nil, now: now)
    #expect(projects.map(\.name) == ["alpha", "beta"])
    #expect(projects.last?.tokens == 150)
}

@Test func quantileLevelsSpreadLikeGitHub() {
    let scale = QuantileScale(values: (1...20).map(Double.init) + [0, 0])
    #expect(scale.level(0) == 0)
    #expect(scale.level(1) == 1)
    #expect(scale.level(20) == 4)
    let few = QuantileScale(values: [0, 10, 40])
    #expect(few.level(10) == 1)
    #expect(few.level(40) == 4)
}

@Test func minuteSetCountsRanges() {
    var set = MinuteSet()
    for minute in [0, 63, 64, 1439] { set.insert(minute) }
    #expect(set.count == 4)
    #expect(set.count(from: 0, to: 64) == 2)
    #expect(set.count(from: 63, to: 65) == 2)
    #expect(set.count(from: 1000, to: 1440) == 1)
    #expect(set.count(from: 5, to: 5) == 0)
}
