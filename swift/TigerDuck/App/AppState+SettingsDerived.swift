import SwiftUI
import Defaults
import os

extension AppState {

    var accentColor: Color {
        // Use bitPattern to avoid trapping on a corrupted-defaults negative
        // accentColorHex (Int → UInt conversion crashes on negative values).
        Color(hex: UInt(bitPattern: Int(shownAccentHex)))
    }

    var shownAccentHex: Int { accentPreviewHex ?? accentColorHex }

    var hasCustomAccent: Bool {
        !Self.themeColors.contains { $0.hex == shownAccentHex & 0xFFFFFF }
    }

    func chooseAccent(_ hex: Int) {
        accentPreviewHex = nil
        accentColorHex = hex
    }

    /// Draws a custom pick at once, made readable, and returns the value to save once picking
    /// pauses; nil when that is the saved accent already.
    func previewCustomAccent(_ picked: Int) -> Int? {
        let saved = accentColorHex & 0xFFFFFF
        let readable = Self.readableCustomAccent(picked)
        // The picker first reports the accent it opens on, which stays as it is, presets too.
        guard picked & 0xFFFFFF != saved, readable != saved else {
            accentPreviewHex = nil
            return nil
        }
        accentPreviewHex = readable
        return readable
    }

    /// Saves a previewed pick, unless a preset was chosen or another pick came since.
    func commitAccentPreview(_ hex: Int) {
        guard accentPreviewHex == hex else { return }
        accentPreviewHex = nil
        accentColorHex = hex
    }

    /// `Color.cardSurface` over the black page; a test keeps the two in step.
    nonisolated static let accentCardHex = 0x181818

    /// A custom accent moved toward white until it reads at 3:1 on the cards, or toward black
    /// until white marks on it read at 3:1. The presets keep their own tones.
    nonisolated static func readableCustomAccent(_ hex: Int) -> Int {
        let picked = hex & 0xFFFFFF
        let card = luminance(accentCardHex)
        let readsOnCards = { (rgb: Int) in (luminance(rgb) + 0.05) / (card + 0.05) >= 3 }
        let whiteReadsOn = { (rgb: Int) in 1.05 / (luminance(rgb) + 0.05) >= 3 }
        if readsOnCards(picked) && whiteReadsOn(picked) { return picked }
        let (target, reads) = readsOnCards(picked) ? (0x000000, whiteReadsOn) : (0xFFFFFF, readsOnCards)
        return (1...100).lazy.map { mix(picked, toward: target, by: Double($0) / 100) }.first(where: reads) ?? target
    }

    private nonisolated static func luminance(_ rgb: Int) -> Double {
        let linear = [16, 8, 0].map { shift -> Double in
            let channel = Double((rgb >> shift) & 0xFF) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private nonisolated static func mix(_ rgb: Int, toward target: Int, by share: Double) -> Int {
        [16, 8, 0].reduce(0) { result, shift in
            let from = Double((rgb >> shift) & 0xFF)
            let to = Double((target >> shift) & 0xFF)
            return result | Int((from + (to - from) * share).rounded()) << shift
        }
    }

    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }

}
