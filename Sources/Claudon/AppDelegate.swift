import AppKit
import ClaudonCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            // Another copy already sits in the menu bar.
            NSApp.terminate(nil)
            return
        }

        let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"
        let model = AppModel(index: TranscriptIndex(stateURL: Self.stateURL),
                             notifier: isAppBundle ? Notifier() : nil)
        self.model = model
        statusItem = StatusItemController(model: model)
        if isAppBundle { LoginItem.enableOnFirstInstalledRun() }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveNow()
    }

    static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudon", isDirectory: true)
            .appendingPathComponent("usage-index.json")
    }
}
