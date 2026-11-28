import Foundation

nonisolated enum AppUserDefaults {
    /// The App Group the phone app shares with its widget and Live Activity extensions.
    static let appGroupIdentifier = "group.org.ntust.app.TigerDuck"

    static var standard: UserDefaults { .standard }

    static func suite(_ name: String) -> UserDefaults? {
        UserDefaults(suiteName: name)
    }
}
