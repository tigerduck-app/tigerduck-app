import SwiftUI
import TigerDuckCore

struct AccentGradientStopRow: View {
    @Binding var draft: AccentGradient
    let index: Int

    var body: some View {
        let name = String(format: String(localized: "a11y_accent_gradient_stop"), index + 1)
        let hex = String(format: "#%06lX", stop)
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            if draft.isGradient {
                Button {
                    draft.stops.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, .red)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel([String(localized: "action_remove"), name].joined(separator: ", "))
            }
            ColorPicker(name, selection: color, supportsOpacity: false)
                .labelsHidden()
                .accessibilityValue(hex)
            Text(hex)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Color.textPrimary)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
    }

    private var stop: Int {
        draft.stops.indices.contains(index) ? draft.stops[index] : 0
    }

    private var color: Binding<Color> {
        Binding(
            get: { Color(hex: UInt(stop)) },
            set: { if draft.stops.indices.contains(index) { draft.stops[index] = Int($0.rgbHex) } }
        )
    }
}
