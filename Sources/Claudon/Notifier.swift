import ClaudonCore
import Foundation
import UserNotifications

/// Posts limit alerts at 80% and 95%, and schedules a reminder for when a busy session resets.
///
/// Only created when Claudon runs from its app bundle: the notification center needs one.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let resetReminderID = "app.claudon.session-reset"
    private static let sentKey = "sentAlerts"

    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    /// Alert keys already announced, with the time they were sent.
    private var sent: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sent = defaults.dictionary(forKey: Self.sentKey) as? [String: Double] ?? [:]
        super.init()
        center.delegate = self
    }

    func setUp(enabled: Bool) {
        if enabled { requestAuthorization() }
    }

    func setEnabled(_ enabled: Bool, snapshot: LimitsSnapshot?) {
        if enabled {
            requestAuthorization()
            if let snapshot { process(snapshot, now: Date(), enabled: true) }
        } else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.resetReminderID])
        }
    }

    func process(_ snapshot: LimitsSnapshot, now: Date, enabled: Bool) {
        guard enabled else { return }
        for alert in AlertPlanner.alerts(for: snapshot, now: now, sent: Set(sent.keys)) {
            post(id: alert.id, title: alert.title, body: alert.body, at: nil)
            for key in alert.keys { sent[key] = now.timeIntervalSince1970 }
        }
        // Keys only matter while their window is open; weekly windows are the longest.
        sent = sent.filter { now.timeIntervalSince1970 - $0.value < 40 * 86_400 }
        defaults.set(sent, forKey: Self.sentKey)

        center.removePendingNotificationRequests(withIdentifiers: [Self.resetReminderID])
        if let reminder = AlertPlanner.sessionResetReminder(for: snapshot, now: now) {
            post(id: Self.resetReminderID, title: reminder.title, body: reminder.body, at: reminder.date)
        }
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(id: String, title: String, body: String, at date: Date?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = date.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false)
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Show banners even though Claudon counts as the active app while its popover is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
