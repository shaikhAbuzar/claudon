import Foundation
import Testing
@testable import ClaudonCore

/// The shape `GET /api/oauth/usage` returned on 2026-09-23 (values only).
private let currentResponse = """
{"five_hour":{"utilization":17.0,"resets_at":"2026-09-23T10:09:59.532362+00:00"},\
"seven_day":{"utilization":3.0,"resets_at":"2026-09-23T06:59:59.532384+00:00"},\
"seven_day_opus":null,"nimbus_quill":{"utilization":0.0,"resets_at":null},\
"extra_usage":{"is_enabled":true,"monthly_limit":1000000,"used_credits":817238.0,"utilization":81.7238,"currency":"USD","decimal_places":2},\
"limits":[{"kind":"session","group":"session","percent":17,"severity":"normal","resets_at":"2026-09-23T10:09:59.532362+00:00","scope":null,"is_active":true},\
{"kind":"weekly_all","group":"weekly","percent":3,"severity":"normal","resets_at":"2026-09-23T06:59:59.532384+00:00","scope":null,"is_active":false},\
{"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal","resets_at":"2026-09-23T06:59:59.532570+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],\
"spend":{"used":{"amount_minor":817238,"currency":"USD","exponent":2},"limit":{"amount_minor":1000000,"currency":"USD","exponent":2},"percent":82,"severity":"warning","enabled":true}}
"""

@Test func parsesTheLimitsList() throws {
    let snapshot = try LimitsParser.parse(Data(currentResponse.utf8), fetchedAt: Date(timeIntervalSince1970: 0))
    #expect(snapshot.windows.map(\.title) == ["Session", "Week · all models", "Week · Fable"])
    #expect(snapshot.windows.map(\.percent) == [17, 3, 5])
    #expect(snapshot.session?.resetsAt == Timestamp.date("2026-09-23T10:09:59.532362Z"))
    let extra = try #require(snapshot.extra)
    #expect(extra.isEnabled)
    #expect(abs(extra.used - 8172.38) < 1e-6)
    #expect(extra.limit == 10_000)
    #expect(extra.percent == 82)
}

@Test func fallsBackToTheOlderFields() throws {
    let legacy = """
    {"five_hour":{"utilization":42.5,"resets_at":"2026-09-23T10:00:00Z"},"seven_day":{"utilization":10,"resets_at":null},\
    "seven_day_opus":{"utilization":true,"resets_at":null},"seven_day_sonnet":null,\
    "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
    """
    let snapshot = try LimitsParser.parse(Data(legacy.utf8), fetchedAt: Date())
    #expect(snapshot.windows.map(\.kind) == ["session", "weekly_all"])
    #expect(snapshot.windows.first?.percent == 42.5)
    #expect(snapshot.extra?.isEnabled == false)
    #expect(throws: LimitsError.badResponse) { try LimitsParser.parse(Data("[]".utf8), fetchedAt: Date()) }
}

@Test func credentialsParseAndDescribeThePlan() throws {
    let json = #"{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"r","expiresAt":1790165039055,"scopes":["user:inference"],"subscriptionType":"team","rateLimitTier":"default_claude_max_5x"}}"#
    let credentials = try #require(ClaudeCredentials.parse(Data(json.utf8)))
    #expect(credentials.accessToken == "test-token")
    #expect(credentials.planLabel == "Team · Max 5x")
    #expect(credentials.isExpired(at: Date(timeIntervalSince1970: 1_790_165_040)))
    #expect(!credentials.isExpired(at: Date(timeIntervalSince1970: 1_790_165_000)))
    #expect(OAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: "max",
                             rateLimitTier: "default_claude_max_20x").planLabel == "Max 20x")
    #expect(OAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: "pro", rateLimitTier: nil).planLabel == "Pro")
    #expect(ClaudeCredentials.parse(Data("{}".utf8)) == nil)
}

private func snapshot(session: Double, sessionReset: TimeInterval = 4 * 3600 + 39 * 60,
                      weekly: Double = 3, weeklyReset: TimeInterval = 3 * 86_400, now: Date) -> LimitsSnapshot {
    LimitsSnapshot(fetchedAt: now, windows: [
        LimitWindow(id: "session", kind: "session", title: "Session", percent: session,
                    resetsAt: now.addingTimeInterval(sessionReset)),
        LimitWindow(id: "weekly_all", kind: "weekly_all", title: "Week · all models", percent: weekly,
                    resetsAt: now.addingTimeInterval(weeklyReset)),
    ], extra: nil)
}

@Test func menuBarShowsSessionAndCountdown() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    #expect(MenuBarSummary.make(from: snapshot(session: 17, now: now), now: now)
            == MenuBarSummary(text: "17% · 4h 39m", level: .normal, stage: 1))
    #expect(MenuBarSummary.make(from: snapshot(session: 85, now: now), now: now)?.level == .warning)
    #expect(MenuBarSummary.make(from: snapshot(session: 97, now: now), now: now)?.level == .critical)
    // After the reset time the session starts over.
    let later = now.addingTimeInterval(5 * 3600)
    #expect(MenuBarSummary.make(from: snapshot(session: 97, now: now), now: later)?.text == "0%")
    // A used-up weekly limit is what blocks, so it takes over.
    #expect(MenuBarSummary.make(from: snapshot(session: 10, weekly: 100, weeklyReset: 2 * 86_400, now: now), now: now)
            == MenuBarSummary(text: "Week 100% · 2d", level: .critical, stage: 9))
    #expect(MenuBarSummary.make(from: nil, now: now) == nil)
}

@Test func stagesStepEveryTenPercent() {
    #expect(UsageLevel.stage(percent: 0) == 0)
    #expect(UsageLevel.stage(percent: 9.9) == 0)
    #expect(UsageLevel.stage(percent: 10) == 1)
    #expect(UsageLevel.stage(percent: 55) == 5)
    #expect(UsageLevel.stage(percent: 99.9) == 9)
    #expect(UsageLevel.stage(percent: 100) == 9)
    #expect(UsageLevel.stage(percent: 140) == 9)
    #expect(UsageLevel.stage(percent: -5) == 0)
}

@Test func alertsFireOncePerThresholdAndWindow() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    #expect(AlertPlanner.alerts(for: snapshot(session: 50, now: now), now: now, sent: []).isEmpty)

    let first = AlertPlanner.alerts(for: snapshot(session: 85, now: now), now: now, sent: [])
    #expect(first.count == 1)
    #expect(first[0].title == "Session at 85%")
    #expect(first[0].keys.count == 1)
    let sent = Set(first.flatMap(\.keys))
    #expect(AlertPlanner.alerts(for: snapshot(session: 90, now: now), now: now, sent: sent).isEmpty)

    let critical = AlertPlanner.alerts(for: snapshot(session: 96, now: now), now: now, sent: sent)
    #expect(critical.count == 1)
    #expect(critical[0].body.hasPrefix("Almost at the limit."))
    #expect(critical[0].keys.count == 2)

    // Jumping straight past 95% sends one alert, not two.
    #expect(AlertPlanner.alerts(for: snapshot(session: 99, now: now), now: now, sent: []).count == 1)

    let extra = LimitsSnapshot(fetchedAt: now, windows: [],
                               extra: ExtraUsage(isEnabled: true, used: 8172.38, limit: 10_000, currency: "USD", percent: 82))
    #expect(AlertPlanner.alerts(for: extra, now: now, sent: []).first?.title == "Extra usage at 82%")
}

@Test func resetReminderOnlyWhenTheSessionWasBusy() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    #expect(AlertPlanner.sessionResetReminder(for: snapshot(session: 40, now: now), now: now) == nil)
    let reminder = AlertPlanner.sessionResetReminder(for: snapshot(session: 88, now: now), now: now)
    #expect(reminder?.date == now.addingTimeInterval(4 * 3600 + 39 * 60))
}

@Test func formattersStayCompact() {
    #expect(Formatters.tokens(950) == "950")
    #expect(Formatters.tokens(12_345) == "12K")
    #expect(Formatters.tokens(4_100_000) == "4.1M")
    #expect(Formatters.tokens(999_960) == "1M")
    #expect(Formatters.tokens(3_700_000_000) == "3.7B")
    #expect(Formatters.countdown(0) == "now")
    #expect(Formatters.countdown(30) == "1m")
    #expect(Formatters.countdown(39 * 60) == "39m")
    #expect(Formatters.countdown(4 * 3600 + 39 * 60) == "4h 39m")
    #expect(Formatters.countdown(2 * 86_400 + 4 * 3600) == "2d 4h")
    #expect(Formatters.duration(minutes: 45) == "45m")
    #expect(Formatters.duration(minutes: 155) == "2h 35m")
    #expect(Formatters.duration(minutes: 120) == "2h")
    #expect(Formatters.duration(minutes: 7600) == "126h")
    #expect(Formatters.percent(0.4) == "<1%")
    #expect(Formatters.percent(17.2) == "17%")
}
