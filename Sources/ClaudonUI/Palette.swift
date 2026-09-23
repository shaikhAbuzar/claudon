import ClaudonCore
import SwiftUI

/// Colors shared by the popover and the widget. Each is picked per color scheme explicitly so
/// the same values render in the app, the widget and snapshots.
public enum Palette {
    /// The stage each heatmap level borrows from the glyph: blue, green, orange, red, so busy
    /// days read like a nearly full limit.
    public static let heatStages = [1, 4, 7, 9]

    /// Heatmap levels 0 to 4, on the same color scale as the glyph. Level 0 is an empty square.
    public static func heat(_ level: Int, _ scheme: ColorScheme) -> Color {
        guard level > 0 else { return empty(scheme) }
        let stage = heatStages[min(level, heatStages.count) - 1]
        return Color(hex: ClaudonArt.stageColor(stage, dark: scheme == .dark))
    }

    /// Heatmap levels as brightness steps, for when the system draws the widget in one tint
    /// (the desktop while another app is in front). Hues would all turn the same gray there.
    public static func dimmedHeat(_ level: Int) -> Color {
        let opacities = [0.12, 0.32, 0.52, 0.74, 0.96]
        return Color.primary.opacity(opacities[min(max(level, 0), opacities.count - 1)])
    }

    public static func empty(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
    }

    /// Status colors carry state only, and always sit next to a number or an icon.
    public static func status(_ level: UsageLevel) -> Color {
        switch level {
        case .normal: Color(hex: 0x0CA30C)
        case .warning: Color(hex: 0xFAB219)
        case .critical: Color(hex: 0xD03B3B)
        }
    }
}

private struct WidgetDimmedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the system draws the widget in one tint, where colors carry no meaning and
    /// views switch to brightness steps.
    public var widgetDimmed: Bool {
        get { self[WidgetDimmedKey.self] }
        set { self[WidgetDimmedKey.self] = newValue }
    }
}

extension Color {
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// The menu bar glyph as SwiftUI shapes, for places that can't show an `NSImage` drawn on
/// demand, like widgets. `stage` nil draws the plain outline in the current foreground style.
public struct GlyphView: View {
    let stage: Int?
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetDimmed) private var dimmed

    public init(stage: Int?, size: CGFloat = 18) {
        self.stage = stage
        self.size = size
    }

    public var body: some View {
        let line = StrokeStyle(lineWidth: ClaudonArt.glyphStroke * size / ClaudonArt.glyphBox, lineCap: .round)
        ZStack {
            if let stage {
                let color = dimmed ? Color.primary : Color(hex: ClaudonArt.stageColor(stage, dark: scheme == .dark))
                GlyphPath(path: Path(ClaudonArt.squircle))
                    .stroke(dimmed ? Color.primary.opacity(0.25)
                        : scheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.22), style: line)
                GlyphPath(path: Path(ClaudonArt.squircle))
                    .trim(from: 0, to: CGFloat(min(max(stage, 0), 9) + 1) / 10)
                    .stroke(color, style: line)
                GlyphPath(path: Path(ClaudonArt.glyphEars)).fill(color)
            } else {
                GlyphPath(path: Path(ClaudonArt.squircle)).stroke(style: line)
                GlyphPath(path: Path(ClaudonArt.glyphEars))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A glyph path, drawn in its 18 point box and scaled to fill the frame.
private struct GlyphPath: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / ClaudonArt.glyphBox
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
