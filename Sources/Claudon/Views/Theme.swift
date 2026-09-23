import ClaudonCore
import ClaudonUI
import SwiftUI

/// Colors and sizes. Colors are picked per color scheme explicitly so the same values render
/// in the app and in snapshots; the ones the widget shares live in `Palette`.
enum Theme {
    static let width: CGFloat = 400
    static let padding: CGFloat = 16

    /// Heatmap levels 0 to 4, on the menu bar glyph's color scale.
    static func heat(_ level: Int, _ scheme: ColorScheme) -> Color { Palette.heat(level, scheme) }

    /// Single-series bars, such as model and project shares.
    static func accent(_ scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? 0x3987E5 : 0x2A78D6)
    }

    static func status(_ level: UsageLevel) -> Color { Palette.status(level) }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)
    }
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering PNG snapshots, where AppKit-backed menus can't draw. Menus then
    /// show just their label.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}
