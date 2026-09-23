import AppKit
import ClaudonCore
import ClaudonUI
import Combine
import SwiftUI

/// The menu bar item: the creature plus "17% · 4h 39m", opening the popover on click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()

        if let button = statusItem.button {
            button.image = ClaudonArt.menuBarGlyph()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model, hover: model.hover))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        model.$limits.combineLatest(model.$now, model.$limitsProblem)
            .sink { [weak self] limits, now, problem in
                self?.updateButton(limits: limits, now: now, stale: problem != nil)
            }
            .store(in: &subscriptions)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            model.popoverWillOpen()
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.hover.clear()
    }

    private func updateButton(limits: LimitsSnapshot?, now: Date, stale: Bool) {
        guard let button = statusItem.button else { return }
        guard let summary = MenuBarSummary.make(from: limits, now: now) else {
            button.image = ClaudonArt.menuBarGlyph()
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "Claudon"
            return
        }
        // Stale numbers keep the plain glyph so an old color doesn't look current.
        button.image = stale ? ClaudonArt.menuBarGlyph() : ClaudonArt.menuBarGlyph(stage: summary.stage)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ]
        switch summary.level {
        case .normal: if stale { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        case .warning: attributes[.foregroundColor] = NSColor.systemOrange
        case .critical: attributes[.foregroundColor] = NSColor.systemRed
        }
        button.attributedTitle = NSAttributedString(string: " " + summary.text, attributes: attributes)
        button.toolTip = tooltip(limits: limits, now: now)
    }

    private func tooltip(limits: LimitsSnapshot?, now: Date) -> String {
        guard let limits else { return "Claudon" }
        let lines = limits.windows.map { window -> String in
            var line = "\(window.title): \(Formatters.percent(window.percent(at: now)))"
            if let reset = window.resetsAt, reset > now { line += ", resets \(Formatters.resetClock(reset, now: now))" }
            return line
        }
        return (["Claudon"] + lines).joined(separator: "\n")
    }

    // MARK: Right-click menu

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(item("Refresh Now", #selector(refresh)))
        menu.addItem(.separator())
        let notifications = item("Limit Notifications", #selector(toggleNotifications))
        notifications.state = model.notificationsEnabled ? .on : .off
        notifications.isEnabled = model.canNotify
        menu.addItem(notifications)
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Claudon", #selector(quit), key: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refresh() { model.refreshAll(force: true) }
    @objc private func toggleNotifications() { model.setNotifications(!model.notificationsEnabled) }
    @objc private func toggleLaunchAtLogin() { model.setLaunchAtLogin(!LoginItem.isEnabled) }
    @objc private func quit() { NSApp.terminate(nil) }
}
