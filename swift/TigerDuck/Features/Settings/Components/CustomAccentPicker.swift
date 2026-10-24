import SwiftUI

/// A custom accent while it is being picked. The app's tint draws it at once, while the saved
/// accent waits for the drag to pause: saving regenerates the widget snapshot, updates the
/// Watch and refreshes Live Activities, which would otherwise happen at every step of a drag.
@Observable
final class AccentPreview {
    static let shared = AccentPreview()

    private(set) var hex: Int?

    func tint(saved: Color) -> Color {
        hex.map { Color(hex: UInt($0)) } ?? saved
    }

    func shownHex(saved: Int) -> Int {
        hex ?? saved
    }

    func isCustom(saved: Int) -> Bool {
        let shown = shownHex(saved: saved) & 0xFFFFFF
        return !AppState.themeColors.contains { $0.hex == shown }
    }

    /// Draws a pick, made readable, and returns the value to save once picking pauses, or nil
    /// when that is the saved accent: the picker first reports the colour it opens on.
    func preview(_ picked: Int, saved: Int) -> Int? {
        let saved = saved & 0xFFFFFF
        let readable = AccentContrast.readable(picked)
        guard picked & 0xFFFFFF != saved, readable != saved else {
            hex = nil
            return nil
        }
        hex = readable
        return readable
    }

    /// Whether a pending save still holds: a preset chosen, or a later pick, replaces it.
    func takeForSaving(_ value: Int) -> Bool {
        guard hex == value else { return false }
        hex = nil
        return true
    }

    func clear() {
        hex = nil
    }
}

/// The accent row's last button, a colour well for a colour of the user's own. The well keeps
/// the raw pick, so the picker's handle stays where it is dragged while the app draws the
/// readable version.
struct CustomAccentPicker: View {
    let appState: AppState
    let size: CGFloat

    @State private var picked: Color
    @State private var picks: CustomColorPickDebouncer
    private let preview = AccentPreview.shared

    init(appState: AppState, size: CGFloat) {
        self.appState = appState
        self.size = size
        _picked = State(initialValue: appState.accentColor)
        let preview = AccentPreview.shared
        _picks = State(initialValue: CustomColorPickDebouncer(
            apply: { [weak appState] hex in
                if preview.takeForSaving(Int(hex)) { appState?.accentColorHex = Int(hex) }
            },
            appliedHex: { [weak appState] in UInt32((appState?.accentColorHex ?? 0) & 0xFFFFFF) },
            isCurrent: { true }
        ))
    }

    private var isSelected: Bool {
        preview.isCustom(saved: appState.accentColorHex)
    }

    var body: some View {
        ColorPicker(String(localized: "color_picker_custom"), selection: $picked, supportsOpacity: false)
            .labelsHidden()
            .frame(width: size, height: size)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(AccentContrast.whiteReads(on: Int(picked.rgbHex)) ? Color.white : Color.black)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onChange(of: picked) { _, colour in
                if let hex = preview.preview(Int(colour.rgbHex), saved: appState.accentColorHex) {
                    picks.pick(UInt32(hex))
                } else {
                    picks.cancel()
                }
            }
            // A preset chosen meanwhile, the saved one included, which clears the preview but
            // saves nothing new, is where the picker opens next: opening it saves nothing, and
            // the last custom colour can be picked again.
            .onChange(of: appState.accentColorHex) { followPreset() }
            .onChange(of: preview.hex) { followPreset() }
            .onDisappear { picks.flush() }
    }

    private func followPreset() {
        let saved = appState.accentColorHex
        guard preview.hex == nil, !preview.isCustom(saved: saved) else { return }
        picked = Color(hex: UInt(saved & 0xFFFFFF))
    }
}
