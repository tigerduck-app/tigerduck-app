import Foundation

enum LanguageManager {
    static let system = "system"
    private static let zhHant = "zh-Hant"
    private static let zhHans = "zh-Hans"

    // MARK: - Language resolution

    /// Language codes that should be treated as Chinese for the course API.
    /// "yue" covers Cantonese; "zh" covers Mandarin variants.
    private static let chineseLanguageCodes: Set<String> = ["zh", "yue"]

    /// Resolves the language tag to use for NTUST course API calls.
    /// The API only supports "zh" and "en".
    static func resolvedCourseApiLanguage(appLanguage: String) -> String {
        let tag = appLanguage == system ? resolvedSystemLanguage() : appLanguage
        let locale = Locale(identifier: tag)
        let code = locale.language.languageCode?.identifier ?? ""
        return chineseLanguageCodes.contains(code) ? "zh" : "en"
    }

    static func isCourseApiEnglish(appLanguage: String) -> Bool {
        resolvedCourseApiLanguage(appLanguage: appLanguage) == "en"
    }

    /// Returns the device's primary language code for use when appLanguage == "system".
    /// Falls back to "en" for unsupported device languages.
    static func resolvedSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let locale = Locale(identifier: preferred)
        let code = locale.language.languageCode?.identifier ?? ""
        return chineseLanguageCodes.contains(code) ? "zh" : "en"
    }

    // MARK: - Supported locale tags

    /// Returns the BCP-47 tags that correspond to `.lproj` bundles baked into the app.
    /// The TigerDuck pipeline ships them under `<app>/Localization/*.lproj`, so we
    /// enumerate that directory rather than relying on `Bundle.main.localizations`
    /// (which only sees lproj folders at the bundle root).
    static func supportedLocaleTags() -> [String] {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let localizationDir = resourceURL.appendingPathComponent("Localization", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: localizationDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "lproj" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != "Base" }
            .sorted()
    }

    // MARK: - Apply

    /// Applies the selected language by writing `AppleLanguages` to UserDefaults.
    /// The caller is responsible for forcing a root-view rebuild so SwiftUI
    /// re-resolves all `String(localized:)` calls with the new locale.
    static func apply(_ appLanguage: String) {
        if appLanguage == system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            let appleTag: String
            switch appLanguage {
            case zhHant: appleTag = "zh-Hant-TW"
            case zhHans: appleTag = "zh-Hans-CN"
            default: appleTag = appLanguage
            }
            UserDefaults.standard.set([appleTag], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}
