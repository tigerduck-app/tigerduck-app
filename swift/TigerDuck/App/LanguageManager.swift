import Foundation

enum LanguageManager {
    static let system = "system"
    private static let zhHant = "zh-Hant"
    private static let zhHans = "zh-Hans"

    // MARK: - Language resolution

    /// Language codes that should be treated as Chinese for the course API.
    /// Covers every Sinitic language iOS exposes as a system language:
    /// Mandarin (zh, incl. Hans/Hant/HK), Cantonese (yue), Min Nan / Hokkien
    /// (nan), Hakka (hak), Wu (wuu), and Classical / Literary Chinese (lzh).
    private static let chineseLanguageCodes: Set<String> = [
        "zh", "yue", "nan", "hak", "wuu", "lzh"
    ]

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

    /// Whether the active UI language is non-Chinese (English, Japanese,
    /// Korean, French, etc.). Used to gate UI that only makes sense outside
    /// Chinese locales — e.g. the course-name abbreviation settings, which
    /// transform Mandarin display strings.
    ///
    /// When the user picked an explicit `appLanguage`, trust that tag. For
    /// "system", read `Bundle.main.preferredLocalizations` — this is the lproj
    /// iOS resolved at launch (matching what `String(localized:)` actually
    /// uses) and stays stable for the running process, unlike `Locale.current`
    /// which re-resolves dynamically when `AppleLanguages` changes.
    static func isCurrentLanguageNonChinese(appLanguage: String) -> Bool {
        let tag: String
        if appLanguage == system {
            tag = Bundle.main.preferredLocalizations.first ?? "en"
        } else {
            tag = appLanguage
        }
        let code = Locale(identifier: tag).language.languageCode?.identifier ?? ""
        return !chineseLanguageCodes.contains(code)
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
    /// `tools/localization/sync_localizations.py` surfaces each generated lproj as
    /// a top-level symlink under the synchronized group, so Xcode copies them to
    /// the bundle root (`<App>.app/<lang>.lproj`), not into a `Localization/`
    /// subfolder. We enumerate the resource URL directly.
    static func supportedLocaleTags() -> [String] {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
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
    }
}
