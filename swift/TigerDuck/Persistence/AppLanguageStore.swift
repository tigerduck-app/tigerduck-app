import Foundation
import TigerDuckCore

/// The language chosen in the app's settings, kept in the App Group for the widget and Live
/// Activity extensions. The backend starts a class Live Activity with no app process running, so the
/// extension reads it here rather than from what the app sends.
nonisolated struct AppLanguageStore {
    static let key = "appLanguageTag"

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = AppUserDefaults.suite(AppUserDefaults.appGroupIdentifier)) {
        self.defaults = defaults
    }

    func read() -> AppLanguage {
        AppLanguage(tag: defaults?.string(forKey: Self.key))
    }

    func write(_ language: AppLanguage) {
        if let tag = language.tag {
            defaults?.set(tag, forKey: Self.key)
        } else {
            defaults?.removeObject(forKey: Self.key)
        }
    }
}
