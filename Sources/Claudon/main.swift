import AppKit
import ClaudonUI

let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
    return arguments[i + 1]
}

// Build-time helper: renders the app icon for iconutil.
if let path = argument(after: "--export-iconset") {
    do {
        try ClaudonArt.writeIconset(to: URL(fileURLWithPath: path))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Couldn't write the icon set: \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let path = argument(after: "--snapshot") {
        // Renders the popover to PNG files, with demo data when --demo is given.
        let delegate = SnapshotDelegate(output: URL(fileURLWithPath: path), demo: arguments.contains("--demo"))
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
