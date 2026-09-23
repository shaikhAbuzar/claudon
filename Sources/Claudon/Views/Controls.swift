import SwiftUI

/// A compact segmented control drawn in SwiftUI, so it matches the charts and renders in snapshots.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Text tabs with an underline under the selected one.
struct TabBar<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 18) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    VStack(spacing: 4) {
                        Text(option.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                        Capsule()
                            .fill(selected ? Theme.accent(scheme) : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

/// A usage meter: the fill carries state and the track is a lighter step of the same color.
struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let value = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color.opacity(0.2))
                if value > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: max(geometry.size.width * value, 6))
                }
            }
        }
        .frame(height: 6)
    }
}

/// A horizontal share bar, square at the baseline with a rounded end, and its percentage.
struct ShareBar: View {
    let share: Double
    let color: Color
    var width: CGFloat = 56

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Color.clear.frame(width: width, height: 7)
                UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, width * min(max(share, 0), 1)), height: 7)
            }
            Text(percentText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var percentText: String {
        let percent = share * 100
        return percent > 0 && percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }
}
