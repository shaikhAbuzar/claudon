import ClaudonCore
import Foundation

extension WidgetSnapshot {
    /// Made-up data for the widget gallery, before the app has written anything.
    public static func preview(now: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        let weeks = 26
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let row = (weekday - calendar.firstWeekday + 7) % 7
        let count = (weeks - 1) * 7 + row + 1
        // A fixed pattern: busier weekdays, quiet weekends, a few days off.
        let dayLevels = (0..<count).map { i -> Int in
            let r = i % 7
            let weekend = (r + calendar.firstWeekday - 1) % 7 == 0 || (r + calendar.firstWeekday - 1) % 7 == 6
            let wave = (i * 7 + i / 7 * 3) % 11
            if wave == 0 { return 0 }
            return weekend ? (wave % 3 == 0 ? 1 : 0) : 1 + wave % 4
        }
        let hourLevels = (0..<(7 * 24)).map { i -> Int in
            let hour = i % 24, day = i / 24
            guard (9...18).contains(hour) || (20...22).contains(hour) else { return 0 }
            let base = (10...12).contains(hour) || (14...17).contains(hour) ? 3 : 1
            return day == 0 || day == 6 ? max(0, base - 2) : min(4, base + (hour + day) % 2)
        }
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let rowNames = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let weekReset = now.addingTimeInterval(3 * 86_400 + 5 * 3600)
        let limits = LimitsSnapshot(fetchedAt: now, windows: [
            LimitWindow(id: "session", kind: "session", title: "Session", percent: 42,
                        resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
            LimitWindow(id: "weekly_all", kind: "weekly_all", title: "Week · all models", percent: 61,
                        resetsAt: weekReset),
        ], extra: nil)
        return WidgetSnapshot(generatedAt: now, limits: limits, limitsStale: false, metric: .tokens,
                              today: Totals(tokens: 1_240_000, minutes: 185, cost: 9.8),
                              week: Totals(tokens: 9_800_000, minutes: 1_320, cost: 71),
                              dayLevels: dayLevels, monthLabels: [], hourLevels: hourLevels,
                              hourRowNames: rowNames)
    }
}
