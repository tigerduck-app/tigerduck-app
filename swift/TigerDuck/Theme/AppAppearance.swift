import Defaults
import SwiftUI

/// Settings' colour theme: the system's appearance, or light or dark whatever the system uses.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "settings_theme_system")
        case .light: String(localized: "settings_theme_light")
        case .dark: String(localized: "settings_theme_dark")
        }
    }
}

extension View {
    /// Environments do not cross scene boundaries, so every scene's root view takes this.
    func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @Default(.appAppearance) private var appearance

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}
