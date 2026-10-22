import Foundation

nonisolated enum LanguageManager {
    static let system = "system"
    private static let zhHant = "zh-Hant"
    private static let zhHans = "zh-Hans"

    private static let chineseLanguageCodes: Set<String> = [
        "zh", "yue", "nan", "hak", "wuu", "lzh"
    ]

    static func resolvedCourseApiLanguage(appLanguage: String) -> String {
        let tag = appLanguage == system ? resolvedSystemLanguage() : appLanguage
        let locale = Locale(identifier: tag)
        let code = locale.language.languageCode?.identifier ?? ""
        return chineseLanguageCodes.contains(code) ? "zh" : "en"
    }

    static func isCourseApiEnglish(appLanguage: String) -> Bool {
        resolvedCourseApiLanguage(appLanguage: appLanguage) == "en"
    }

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

    static func resolvedSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let locale = Locale(identifier: preferred)
        let code = locale.language.languageCode?.identifier ?? ""
        return chineseLanguageCodes.contains(code) ? "zh" : "en"
    }

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

    static func displayName(for tag: String) -> String {
        let locale = Locale(identifier: tag)
        guard let name = locale.localizedString(forIdentifier: tag),
              let first = name.first
        else { return tag }
        return String(first).capitalized(with: locale) + name.dropFirst()
    }

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
