import AppKit
import ClaudonCore
import Combine

/// Everything the menu bar item and the popover show, and the timers that keep it fresh.
@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable { case activity, models, projects }
    enum Range: String, CaseIterable { case week, month, all }

    enum LimitsProblem: Equatable {
        case signedOut, expired, rejected, rateLimited, offline
        case server(Int)
    }

    struct Overview: Equatable {
        var today = PeriodSummary.empty
        var week = PeriodSummary.empty
        var month = PeriodSummary.empty
    }

    static let calendarWeeks = 26
    static let hourGridDays = 30
    /// Plan limits change slowly; checking every few minutes keeps well clear of rate limits.
    static let limitsInterval: TimeInterval = 180
    static let scanInterval: TimeInterval = 30

    // Limits
    @Published private(set) var limits: LimitsSnapshot?
    @Published private(set) var limitsProblem: LimitsProblem?
    @Published private(set) var plan: String?
    @Published private(set) var isFetchingLimits = false

    // Local usage
    @Published private(set) var usageLoaded = false
    @Published private(set) var isScanning = false
    @Published private(set) var activity: ActivityData?
    @Published private(set) var overview = Overview()
    @Published private(set) var modelRows: [ShareRow] = []
    @Published private(set) var projectRows: [ShareRow] = []
    @Published private(set) var modelOptions: [String] = []
    @Published private(set) var transcriptCount = 0
    @Published private(set) var lastScanAt: Date?

    /// Ticks every 20 seconds so countdowns stay current.
    @Published private(set) var now = Date()

    // View choices, remembered between launches
    @Published var metric: Metric {
        didSet { defaults.set(metric.rawValue, forKey: Keys.metric); rebuildActivity() }
    }
    @Published var modelFilter: String? {
        didSet { defaults.set(modelFilter, forKey: Keys.modelFilter); rebuildActivity() }
    }
    @Published var tab: Tab {
        didSet { defaults.set(tab.rawValue, forKey: Keys.tab) }
    }
    @Published var range: Range {
        didSet { defaults.set(range.rawValue, forKey: Keys.range); rebuildBreakdown() }
    }

    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var launchAtLogin = false

    let hover = HoverState()

    private let defaults: UserDefaults
    private let index: TranscriptIndex?
    private let indexQueue = DispatchQueue(label: "app.claudon.index", qos: .utility)
    private let client = LimitsClient()
    private let notifier: Notifier?
    private let widget: WidgetPublisher?
    private var aggregator: UsageAggregator?
    private var credentials: OAuthCredentials?
    private var credentialsReadAt = Date.distantPast
    private var nextLimitsFetch = Date.distantPast
    private var backoff: TimeInterval = 0
    private var lastSave = Date()
    private var builtForDay: Date?
    private var ticker: Timer?
    private var wakeObserver: NSObjectProtocol?

    private enum Keys {
        static let metric = "metric"
        static let modelFilter = "modelFilter"
        static let tab = "tab"
        static let range = "range"
        static let notifications = "notificationsEnabled"
        static let lastLimits = "lastLimits"
        static let plan = "plan"
    }

    init(index: TranscriptIndex?, notifier: Notifier?, widget: WidgetPublisher? = nil,
         defaults: UserDefaults = .standard) {
        self.index = index
        self.notifier = notifier
        self.widget = widget
        self.defaults = defaults
        metric = Metric(rawValue: defaults.string(forKey: Keys.metric) ?? "") ?? .tokens
        modelFilter = defaults.string(forKey: Keys.modelFilter)
        tab = Tab(rawValue: defaults.string(forKey: Keys.tab) ?? "") ?? .activity
        range = Range(rawValue: defaults.string(forKey: Keys.range) ?? "") ?? .month
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        plan = defaults.string(forKey: Keys.plan)
        if let data = defaults.data(forKey: Keys.lastLimits),
           let saved = try? JSONDecoder().decode(LimitsSnapshot.self, from: data) {
            limits = saved
        }
    }

    // MARK: Lifecycle

    func start() {
        launchAtLogin = LoginItem.isEnabled
        notifier?.setUp(enabled: notificationsEnabled)
        scanUsage()
        refreshLimits(force: true)
        ticker = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker?.tolerance = 5
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll(force: true) }
        }
    }

    func popoverWillOpen() {
        now = Date()
        hover.clear()
        launchAtLogin = LoginItem.isEnabled
        scanUsage()
        let fresh = limits.map { now.timeIntervalSince($0.fetchedAt) < 60 } ?? false
        if !fresh || limitsProblem != nil { refreshLimits(force: backoff == 0) }
    }

    func refreshAll(force: Bool) {
        now = Date()
        scanUsage()
        refreshLimits(force: force && backoff == 0)
    }

    func saveNow() {
        guard let index else { return }
        indexQueue.sync { try? index.save() }
    }

    private func tick() {
        now = Date()
        if let day = builtForDay, !Calendar.current.isDate(day, inSameDayAs: now) { rebuildAll() }
        if now >= nextLimitsFetch { refreshLimits() }
        if lastScanAt.map({ now.timeIntervalSince($0) >= Self.scanInterval }) ?? true { scanUsage() }
        if now.timeIntervalSince(lastSave) > 60, let index {
            lastSave = now
            indexQueue.async { try? index.save() }
        }
    }

    // MARK: Settings

    func setNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: Keys.notifications)
        notifier?.setEnabled(enabled, snapshot: limits)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    var canNotify: Bool { notifier != nil }

    // MARK: Limits

    func refreshLimits(force: Bool = false) {
        guard !isFetchingLimits, force || Date() >= nextLimitsFetch else { return }
        isFetchingLimits = true
        Task {
            await fetchLimits()
            isFetchingLimits = false
            publishWidget()
        }
    }

    private func fetchLimits() async {
        guard let first = await loadCredentials(reload: false) else {
            limitsProblem = .signedOut
            retry(after: 300)
            return
        }
        plan = first.planLabel
        defaults.set(plan, forKey: Keys.plan)
        do {
            apply(try await client.fetch(accessToken: first.accessToken))
        } catch LimitsError.unauthorized {
            // Claude Code may have renewed its login since Claudon last read it.
            if let fresh = await loadCredentials(reload: true), fresh.accessToken != first.accessToken,
               let snapshot = try? await client.fetch(accessToken: fresh.accessToken) {
                apply(snapshot)
                return
            }
            limitsProblem = (credentials?.isExpired(at: Date()) ?? false) ? .expired : .rejected
            retry(after: 120)
        } catch LimitsError.rateLimited(let retryAfter) {
            backoff = min(max(backoff * 2, 300), 1800)
            limitsProblem = .rateLimited
            retry(after: max(retryAfter ?? 0, backoff))
        } catch LimitsError.http(let code) {
            limitsProblem = .server(code)
            retry(after: Self.limitsInterval)
        } catch {
            limitsProblem = .offline
            retry(after: 60)
        }
    }

    private func loadCredentials(reload: Bool) async -> OAuthCredentials? {
        let stale = Date().timeIntervalSince(credentialsReadAt) > 1800
        if reload || stale || credentials == nil || credentials?.isExpired(at: Date()) == true {
            credentials = await Task.detached(priority: .utility) { ClaudeCredentials.load() }.value
            credentialsReadAt = Date()
        }
        return credentials
    }

    private func apply(_ snapshot: LimitsSnapshot) {
        limits = snapshot
        limitsProblem = nil
        backoff = 0
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Keys.lastLimits) }
        var next = Date().addingTimeInterval(Self.limitsInterval)
        // Check again just after a window resets, so the menu bar doesn't show a stale number.
        if let reset = snapshot.windows.compactMap(\.resetsAt).filter({ $0 > Date() }).min(),
           reset.addingTimeInterval(5) < next {
            next = reset.addingTimeInterval(5)
        }
        nextLimitsFetch = next
        notifier?.process(snapshot, now: Date(), enabled: notificationsEnabled)
    }

    private func retry(after seconds: TimeInterval) {
        nextLimitsFetch = Date().addingTimeInterval(seconds)
    }

    // MARK: Local usage

    func scanUsage() {
        guard let index, !isScanning else { return }
        isScanning = true
        let firstLoad = !usageLoaded
        let calendar = Calendar.current
        let queue = indexQueue
        Task {
            let result: (UsageAggregator?, Int) = await withCheckedContinuation { continuation in
                queue.async {
                    let changed = index.scan()
                    let aggregator = changed || firstLoad
                        ? UsageAggregator(rollup: index.snapshot(), calendar: calendar) : nil
                    continuation.resume(returning: (aggregator, index.fileCount))
                }
            }
            isScanning = false
            lastScanAt = Date()
            if let aggregator = result.0 { load(aggregator) }
            transcriptCount = result.1
        }
    }

    /// Shows a prepared aggregator; also used for snapshots and demo data.
    func load(_ aggregator: UsageAggregator) {
        self.aggregator = aggregator
        transcriptCount = aggregator.rollup.transcriptCount
        usageLoaded = true
        rebuildAll()
    }

    func load(limits snapshot: LimitsSnapshot?, plan: String?) {
        limits = snapshot
        self.plan = plan
    }

    private func rebuildAll() {
        now = Date()
        builtForDay = now
        guard let aggregator else { return }
        modelOptions = aggregator.groupsByUsage
        if let filter = modelFilter, !modelOptions.contains(filter) { modelFilter = nil }
        let calendar = aggregator.calendar
        let today = calendar.startOfDay(for: now)
        func start(daysBack days: Int) -> Date {
            calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        }
        overview = Overview(today: aggregator.summary(from: today, to: now),
                            week: aggregator.summary(from: start(daysBack: 7), to: now),
                            month: aggregator.summary(from: start(daysBack: 30), to: now))
        rebuildActivity()
        rebuildBreakdown()
    }

    private func rebuildActivity() {
        guard let aggregator else {
            activity = nil
            return
        }
        let group = modelFilter.flatMap(aggregator.groupIndex(named:))
        activity = activityData(aggregator, group: group)
        publishWidget()
    }

    private func activityData(_ aggregator: UsageAggregator, group: Int?) -> ActivityData {
        ActivityData(days: aggregator.days(weeks: Self.calendarWeeks, group: group, now: now),
                     hours: aggregator.hours(days: Self.hourGridDays, group: group, now: now),
                     metric: metric, filtered: group != nil, calendar: aggregator.calendar)
    }

    /// The widget shows all models with the popover's metric, whatever the model filter.
    private func publishWidget() {
        guard let widget, let aggregator else { return }
        let data = modelFilter == nil ? activity : nil
        widget.publish(widgetSnapshot(data ?? activityData(aggregator, group: nil)))
    }

    func widgetSnapshot(_ data: ActivityData) -> WidgetSnapshot {
        func totals(_ summary: PeriodSummary) -> WidgetSnapshot.Totals {
            .init(tokens: summary.tokens, minutes: summary.minutes, cost: summary.cost)
        }
        return WidgetSnapshot(generatedAt: Date(), limits: limits, limitsStale: limitsProblem != nil,
                              metric: data.metric, today: totals(overview.today), week: totals(overview.week),
                              dayLevels: data.dayLevels,
                              monthLabels: data.monthLabels.map { .init(column: $0.id, text: $0.text) },
                              hourLevels: data.hourLevels, hourRowNames: data.hourRowNames)
    }

    private func rebuildBreakdown() {
        guard let aggregator else { return }
        let calendar = aggregator.calendar
        let today = calendar.startOfDay(for: now)
        let since: Date? = switch range {
        case .week: calendar.date(byAdding: .day, value: -6, to: today)
        case .month: calendar.date(byAdding: .day, value: -29, to: today)
        case .all: nil
        }
        modelRows = aggregator.modelShares(since: since, now: now)
        projectRows = aggregator.projectShares(since: since, now: now)
    }

    var footerText: String {
        var parts: [String] = []
        if let limits { parts.append("Limits updated \(Formatters.clock(limits.fetchedAt))") }
        if usageLoaded { parts.append("\(transcriptCount) transcripts") }
        return parts.joined(separator: " · ")
    }
}

/// Which heatmap cell the pointer is over. Kept apart from `AppModel` so hovering redraws only
/// the grids and the readout.
@MainActor
final class HoverState: ObservableObject {
    @Published private(set) var day: Int?
    @Published private(set) var hourCell: Int?

    func set(day: Int?) {
        if self.day != day { self.day = day }
        if day != nil, hourCell != nil { hourCell = nil }
    }

    func set(hourCell: Int?) {
        if self.hourCell != hourCell { self.hourCell = hourCell }
        if hourCell != nil, day != nil { day = nil }
    }

    func clear() {
        set(day: nil)
        set(hourCell: nil)
    }
}

/// Heatmap data prepared for drawing.
struct ActivityData {
    struct Label: Identifiable {
        let id: Int
        let text: String
    }

    let days: [DayStat]
    let hours: [HourStat]
    let metric: Metric
    let filtered: Bool
    let weeks: Int
    let dayLevels: [Int]
    let hourLevels: [Int]
    /// Month names keyed by the calendar column where each month starts.
    let monthLabels: [Label]
    /// Calendar rows that get a weekday label, GitHub style.
    let weekdayLabels: [Label]
    /// Row names for the hour grid.
    let hourRowNames: [String]

    init(days: [DayStat], hours: [HourStat], metric: Metric, filtered: Bool, calendar: Calendar) {
        self.days = days
        self.hours = hours
        self.metric = metric
        self.filtered = filtered
        weeks = max(1, (days.count + 6) / 7)
        let dayScale = QuantileScale(values: days.map { $0.value(metric) })
        dayLevels = days.map { dayScale.level($0.value(metric)) }
        let hourScale = QuantileScale(values: hours.map { $0.value(metric) })
        hourLevels = hours.map { hourScale.level($0.value(metric)) }

        let monthFormatter = DateFormatter()
        monthFormatter.setLocalizedDateFormatFromTemplate("MMM")
        var candidates: [Label] = []
        var lastMonth = -1
        for column in 0..<weeks where column * 7 < days.count {
            let month = calendar.component(.month, from: days[column * 7].date)
            if month != lastMonth {
                candidates.append(Label(id: column, text: monthFormatter.string(from: days[column * 7].date)))
                lastMonth = month
            }
        }
        // Drop a label that would collide with the next one, like a short first month.
        monthLabels = candidates.enumerated().compactMap { i, label in
            i + 1 < candidates.count && candidates[i + 1].id - label.id < 3 ? nil : label
        }

        let symbols = calendar.shortStandaloneWeekdaySymbols
        var labels: [Label] = []
        var names: [String] = []
        for row in 0..<7 {
            let weekday = (calendar.firstWeekday - 1 + row) % 7 + 1
            names.append(symbols[weekday - 1])
            if [2, 4, 6].contains(weekday) { labels.append(Label(id: row, text: symbols[weekday - 1])) }
        }
        weekdayLabels = labels
        hourRowNames = names
    }
}
