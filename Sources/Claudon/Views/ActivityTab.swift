import ClaudonCore
import SwiftUI

struct ActivityTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hover: HoverState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One row of filters above both grids; they scope everything below.
            HStack {
                Segmented(options: [(Metric.tokens, "Tokens"), (.time, "Time")], selection: $model.metric)
                Spacer()
                ModelFilterMenu(model: model)
            }
            .padding(.bottom, 10)

            if let data = model.activity {
                CalendarHeatmap(data: data, hover: hover)
                Readout(data: data, hover: hover)
                    .padding(.top, 6)
                Text("When you use Claude · last \(AppModel.hourGridDays) days")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.bottom, 5)
                HourGrid(data: data, hover: hover)
                HStack {
                    Text(data.metric == .tokens ? "Shade: tokens" : "Shade: active time")
                    Spacer()
                    Legend()
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            } else {
                Text(model.usageLoaded ? "No Claude Code usage found yet." : "Reading Claude Code transcripts…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ModelFilterMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            HStack(spacing: 3) {
                Text(model.modelFilter ?? "All models")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            Toggle("All models", isOn: Binding(get: { model.modelFilter == nil },
                                               set: { if $0 { model.modelFilter = nil } }))
            if !model.modelOptions.isEmpty { Divider() }
            ForEach(model.modelOptions, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { model.modelFilter == name },
                                           set: { if $0 { model.modelFilter = name } }))
            }
        } label: {
            Text(model.modelFilter ?? "All models")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show one model")
    }
}

/// GitHub-style grid: one square per day, weeks as columns.
struct CalendarHeatmap: View {
    let data: ActivityData
    @ObservedObject var hover: HoverState
    @Environment(\.colorScheme) private var scheme

    static let cell: CGFloat = 11
    static let gap: CGFloat = 2
    static let labelWidth: CGFloat = 26
    static let headerHeight: CGFloat = 14
    private var pitch: CGFloat { Self.cell + Self.gap }

    var body: some View {
        Canvas { context, _ in
            for label in data.monthLabels {
                context.draw(Text(label.text).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: Self.labelWidth + CGFloat(label.id) * pitch, y: 0), anchor: .topLeading)
            }
            for label in data.weekdayLabels {
                context.draw(Text(label.text).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: 0, y: Self.headerHeight + CGFloat(label.id) * pitch + Self.cell / 2),
                             anchor: .leading)
            }
            for i in data.days.indices {
                context.fill(Path(roundedRect: rect(i), cornerRadius: 2),
                             with: .color(Theme.heat(data.dayLevels[i], scheme)))
            }
            if let day = hover.day, data.days.indices.contains(day) {
                context.stroke(Path(roundedRect: rect(day).insetBy(dx: -1, dy: -1), cornerRadius: 3),
                               with: .color(.primary), lineWidth: 1.25)
            }
        }
        .frame(width: Self.labelWidth + CGFloat(data.weeks) * pitch - Self.gap,
               height: Self.headerHeight + 7 * pitch - Self.gap)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover.set(day: index(at: point))
            case .ended: hover.set(day: nil)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Daily activity for the last \(data.weeks) weeks")
        .accessibilityValue(accessibilitySummary)
    }

    private func rect(_ i: Int) -> CGRect {
        CGRect(x: Self.labelWidth + CGFloat(i / 7) * pitch, y: Self.headerHeight + CGFloat(i % 7) * pitch,
               width: Self.cell, height: Self.cell)
    }

    /// The hit area includes the gaps, so the pointer never falls between cells.
    private func index(at point: CGPoint) -> Int? {
        let x = point.x - Self.labelWidth, y = point.y - Self.headerHeight
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / pitch), row = Int(y / pitch)
        guard row < 7 else { return nil }
        let i = column * 7 + row
        return data.days.indices.contains(i) ? i : nil
    }

    private var accessibilitySummary: String {
        let active = data.days.filter { $0.tokens > 0 || $0.minutes > 0 }
        guard let busiest = active.max(by: { $0.value(data.metric) < $1.value(data.metric) }) else {
            return "No activity"
        }
        return "\(active.count) active days. Busiest: \(Formatters.dayLabel(busiest.date)), "
            + "\(Formatters.tokens(busiest.tokens)) tokens, \(Formatters.duration(minutes: busiest.minutes))."
    }
}

/// Weekday by hour over the last 30 days.
struct HourGrid: View {
    let data: ActivityData
    @ObservedObject var hover: HoverState
    @Environment(\.colorScheme) private var scheme

    static let cellWidth: CGFloat = 12
    static let cellHeight: CGFloat = 10
    static let gap: CGFloat = 2
    static let labelWidth: CGFloat = 26
    static let headerHeight: CGFloat = 13
    private var pitchX: CGFloat { Self.cellWidth + Self.gap }
    private var pitchY: CGFloat { Self.cellHeight + Self.gap }

    var body: some View {
        Canvas { context, _ in
            for hour in stride(from: 0, to: 24, by: 6) {
                context.draw(Text(Formatters.hourLabel(hour)).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: Self.labelWidth + CGFloat(hour) * pitchX, y: 0), anchor: .topLeading)
            }
            for (row, name) in data.hourRowNames.enumerated() {
                context.draw(Text(name).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: 0, y: Self.headerHeight + CGFloat(row) * pitchY + Self.cellHeight / 2),
                             anchor: .leading)
            }
            for i in data.hours.indices {
                context.fill(Path(roundedRect: rect(i), cornerRadius: 2),
                             with: .color(Theme.heat(data.hourLevels[i], scheme)))
            }
            if let cell = hover.hourCell, data.hours.indices.contains(cell) {
                context.stroke(Path(roundedRect: rect(cell).insetBy(dx: -1, dy: -1), cornerRadius: 3),
                               with: .color(.primary), lineWidth: 1.25)
            }
        }
        .frame(width: Self.labelWidth + 24 * pitchX - Self.gap, height: Self.headerHeight + 7 * pitchY - Self.gap)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover.set(hourCell: index(at: point))
            case .ended: hover.set(hourCell: nil)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Activity by weekday and hour, last \(AppModel.hourGridDays) days")
    }

    private func rect(_ i: Int) -> CGRect {
        CGRect(x: Self.labelWidth + CGFloat(i % 24) * pitchX, y: Self.headerHeight + CGFloat(i / 24) * pitchY,
               width: Self.cellWidth, height: Self.cellHeight)
    }

    private func index(at point: CGPoint) -> Int? {
        let x = point.x - Self.labelWidth, y = point.y - Self.headerHeight
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / pitchX), row = Int(y / pitchY)
        guard column < 24, row < 7 else { return nil }
        return row * 24 + column
    }
}

/// One line under the calendar: the hovered day or hour, or today when nothing is hovered.
private struct Readout: View {
    let data: ActivityData
    @ObservedObject var hover: HoverState

    var body: some View {
        line
            .font(.system(size: 11))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
    }

    private var line: Text {
        if let cell = hover.hourCell, data.hours.indices.contains(cell) {
            return hourLine(data.hours[cell])
        }
        if let day = hover.day, data.days.indices.contains(day) {
            return dayLine(data.days[day], isToday: day == data.days.count - 1)
        }
        guard let today = data.days.last else { return Text("") }
        return dayLine(today, isToday: true)
    }

    private func dayLine(_ day: DayStat, isToday: Bool) -> Text {
        let date = Text(isToday ? "Today" : Formatters.dayLabel(day.date)).foregroundColor(.secondary)
        guard day.tokens > 0 || day.minutes > 0 else {
            return date + Text(" · no activity").foregroundColor(.secondary)
        }
        var line = date + separator + strong(Formatters.tokens(day.tokens)) + Text(" tokens").foregroundColor(.secondary)
            + separator + strong(Formatters.duration(minutes: day.minutes))
            + separator + strong(Formatters.money(day.cost))
        if !data.filtered, let top = day.topModel {
            line = line + separator + Text(top).foregroundColor(.secondary)
        }
        return line
    }

    private func hourLine(_ stat: HourStat) -> Text {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        let when = "\(symbols[stat.weekday - 1]) \(Formatters.hourLabel(stat.hour))-\(Formatters.hourLabel((stat.hour + 1) % 24))"
        let value = data.metric == .tokens
            ? strong(Formatters.tokens(stat.tokens)) + Text(" tokens").foregroundColor(.secondary)
            : strong(Formatters.duration(minutes: stat.minutes)) + Text(" active").foregroundColor(.secondary)
        return Text(when).foregroundColor(.secondary) + separator + value
            + Text(" over \(AppModel.hourGridDays) days").foregroundColor(.secondary)
    }

    private var separator: Text { Text(" · ").foregroundColor(.secondary) }

    private func strong(_ text: String) -> Text {
        Text(text).fontWeight(.semibold).foregroundColor(.primary)
    }
}

private struct Legend: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(Theme.heat(level, scheme)).frame(width: 9, height: 9)
            }
            Text("More")
        }
        .accessibilityHidden(true)
    }
}
