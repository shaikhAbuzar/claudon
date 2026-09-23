import ClaudonCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hover: HoverState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(model: model)
            Divider()
            LimitsSection(model: model)
            Divider()
            OverviewTable(overview: model.overview, loaded: model.usageLoaded)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TabBar(options: [(.activity, "Activity"), (.models, "Models"), (.projects, "Projects")],
                       selection: $model.tab)
                switch model.tab {
                case .activity: ActivityTab(model: model, hover: hover)
                case .models: BreakdownTab(model: model, kind: .models)
                case .projects: BreakdownTab(model: model, kind: .projects)
                }
            }
            .padding(.horizontal, Theme.padding)
            .padding(.top, 12)
            .padding(.bottom, Theme.padding)
            // As tall as the Activity tab, so switching tabs doesn't resize the popover.
            .frame(minHeight: 364, alignment: .top)
            Divider()
            Text(model.footerText)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, 8)
        }
        .frame(width: Theme.width)
    }
}

private struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ClaudonArt.appIcon(size: 26))
                .resizable()
                .frame(width: 26, height: 26)
                .padding(-3)
                .accessibilityHidden(true)
            Text("Claudon")
                .font(.system(size: 14, weight: .semibold))
            if let plan = model.plan {
                Text(plan)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Spacer()
            Button {
                model.refreshAll(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(model.isFetchingLimits || model.isScanning ? 0.4 : 1)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Refresh now")
            SettingsMenu(model: model)
        }
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 10)
    }
}

private struct SettingsMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            label.foregroundStyle(.secondary)
        } else {
            menu
        }
    }

    private var label: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(size: 13))
    }

    private var menu: some View {
        Menu {
            Button("Refresh Now") { model.refreshAll(force: true) }
            Divider()
            Toggle("Limit Notifications", isOn: Binding(get: { model.notificationsEnabled },
                                                        set: { model.setNotifications($0) }))
                .disabled(!model.canNotify)
            Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
            Divider()
            Button("Open Usage Settings on claude.ai") {
                if let url = URL(string: "https://claude.ai/settings/usage") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Quit Claudon") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }
}

struct OverviewTable: View {
    let overview: AppModel.Overview
    let loaded: Bool

    var body: some View {
        let periods = [overview.today, overview.week, overview.month]
        VStack(spacing: 5) {
            row(nil, ["Today", "7 days", "30 days"], header: true)
            row("Tokens", periods.map { Formatters.tokens($0.tokens) })
            row("Active time", periods.map { Formatters.duration(minutes: $0.minutes) })
            row("API cost", periods.map { Formatters.money($0.cost, compact: true) })
                .help("What these tokens would cost at Anthropic API list prices. Your plan is billed differently.")
            row("Top model", periods.map { $0.topModel ?? "-" })
        }
        .opacity(loaded ? 1 : 0.4)
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 12)
    }

    private func row(_ label: String?, _ values: [String], header: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(label ?? "")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(values.indices, id: \.self) { i in
                Text(values[i])
                    .fontWeight(header ? .regular : .medium)
                    .foregroundStyle(header ? .secondary : .primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 88, alignment: .trailing)
            }
        }
        .font(.system(size: header ? 10.5 : 12))
        .accessibilityElement(children: .combine)
    }
}
