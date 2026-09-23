import ClaudonCore
import Foundation
import WidgetKit

/// Writes what the widget shows and asks WidgetKit to redraw it. WidgetKit budgets reloads,
/// so a change to the limits reloads right away and anything else at most every 15 minutes;
/// the widget also rereads the file on its own schedule.
@MainActor
final class WidgetPublisher {
    static let kind = "ClaudonUsage"
    private static let minimumInterval: TimeInterval = 15 * 60

    private let url: URL
    private var lastWritten: Data?
    private var lastSignature: String?
    private var lastReload = Date.distantPast
    private var pendingReload = false

    init(url: URL = WidgetSnapshot.fileURL) {
        self.url = url
    }

    func publish(_ snapshot: WidgetSnapshot) {
        // generatedAt changes every time; compare the rest.
        var comparable = snapshot
        comparable.generatedAt = .distantPast
        guard let key = try? comparable.encoded(), key != lastWritten, let data = try? snapshot.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        lastWritten = key
        let signature = snapshot.limitsSignature
        let limitsChanged = signature != lastSignature
        lastSignature = signature
        if limitsChanged || Date().timeIntervalSince(lastReload) >= Self.minimumInterval {
            reload()
        } else if !pendingReload {
            pendingReload = true
            let delay = Self.minimumInterval - Date().timeIntervalSince(lastReload)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pendingReload else { return }
                    self.reload()
                }
            }
        }
    }

    private func reload() {
        pendingReload = false
        lastReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: Self.kind)
    }
}
