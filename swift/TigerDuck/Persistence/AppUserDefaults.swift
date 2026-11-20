import Foundation

nonisolated enum AppUserDefaults {
    static var standard: UserDefaults { .standard }

    static func suite(_ name: String) -> UserDefaults? {
        UserDefaults(suiteName: name)
    }
}
