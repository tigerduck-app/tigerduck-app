import SwiftUI

extension Color {
    static let textOnPastel = Color(.sRGB, white: 26 / 255)
    static let textOnPastelSecondary = Color(.sRGB, white: 26 / 255, opacity: 0.8)

    var pastel: Color { mixed(toward: 1, by: 0.65) }

    /// The pastel of a dark page: the colour mixed toward the dark widget surface, #1C1C1E.
    var darkPastel: Color { mixed(toward: 0.11, by: 0.65) }

    var pastelOutline: Color { mixed(toward: 0, by: 0.5) }

    private func mixed(toward target: Float, by share: Float) -> Color {
        var resolved = resolve(in: EnvironmentValues())
        resolved.red += (target - resolved.red) * share
        resolved.green += (target - resolved.green) * share
        resolved.blue += (target - resolved.blue) * share
        resolved.opacity = 1
        return Color(resolved)
    }
}
