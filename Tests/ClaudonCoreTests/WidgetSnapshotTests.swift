import Foundation
import Testing
@testable import ClaudonCore

private func snapshot(session: Double, weekly: Double, now: Date) -> WidgetSnapshot {
    let limits = LimitsSnapshot(fetchedAt: now, windows: [
        LimitWindow(id: "session", kind: "session", title: "Session", percent: session,
                    resetsAt: now.addingTimeInterval(3600)),
        LimitWindow(id: "weekly_all", kind: "weekly_all", title: "Week · all models", percent: weekly,
                    resetsAt: now.addingTimeInterval(86_400)),
    ], extra: nil)
    return WidgetSnapshot(generatedAt: now, limits: limits, limitsStale: false, metric: .time,
                          today: .init(tokens: 1200, minutes: 35, cost: 0.4),
                          week: .init(tokens: 9000, minutes: 240, cost: 3.1),
                          dayLevels: [0, 1, 2, 3, 4], monthLabels: [.init(column: 0, text: "Sep")],
                          hourLevels: Array(repeating: 0, count: 168), hourRowNames: ["Mon"])
}

@Test func widgetFileRoundTrips() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = snapshot(session: 42, weekly: 61, now: now)
    try original.encoded().write(to: url)
    #expect(WidgetSnapshot.load(from: url) == original)
    #expect(WidgetSnapshot.load(from: url.appendingPathExtension("missing")) == nil)
}

@Test func limitsSignatureIgnoresUsageTotals() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var busier = snapshot(session: 42.3, weekly: 61, now: now)
    busier.today.tokens *= 10
    #expect(busier.limitsSignature == snapshot(session: 42, weekly: 61, now: now).limitsSignature)
    #expect(snapshot(session: 43, weekly: 61, now: now).limitsSignature
            != snapshot(session: 42, weekly: 61, now: now).limitsSignature)
    busier.limitsStale = true
    #expect(busier.limitsSignature != snapshot(session: 42, weekly: 61, now: now).limitsSignature)
}

@Test func headlineIsTheSessionUnlessAWeekIsUsedUp() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let normal = try #require(snapshot(session: 42, weekly: 61, now: now).limits?.headline(at: now))
    #expect(normal.window.id == "session" && !normal.blocking)
    let blocked = try #require(snapshot(session: 10, weekly: 100, now: now).limits?.headline(at: now))
    #expect(blocked.window.id == "weekly_all" && blocked.blocking)
    // Once the week resets, the session leads again.
    let later = now.addingTimeInterval(2 * 86_400)
    #expect(snapshot(session: 10, weekly: 100, now: now).limits?.headline(at: later)?.window.id == "session")
}
