import Foundation

/// The defaults the app's settings, flags and small caches live in, each under the key its owner
/// names. Code outside `Persistence/` reaches them through here, so every store of user data is
/// found under `Persistence/`. The widgets and the Watch compile it for the App Group's suite.
nonisolated enum AppUserDefaults {
    static var standard: UserDefaults { .standard }

    static func suite(_ name: String) -> UserDefaults? {
        UserDefaults(suiteName: name)
    }
}
