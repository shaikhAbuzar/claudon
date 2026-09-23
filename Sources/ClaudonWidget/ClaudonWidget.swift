import ClaudonCore
import ClaudonUI
import SwiftUI
import WidgetKit

@main
struct ClaudonWidgets: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

struct UsageWidget: Widget {
    /// Matches `WidgetPublisher.kind` in the app, which reloads it.
    let kind = "ClaudonUsage"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Claude Usage")
        .description("Your session limit, weekly limits and Claude Code activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct UsageEntryView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        UsageWidgetView(snapshot: entry.snapshot, now: entry.date, size: size)
    }

    private var size: WidgetSize {
        switch family {
        case .systemSmall: .small
        case .systemLarge, .systemExtraLarge: .large
        default: .medium
        }
    }
}

/// Reads the file the app writes. Entries every two minutes keep countdowns current and show a
/// window as reset once its time passes, without waking the app.
struct UsageProvider: TimelineProvider {
    private static let step: TimeInterval = 120
    private static let steps = 30

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .preview(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let now = Date()
        let saved = WidgetSnapshot.load()
        completion(UsageEntry(date: now, snapshot: saved ?? (context.isPreview ? .preview(now: now) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let entries = (0..<Self.steps).map {
            UsageEntry(date: now.addingTimeInterval(Double($0) * Self.step), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}
