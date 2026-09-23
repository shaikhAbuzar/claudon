import Foundation

// MARK: - Model

/// Plan limits as reported by Anthropic: the 5-hour session, weekly windows and extra usage.
public struct LimitsSnapshot: Codable, Sendable, Equatable {
    public var fetchedAt: Date
    public var windows: [LimitWindow]
    public var extra: ExtraUsage?

    public init(fetchedAt: Date, windows: [LimitWindow], extra: ExtraUsage?) {
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.extra = extra
    }

    public var session: LimitWindow? { windows.first { $0.kind == "session" } }
}

public struct LimitWindow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// "session", "weekly_all", "weekly_scoped", ...
    public var kind: String
    /// "Session", "Week · all models", "Week · Fable".
    public var title: String
    public var percent: Double
    public var resetsAt: Date?

    public init(id: String, kind: String, title: String, percent: Double, resetsAt: Date?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.percent = percent
        self.resetsAt = resetsAt
    }

    public func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// Usage right now: a window whose reset time has passed starts again from zero.
    public func percent(at now: Date) -> Double {
        hasReset(at: now) ? 0 : percent
    }
}

public struct ExtraUsage: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// In currency units.
    public var used: Double
    public var limit: Double?
    public var currency: String
    public var percent: Double?

    public init(isEnabled: Bool, used: Double, limit: Double?, currency: String, percent: Double?) {
        self.isEnabled = isEnabled
        self.used = used
        self.limit = limit
        self.currency = currency
        self.percent = percent
    }
}

public enum UsageLevel: Int, Comparable, Sendable {
    case normal, warning, critical

    public init(percent: Double) {
        self = percent >= 95 ? .critical : percent >= 80 ? .warning : .normal
    }

    public static func < (lhs: UsageLevel, rhs: UsageLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Parsing

public enum LimitsError: Error, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse
    case network(String)
}

public enum LimitsParser {
    /// Parses the body of `GET /api/oauth/usage`. Reads the `limits` list when present and
    /// falls back to the older `five_hour` / `seven_day` fields.
    public static func parse(_ data: Data, fetchedAt: Date) throws -> LimitsSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.badResponse
        }
        var windows: [LimitWindow] = []
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            for item in limits {
                guard let kind = item["kind"] as? String, let percent = number(item["percent"]) else { continue }
                let scope = scopeName(item["scope"])
                windows.append(LimitWindow(id: scope.map { "\(kind):\($0)" } ?? kind, kind: kind,
                                           title: title(kind: kind, scope: scope), percent: percent,
                                           resetsAt: date(item["resets_at"])))
            }
        } else {
            let legacy: [(field: String, kind: String, scope: String?)] = [
                ("five_hour", "session", nil),
                ("seven_day", "weekly_all", nil),
                ("seven_day_opus", "weekly_scoped", "Opus"),
                ("seven_day_sonnet", "weekly_scoped", "Sonnet"),
            ]
            for entry in legacy {
                guard let item = root[entry.field] as? [String: Any], let percent = number(item["utilization"]) else {
                    continue
                }
                windows.append(LimitWindow(id: entry.scope.map { "\(entry.kind):\($0)" } ?? entry.kind,
                                           kind: entry.kind, title: title(kind: entry.kind, scope: entry.scope),
                                           percent: percent, resetsAt: date(item["resets_at"])))
            }
        }
        let extra = spend(root["spend"]) ?? extraUsage(root["extra_usage"])
        return LimitsSnapshot(fetchedAt: fetchedAt, windows: windows, extra: extra)
    }

    static func title(kind: String, scope: String?) -> String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Week · all models"
        case "weekly_scoped": return "Week · \(scope ?? "limited")"
        default:
            var words = kind.split(separator: "_").map(String.init)
            if words.first == "weekly" { words[0] = "week" }
            if words.first == "daily" { words[0] = "day" }
            let base = words.joined(separator: " ")
            let label = base.prefix(1).uppercased() + base.dropFirst()
            return scope.map { "\(label) · \($0)" } ?? label
        }
    }

    private static func scopeName(_ value: Any?) -> String? {
        guard let scope = value as? [String: Any] else { return nil }
        for key in ["model", "surface"] {
            if let text = scope[key] as? String, !text.isEmpty { return text }
            if let object = scope[key] as? [String: Any] {
                for field in ["display_name", "name", "id"] {
                    if let text = object[field] as? String, !text.isEmpty { return text }
                }
            }
        }
        return nil
    }

    private static func spend(_ value: Any?) -> ExtraUsage? {
        guard let spend = value as? [String: Any], let used = money(spend["used"]) else { return nil }
        let limit = money(spend["limit"])
        let percent = number(spend["percent"])
            ?? limit.flatMap { $0.amount > 0 ? used.amount / $0.amount * 100 : nil }
        return ExtraUsage(isEnabled: spend["enabled"] as? Bool ?? true, used: used.amount, limit: limit?.amount,
                          currency: used.currency ?? limit?.currency ?? "USD", percent: percent)
    }

    private static func extraUsage(_ value: Any?) -> ExtraUsage? {
        guard let extra = value as? [String: Any], let enabled = extra["is_enabled"] as? Bool else { return nil }
        let scale = pow(10, number(extra["decimal_places"]) ?? 2)
        return ExtraUsage(isEnabled: enabled, used: (number(extra["used_credits"]) ?? 0) / scale,
                          limit: number(extra["monthly_limit"]).map { $0 / scale },
                          currency: extra["currency"] as? String ?? "USD", percent: number(extra["utilization"]))
    }

    private static func money(_ value: Any?) -> (amount: Double, currency: String?)? {
        guard let money = value as? [String: Any], let minor = number(money["amount_minor"]) else { return nil }
        let exponent = number(money["exponent"]) ?? 2
        return (minor / pow(10, exponent), money["currency"] as? String)
    }

    /// A JSON number as Double. JSON booleans also arrive as NSNumber, so they are ruled out.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap(Timestamp.date)
    }
}

// MARK: - Fetching

public struct LimitsClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func fetch(accessToken: String, now: Date = Date()) async throws -> LimitsSnapshot {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Claudon/\(ClaudonInfo.version)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LimitsError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LimitsError.badResponse }
        switch http.statusCode {
        case 200:
            return try LimitsParser.parse(data, fetchedAt: now)
        case 401, 403:
            throw LimitsError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw LimitsError.rateLimited(retryAfter: retryAfter)
        default:
            throw LimitsError.http(http.statusCode)
        }
    }
}

public struct OAuthCredentials: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// "Pro", "Max 20x", "Team · Max 5x".
    public var planLabel: String? {
        var multiplier: String?
        if let tier = rateLimitTier?.lowercased(),
           let match = tier.range(of: #"max_\d+x"#, options: .regularExpression) {
            multiplier = "Max " + tier[match].dropFirst(4)
        }
        let plan = subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        switch (plan, multiplier) {
        case let (plan?, multiplier?): return plan == "Max" ? multiplier : "\(plan) · \(multiplier)"
        case let (plan?, nil): return plan
        case let (nil, multiplier?): return multiplier
        case (nil, nil): return nil
        }
    }
}

/// Reads the login that Claude Code keeps for itself. Claudon only reads it: it never
/// refreshes or rewrites the token.
public enum ClaudeCredentials {
    public static let keychainService = "Claude Code-credentials"

    public static func load() -> OAuthCredentials? {
        if let data = readKeychain(), let credentials = parse(data) { return credentials }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let credentials = parse(data) { return credentials }
        return nil
    }

    /// Goes through /usr/bin/security, the tool Claude Code writes the item with, so macOS
    /// doesn't ask for keychain access again.
    static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    public static func parse(_ data: Data) -> OAuthCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = LimitsParser.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return OAuthCredentials(accessToken: token, expiresAt: expiresAt,
                                subscriptionType: oauth["subscriptionType"] as? String,
                                rateLimitTier: oauth["rateLimitTier"] as? String)
    }
}

// MARK: - Menu bar

public struct MenuBarSummary: Equatable, Sendable {
    public var text: String
    public var level: UsageLevel

    /// "17% · 4h 39m" for the session. A used-up weekly limit blocks everything,
    /// so it takes the session's place until it resets.
    public static func make(from snapshot: LimitsSnapshot?, now: Date) -> MenuBarSummary? {
        guard let snapshot, !snapshot.windows.isEmpty else { return nil }
        let blocking = snapshot.windows.first { $0.kind != "session" && $0.percent(at: now) >= 100 }
        let window = blocking ?? snapshot.session ?? snapshot.windows[0]
        let percent = window.percent(at: now)
        var text = Formatters.percent(percent)
        if let resetsAt = window.resetsAt, resetsAt > now {
            text += " · " + Formatters.countdown(resetsAt.timeIntervalSince(now))
        }
        if blocking != nil { text = "Week " + text }
        return MenuBarSummary(text: text, level: UsageLevel(percent: percent))
    }
}

// MARK: - Alerts

public struct LimitAlert: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    /// Remembered once sent, so each threshold fires once per window.
    public var keys: [String]
}

public struct ResetReminder: Equatable, Sendable {
    public var date: Date
    public var title: String
    public var body: String
}

public enum AlertPlanner {
    public static let thresholds = [80, 95]

    /// Alerts for limits that crossed 80% or 95% and haven't been announced for this window.
    public static func alerts(for snapshot: LimitsSnapshot, now: Date, sent: Set<String>,
                              calendar: Calendar = .current) -> [LimitAlert] {
        var alerts: [LimitAlert] = []
        for window in snapshot.windows {
            // Reset times jitter by milliseconds between responses; the hour is stable.
            let period = window.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 3600).rounded())) } ?? "open"
            let percent = window.percent(at: now)
            if let alert = alert(id: window.id, percent: percent, period: period, sent: sent, title: { threshold in
                "\(window.title) at \(Formatters.percent(percent))"
            }, body: { threshold in
                let reset = window.resetsAt.map {
                    "Resets in \(Formatters.countdown($0.timeIntervalSince(now))) (\(Formatters.resetClock($0, now: now)))."
                } ?? ""
                return threshold >= 95 ? "Almost at the limit. \(reset)" : reset
            }) {
                alerts.append(alert)
            }
        }
        if let extra = snapshot.extra, extra.isEnabled, let percent = extra.percent {
            let month = calendar.dateComponents([.year, .month], from: now)
            let period = "\(month.year ?? 0)-\(month.month ?? 0)"
            if let alert = alert(id: "extra", percent: percent, period: period, sent: sent, title: { _ in
                "Extra usage at \(Formatters.percent(percent))"
            }, body: { _ in
                let used = Formatters.money(extra.used, currency: extra.currency)
                guard let limit = extra.limit else { return "\(used) used this month." }
                return "\(used) of \(Formatters.money(limit, currency: extra.currency)) used this month."
            }) {
                alerts.append(alert)
            }
        }
        return alerts
    }

    private static func alert(id: String, percent: Double, period: String, sent: Set<String>,
                              title: (Int) -> String, body: (Int) -> String) -> LimitAlert? {
        let crossed = thresholds.filter { percent >= Double($0) }
        guard let highest = crossed.max() else { return nil }
        let keys = crossed.map { "\(id)|\($0)|\(period)" }
        guard !sent.contains("\(id)|\(highest)|\(period)") else { return nil }
        return LimitAlert(id: "claudon.\(id).\(highest).\(period)", title: title(highest), body: body(highest),
                          keys: keys)
    }

    /// A reminder for when the session resets, scheduled only if the session got close to its limit.
    public static func sessionResetReminder(for snapshot: LimitsSnapshot, now: Date) -> ResetReminder? {
        guard let session = snapshot.session, let resetsAt = session.resetsAt, resetsAt > now,
              session.percent >= Double(thresholds[0]) else { return nil }
        return ResetReminder(date: resetsAt, title: "Session reset",
                             body: "Your 5-hour session limit is available again.")
    }
}
