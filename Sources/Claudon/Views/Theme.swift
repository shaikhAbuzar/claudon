import ClaudonCore
import SwiftUI

/// Colors and sizes. Chart colors come from a validated data-viz palette; each is picked per
/// color scheme explicitly so the same values render in the app and in snapshots.
enum Theme {
    static let width: CGFloat = 400
    static let padding: CGFloat = 16

    /// Sequential blue ramp for the heatmaps, light to dark. Dark mode flips the anchor so
    /// low values recede into the dark background.
    static func heat(_ level: Int, _ scheme: ColorScheme) -> Color {
        guard level > 0 else { return empty(scheme) }
        let ramp: [UInt32] = scheme == .dark
            ? [0x184F95, 0x2A78D6, 0x6DA7EC, 0xB7D3F6]
            : [0x86B6EF, 0x3987E5, 0x1C5CAB, 0x0D366B]
        return Color(hex: ramp[min(level, 4) - 1])
    }

    static func empty(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
    }

    /// Single-series bars, such as model and project shares.
    static func accent(_ scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? 0x3987E5 : 0x2A78D6)
    }

    /// Status colors carry state only, and always sit next to a number or an icon.
    static func status(_ level: UsageLevel) -> Color {
        switch level {
        case .normal: Color(hex: 0x0CA30C)
        case .warning: Color(hex: 0xFAB219)
        case .critical: Color(hex: 0xD03B3B)
        }
    }

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

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
