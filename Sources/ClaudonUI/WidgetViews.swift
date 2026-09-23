import ClaudonCore
import SwiftUI

public enum WidgetSize: CaseIterable, Sendable {
    case small, medium, large
}

/// The desktop and Notification Center widget: the leading limit with the glyph, then the
/// activity heatmaps as room allows. Built from plain shapes and text, which widgets render
/// reliably.
public struct UsageWidgetView: View {
    let snapshot: WidgetSnapshot?
    let now: Date
    let size: WidgetSize

    /// Limits older than this likely mean the app isn't running, so they show as not current.
    static let staleAfter: TimeInterval = 20 * 60

    public init(snapshot: WidgetSnapshot?, now: Date, size: WidgetSize) {
        self.snapshot = snapshot
        self.now = now
        self.size = size
    }

    public var body: some View {
        if let snapshot {
            let state = LimitState(snapshot: snapshot, now: now)
            switch size {
            case .small:
                LimitColumn(state: state, now: now, glyphSize: 22, percentSize: 32)
            case .medium:
                HStack(spacing: 16) {
                    LimitColumn(state: state, now: now, glyphSize: 20, percentSize: 30)
                        .frame(width: 118)
                    VStack(alignment: .leading, spacing: 6) {
                        CalendarGrid(snapshot: snapshot, showMonths: false)
                        TotalsLine(snapshot: snapshot)
                    }
                }
            case .large:
                LargeLayout(snapshot: snapshot, state: state, now: now)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                GlyphView(stage: nil, size: 22)
                Spacer(minLength: 0)
                Text("Open Claudon to see your Claude usage here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The leading limit and the others, worked out for the moment being drawn.
private struct LimitState {
    let headline: LimitWindow?
    let blocking: Bool
    let others: [LimitWindow]
    let stale: Bool
    let fetchedAt: Date?

    init(snapshot: WidgetSnapshot, now: Date) {
        let limits = snapshot.limits
        let lead = limits?.headline(at: now)
        headline = lead?.window
        blocking = lead?.blocking ?? false
        others = (limits?.windows ?? []).filter { $0.id != lead?.window.id }
        fetchedAt = limits?.fetchedAt
        stale = snapshot.limitsStale
            || limits.map { now.timeIntervalSince($0.fetchedAt) > UsageWidgetView.staleAfter } ?? true
    }

    func percent(at now: Date) -> Double { headline?.percent(at: now) ?? 0 }

    /// Stale numbers get the plain glyph, as in the menu bar, so an old color doesn't look current.
    func stage(at now: Date) -> Int? {
        guard headline != nil, !stale else { return nil }
        return UsageLevel.stage(percent: percent(at: now))
    }

    func resetText(at now: Date) -> String? {
        guard let reset = headline?.resetsAt else { return nil }
        guard reset > now else { return "reset, updating" }
        return "resets in \(Formatters.countdown(reset.timeIntervalSince(now)))"
    }
}

/// Glyph, the leading limit as a big percentage, its reset, and the next limit as a meter.
private struct LimitColumn: View {
    let state: LimitState
    let now: Date
    let glyphSize: CGFloat
    let percentSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                GlyphView(stage: state.stage(at: now), size: glyphSize)
                Text(state.headline.map { state.blocking ? $0.title : "Session" } ?? "Claudon")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let headline = state.headline {
                PercentText(percent: headline.percent(at: now), size: percentSize, stale: state.stale)
                Text(state.stale ? updatedText : state.resetText(at: now) ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No plan limits yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let next = state.others.first {
                LimitMeterRow(window: next, now: now, stale: state.stale, compact: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var updatedText: String {
        state.fetchedAt.map { "checked \(Formatters.resetClock($0, now: now))" } ?? " "
    }
}

private struct PercentText: View {
    let percent: Double
    let size: CGFloat
    let stale: Bool

    var body: some View {
        Text(Formatters.percent(percent))
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// Matches the menu bar text: orange from 80%, red from 95%.
    private var color: Color {
        if stale { return .secondary }
        switch UsageLevel(percent: percent) {
        case .normal: return .primary
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct LimitMeterRow: View {
    let window: LimitWindow
    let now: Date
    let stale: Bool
    var compact = false

    var body: some View {
        let percent = window.percent(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                // "Week · all models" doesn't fit a narrow column.
                Text(compact && window.kind == "weekly_all" ? "This week" : window.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Formatters.percent(percent))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.system(size: 10.5))
            WidgetMeter(fraction: percent / 100, color: stale ? .secondary : Palette.status(UsageLevel(percent: percent)))
        }
    }
}

private struct WidgetMeter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let value = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.2))
                if value > 0 {
                    Capsule().fill(color).frame(width: max(geometry.size.width * value, 5))
                }
            }
        }
        .frame(height: 5)
    }
}

private struct LargeLayout: View {
    let snapshot: WidgetSnapshot
    let state: LimitState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                GlyphView(stage: state.stage(at: now), size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.headline.map { state.blocking ? $0.title : "Session" } ?? "Claudon")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let headline = state.headline {
                        PercentText(percent: headline.percent(at: now), size: 24, stale: state.stale)
                    }
                }
                Spacer(minLength: 8)
                if let headline = state.headline {
                    VStack(alignment: .trailing, spacing: 1) {
                        if state.stale, let fetchedAt = state.fetchedAt {
                            Text("Not current")
                            Text("checked \(Formatters.resetClock(fetchedAt, now: now))")
                        } else if let reset = headline.resetsAt, reset > now {
                            Text(state.resetText(at: now) ?? "")
                            Text(Formatters.resetClock(reset, now: now))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            if !state.others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.others.prefix(2)) { window in
                        LimitMeterRow(window: window, now: now, stale: state.stale)
                    }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 10)
            SectionTitle(text: "Last \(max(1, (snapshot.dayLevels.count + 6) / 7)) weeks · \(metricName)")
            CalendarGrid(snapshot: snapshot, showMonths: true)
                .frame(height: 96)
            Spacer(minLength: 10)
            SectionTitle(text: "By weekday and hour · last 30 days")
            HourGrid(snapshot: snapshot)
                .frame(height: 70)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                TotalsLine(snapshot: snapshot)
                Spacer(minLength: 4)
                HeatLegend()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var metricName: String { snapshot.metric == .tokens ? "tokens" : "active time" }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.bottom, 4)
    }
}

/// "Today 1.2M · 7 days 9.8M" in the popover's metric.
private struct TotalsLine: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        (Text("Today ").foregroundColor(.secondary) + Text(value(snapshot.today)).fontWeight(.semibold)
            + Text("  ·  7 days ").foregroundColor(.secondary) + Text(value(snapshot.week)).fontWeight(.semibold))
            .font(.system(size: 10.5))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func value(_ totals: WidgetSnapshot.Totals) -> String {
        snapshot.metric == .tokens ? Formatters.tokens(totals.tokens) : Formatters.duration(minutes: totals.minutes)
    }
}

private struct HeatLegend: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2.5) {
            Text("Less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.heat(level, scheme)).frame(width: 8, height: 8)
            }
            Text("More")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// The day calendar, weeks as columns, showing as many recent weeks as fit the space.
private struct CalendarGrid: View {
    let snapshot: WidgetSnapshot
    let showMonths: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let header: CGFloat = showMonths ? 13 : 0
            let totalWeeks = max(1, (snapshot.dayLevels.count + 6) / 7)
            // Square cells sized to fill the height, then as many recent weeks as fit the width.
            let pitch = max(4, (geometry.size.height - header) / (7 - gapRatio))
            let weeks = min(totalWeeks, max(1, Int((geometry.size.width + pitch * gapRatio) / pitch)))
            let gap = pitch * gapRatio, cell = pitch - gap
            let firstColumn = totalWeeks - weeks
            ZStack(alignment: .topLeading) {
                if showMonths {
                    ForEach(snapshot.monthLabels.filter { $0.column >= firstColumn }, id: \.column) { label in
                        Text(label.text)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: CGFloat(label.column - firstColumn) * pitch)
                    }
                }
                HeatCells(levels: snapshot.dayLevels, cellsPerLine: 7, columnMajor: true,
                          firstLine: firstColumn, cell: CGSize(width: cell, height: cell), gap: gap, top: header)
            }
            .frame(width: CGFloat(weeks) * pitch - gap, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel("Daily Claude Code activity")
    }

    private let gapRatio: CGFloat = 0.18
}

/// Weekday rows by 24 hours, with row names and a few hour marks.
private struct HourGrid: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        GeometryReader { geometry in
            let label: CGFloat = 26, header: CGFloat = 12
            let pitchX = (geometry.size.width - label) / 24
            let pitchY = (geometry.size.height - header) / 7
            let gap = min(pitchX, pitchY) * 0.18
            ZStack(alignment: .topLeading) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(Formatters.hourLabel(hour))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: label + CGFloat(hour) * pitchX)
                }
                ForEach(Array(snapshot.hourRowNames.enumerated()), id: \.offset) { row, name in
                    if row % 2 == 1 {
                        Text(name)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(height: pitchY - gap)
                            .offset(y: header + CGFloat(row) * pitchY)
                    }
                }
                HeatCells(levels: snapshot.hourLevels, cellsPerLine: 24, columnMajor: false, firstLine: 0,
                          cell: CGSize(width: pitchX - gap, height: pitchY - gap), gap: gap, top: header)
                    .offset(x: label)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Activity by weekday and hour")
    }
}

/// Heatmap squares as one filled shape per level. Lines are columns (column-major, 7 per
/// week) or rows (24 hours per weekday); lines before `firstLine` are skipped.
private struct HeatCells: View {
    let levels: [Int]
    let cellsPerLine: Int
    let columnMajor: Bool
    let firstLine: Int
    let cell: CGSize
    let gap: CGFloat
    let top: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5, id: \.self) { level in
                Cells(rects: rects(for: level), radius: max(1, min(cell.width, cell.height) * 0.2))
                    .fill(Palette.heat(level, scheme))
            }
        }
    }

    private func rects(for level: Int) -> [CGRect] {
        levels.indices.compactMap { i in
            guard levels[i] == level else { return nil }
            let line = i / cellsPerLine, position = i % cellsPerLine
            guard line >= firstLine else { return nil }
            let (column, row) = columnMajor ? (line - firstLine, position) : (position, line)
            return CGRect(x: CGFloat(column) * (cell.width + gap), y: top + CGFloat(row) * (cell.height + gap),
                          width: cell.width, height: cell.height)
        }
    }
}

private struct Cells: Shape {
    let rects: [CGRect]
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for cell in rects {
            path.addRoundedRect(in: cell, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}
