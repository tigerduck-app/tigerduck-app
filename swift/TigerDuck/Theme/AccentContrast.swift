import Foundation

/// Keeps a custom accent readable: on the cards it is drawn on, and under the white marks drawn
/// on it, such as checkmarks and prominent buttons. The presets keep their own tones.
nonisolated enum AccentContrast {
    /// `Color.cardSurface` over the dark and the light page; a test keeps them in step.
    static let cardHex = 0x181818
    static let lightCardHex = 0xFCFCFD
    static let minimum = 3.0

    /// The pick moved toward white until it reads on the dark cards, or toward black until it
    /// reads on the light ones. Those are nearly white, so white marks on the accent read too.
    static func readable(_ hex: Int) -> Int {
        let picked = hex & 0xFFFFFF
        if !readsOnCards(picked) { return firstMix(of: picked, toward: 0xFFFFFF, where: readsOnCards) }
        if !readsOnLightCards(picked) { return firstMix(of: picked, toward: 0x000000, where: readsOnLightCards) }
        return picked
    }

    private static func firstMix(of rgb: Int, toward target: Int, where reads: (Int) -> Bool) -> Int {
        for step in 1...100 {
            let mixed = mix(rgb, toward: target, by: Double(step) / 100)
            if reads(mixed) { return mixed }
        }
        return target
    }

    static func whiteReads(on hex: Int) -> Bool {
        contrast(0xFFFFFF, hex & 0xFFFFFF) >= minimum
    }

    private static func readsOnCards(_ hex: Int) -> Bool {
        contrast(hex, cardHex) >= minimum
    }

    private static func readsOnLightCards(_ hex: Int) -> Bool {
        contrast(hex, lightCardHex) >= minimum
    }

    private static func contrast(_ first: Int, _ second: Int) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ rgb: Int) -> Double {
        let linear = [16, 8, 0].map { shift -> Double in
            let channel = Double((rgb >> shift) & 0xFF) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func mix(_ rgb: Int, toward target: Int, by share: Double) -> Int {
        [16, 8, 0].reduce(0) { result, shift in
            let from = Double((rgb >> shift) & 0xFF)
            let to = Double((target >> shift) & 0xFF)
            return result | Int((from + (to - from) * share).rounded()) << shift
        }
    }
}
