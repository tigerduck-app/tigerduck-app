import SwiftUI

/// The accent row's last button, a colour well for a colour of the user's own. The app draws
/// each pick at once and saves it once the drag pauses. The well keeps the raw pick, so the
/// picker's handle stays where it is dragged while the app draws the readable version.
struct CustomAccentPicker: View {
    let appState: AppState
    let size: CGFloat

    @State private var picked: Color
    @State private var picks: CustomColorPickDebouncer

    init(appState: AppState, size: CGFloat) {
        self.appState = appState
        self.size = size
        _picked = State(initialValue: appState.accentColor)
        _picks = State(initialValue: CustomColorPickDebouncer(
            apply: { [weak appState] hex in appState?.commitAccentPreview(Int(hex)) },
            appliedHex: { [weak appState] in UInt32((appState?.accentColorHex ?? 0) & 0xFFFFFF) },
            isCurrent: { true }
        ))
    }

    var body: some View {
        ColorPicker(String(localized: "color_picker_custom"), selection: $picked, supportsOpacity: false)
            .labelsHidden()
            .frame(width: size, height: size)
            .overlay {
                if appState.hasCustomAccent {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(appState.hasCustomAccent ? .isSelected : [])
            .onChange(of: picked) { _, colour in
                if let hex = appState.previewCustomAccent(Int(colour.rgbHex)) {
                    picks.pick(UInt32(hex))
                } else {
                    picks.cancel()
                }
            }
            .onDisappear { picks.flush() }
    }
}
