import ClaudonCore
import SwiftUI

struct LimitsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let limits = model.limits, !limits.windows.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(limits.windows) { window in
                        LimitRow(window: window, now: model.now)
                    }
                    if let extra = limits.extra, extra.isEnabled {
                        ExtraUsageRow(extra: extra)
                    }
                }
                // Values from an earlier check stay visible, dimmed, while there's a problem.
                .opacity(model.limitsProblem == nil ? 1 : 0.55)
            } else if model.limitsProblem == nil {
                Text("Checking your plan limits…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if let problem = model.limitsProblem {
                ProblemNote(problem: problem, lastChecked: model.limits?.fetchedAt) {
                    model.refreshLimits(force: true)
                }
            }
        }
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 12)
    }
}

private struct LimitRow: View {
    let window: LimitWindow
    let now: Date

    var body: some View {
        let percent = window.percent(at: now)
        let level = UsageLevel(percent: percent)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(.system(size: 12, weight: .medium))
                Text(resetText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusIcon(level: level)
                Text(Formatters.percent(percent))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            Meter(fraction: percent / 100, color: Theme.status(level))
        }
        .accessibilityElement(children: .combine)
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else { return "" }
        guard resetsAt > now else { return "reset, updating" }
        return "resets in \(Formatters.countdown(resetsAt.timeIntervalSince(now))) · "
            + Formatters.resetClock(resetsAt, now: now)
    }
}

private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        let percent = extra.percent ?? 0
        let level = UsageLevel(percent: percent)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Extra usage")
                    .font(.system(size: 12, weight: .medium))
                Text(amountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if extra.percent != nil {
                    StatusIcon(level: level)
                    Text(Formatters.percent(percent))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
            }
            if extra.limit != nil {
                Meter(fraction: percent / 100, color: Theme.status(level))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var amountText: String {
        let used = Formatters.money(extra.used, currency: extra.currency, exact: true)
        guard let limit = extra.limit else { return "\(used) this month" }
        return "\(used) of \(Formatters.money(limit, currency: extra.currency, exact: true)) this month"
    }
}

/// The warning and critical states get a symbol too, so the color never works alone.
private struct StatusIcon: View {
    let level: UsageLevel

    var body: some View {
        switch level {
        case .normal:
            EmptyView()
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.status(.warning))
                .accessibilityLabel("Warning")
        case .critical:
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.status(.critical))
                .accessibilityLabel("Near the limit")
        }
    }
}

private struct ProblemNote: View {
    let problem: AppModel.LimitsProblem
    let lastChecked: Date?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                if let lastChecked {
                    Text("Showing the values from \(Formatters.resetClock(lastChecked, now: Date())).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if problem != .signedOut {
                Button("Retry", action: retry)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
            }
        }
    }

    private var message: String {
        switch problem {
        case .signedOut: "Sign in to Claude Code to see plan limits: run `claude`, then /login."
        case .expired: "Your Claude Code login has expired. Run `claude` once to renew it."
        case .rejected: "Anthropic didn't accept the Claude Code login. Run `claude` and sign in again."
        case .rateLimited: "Anthropic is limiting usage checks right now. Claudon will retry in a few minutes."
        case .offline: "Can't reach Anthropic right now."
        case .server(let code): "Anthropic's usage service returned an error (\(code))."
        }
    }
}
