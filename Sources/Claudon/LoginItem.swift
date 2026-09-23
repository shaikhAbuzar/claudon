import AppKit
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // macOS can hold a new login item for approval; send the user to the right pane.
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    /// Turns launch at login on the first time Claudon runs from an Applications folder.
    static func enableOnFirstInstalledRun(defaults: UserDefaults = .standard) {
        let key = "launchAtLoginConfigured"
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        if !isEnabled { set(true) }
    }
}
