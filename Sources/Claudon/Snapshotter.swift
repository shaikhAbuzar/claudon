import AppKit
import ClaudonCore
import ClaudonUI
import SwiftUI

/// `Claudon --snapshot <folder> [--demo]` renders the popover to PNG files, for checking
/// layouts and for screenshots. `--demo` swaps in made-up data.
@MainActor
final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    private let output: URL
    private let demo: Bool

    init(output: URL, demo: Bool) {
        self.output = output
        self.demo = demo
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let status = await Snapshotter.run(to: output, demo: demo)
            exit(status)
        }
    }
}

@MainActor
enum Snapshotter {
    static func run(to directory: URL, demo: Bool) async -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Couldn't create \(directory.path): \(error)")
            return 1
        }
        let suite = "app.claudon.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        let model = AppModel(index: nil, notifier: nil, defaults: UserDefaults(suiteName: suite) ?? .standard)
        let now = Date()
        if demo {
            model.load(UsageAggregator(rollup: DemoData.rollup(now: now), calendar: .current))
            model.load(limits: DemoData.limits(now: now), plan: "Max 5x")
        } else {
            // Real data, read into a throwaway state file so the app's own copy isn't touched.
            let stateURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudon-snapshot-\(UUID().uuidString).json")
            let index = TranscriptIndex(stateURL: stateURL)
            let started = Date()
            index.scan()
            print("Read \(index.fileCount) transcripts in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            model.load(UsageAggregator(rollup: index.snapshot(), calendar: .current))
            let credentials = ClaudeCredentials.load()
            var limits: LimitsSnapshot?
            if let credentials {
                do {
                    limits = try await LimitsClient().fetch(accessToken: credentials.accessToken)
                } catch {
                    print("Limits: \(error)")
                }
            }
            model.load(limits: limits, plan: credentials?.planLabel)
        }

        for tab in AppModel.Tab.allCases {
            model.tab = tab
            for scheme in [ColorScheme.light, .dark] {
                let view = PopoverView(model: model, hover: model.hover)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.965))
                    .environment(\.colorScheme, scheme)
                    .environment(\.isSnapshot, true)
                let name = "popover-\(tab.rawValue)-\(scheme == .dark ? "dark" : "light").png"
                write(view, to: directory.appendingPathComponent(name))
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            let summary = MenuBarSummary.make(from: model.limits, now: now)
            let bar = MenuBarPreview(text: summary?.text ?? "", stage: summary?.stage)
                .environment(\.colorScheme, scheme)
            write(bar, to: directory.appendingPathComponent("menubar-\(scheme == .dark ? "dark" : "light").png"))
        }
        for scheme in [ColorScheme.light, .dark] {
            write(StagesPreview().environment(\.colorScheme, scheme),
                  to: directory.appendingPathComponent("stages-\(scheme == .dark ? "dark" : "light").png"))
        }
        if let activity = model.activity {
            let snapshot = model.widgetSnapshot(activity)
            for scheme in [ColorScheme.light, .dark] {
                write(WidgetsPreview(snapshot: snapshot, now: now).environment(\.colorScheme, scheme),
                      to: directory.appendingPathComponent("widgets-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        if let icon = ClaudonArt.pngData(pixels: 512, draw: { ClaudonArt.drawIcon(in: $0, size: 512) }) {
            try? icon.write(to: directory.appendingPathComponent("icon.png"))
        }
        print("Wrote snapshots to \(directory.path)")
        return 0
    }

    private static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("Couldn't render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}

/// A stand-in for the menu bar item, for screenshots.
private struct MenuBarPreview: View {
    let text: String
    let stage: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            if let stage {
                Image(nsImage: ClaudonArt.menuBarGlyph(stage: stage, dark: scheme == .dark))
            } else {
                Image(nsImage: ClaudonArt.menuBarGlyph())
                    .renderingMode(.template)
            }
            Text(text)
                .font(.system(size: 13).monospacedDigit())
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.93))
    }
}

/// Every menu bar stage side by side, for screenshots.
private struct StagesPreview: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<ClaudonArt.stageColors.count, id: \.self) { stage in
                VStack(spacing: 4) {
                    Image(nsImage: ClaudonArt.menuBarGlyph(stage: stage, dark: scheme == .dark))
                    Text("\(stage * 10)%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.93))
    }
}

/// The widget at each size, laid out like a desktop, for screenshots. Sizes and margins follow
/// macOS desktop widgets.
private struct WidgetsPreview: View {
    let snapshot: WidgetSnapshot
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                tile(.small, width: 164, height: 164)
                tile(.medium, width: 344, height: 164)
            }
            tile(.large, width: 344, height: 344)
        }
        .padding(20)
        .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.85))
    }

    private func tile(_ size: WidgetSize, width: CGFloat, height: CGFloat) -> some View {
        UsageWidgetView(snapshot: snapshot, now: now, size: size)
            .padding(16)
            .frame(width: width, height: height)
            .background(scheme == .dark ? Color(white: 0.17) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Made-up usage for screenshots and trying the UI.
enum DemoData {
    static func rollup(now: Date, calendar: Calendar = .current) -> UsageRollup {
        var random = SplitMix64(seed: 42)
        let models = ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
        let modelWeights = [0.5, 0.3, 0.15, 0.05]
        let projects = [("website", 0.34), ("mobile-app", 0.25), ("api-server", 0.2), ("notes", 0.12), ("cli-tools", 0.09)]

        struct MinuteKey: Hashable { let day: Int32; let model: Int32 }
        var buckets: [BucketKey: TokenCounts] = [:]
        var minutes: [MinuteKey: MinuteSet] = [:]
        let today = calendar.startOfDay(for: now)
        for back in 0..<150 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            if random.unit() < (weekend ? 0.6 : 0.1) { continue }
            let intensity = (weekend ? 0.4 : 1.0) * (0.5 + random.unit())
            for (startHour, hours, chance) in [(9.5, 2.5, 0.85), (13.5, 3.5, 0.85), (20.0, 2.0, 0.35)]
            where random.unit() < chance {
                let model = pick(modelWeights, &random)
                let project = pick(projects.map(\.1), &random)
                var time = day.addingTimeInterval(startHour * 3600)
                let end = time.addingTimeInterval(hours * 3600 * (0.5 + random.unit() * 0.5))
                while time < end, time < now {
                    let scale = intensity * (0.6 + random.unit())
                    let key = BucketKey(quarter: Int32(time.timeIntervalSince1970 / 900), model: Int32(model),
                                        project: Int32(project))
                    buckets[key, default: .zero] += TokenCounts(
                        input: Int64(40 * scale), output: Int64(900 * scale), cacheWrite5m: Int64(3000 * scale),
                        cacheWrite1h: 0, cacheRead: Int64(60_000 * scale), messages: 1)
                    let minute = Int(time.timeIntervalSince1970 / 60)
                    for m in minute..<(minute + TranscriptIndex.activityWindowMinutes) {
                        minutes[MinuteKey(day: Int32(m / 1440), model: Int32(model)), default: MinuteSet()]
                            .insert(m % 1440)
                    }
                    time = time.addingTimeInterval(60 + random.unit() * 180)
                }
            }
        }
        return UsageRollup(
            models: models,
            projects: projects.map { ProjectInfo(folder: "-demo-\($0.0)", name: $0.0, nameQuality: 2) },
            buckets: buckets.map { UsageRollup.Bucket(key: $0.key, counts: $0.value) },
            minutes: minutes.map { UsageRollup.Minutes(day: $0.key.day, model: $0.key.model, set: $0.value) },
            lastActivity: now, transcriptCount: 214)
    }

    static func limits(now: Date) -> LimitsSnapshot {
        let weekReset = now.addingTimeInterval(3 * 86_400 + 5 * 3600)
        return LimitsSnapshot(fetchedAt: now, windows: [
            LimitWindow(id: "session", kind: "session", title: "Session", percent: 42,
                        resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
            LimitWindow(id: "weekly_all", kind: "weekly_all", title: "Week · all models", percent: 61, resetsAt: weekReset),
            LimitWindow(id: "weekly_scoped:Fable", kind: "weekly_scoped", title: "Week · Fable", percent: 83,
                        resetsAt: weekReset),
        ], extra: ExtraUsage(isEnabled: true, used: 12.4, limit: 50, currency: "USD", percent: 24.8))
    }

    private static func pick(_ weights: [Double], _ random: inout SplitMix64) -> Int {
        var roll = random.unit() * weights.reduce(0, +)
        for (i, weight) in weights.enumerated() {
            roll -= weight
            if roll < 0 { return i }
        }
        return weights.count - 1
    }
}

/// Small deterministic generator, so demo screenshots come out the same every time.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
