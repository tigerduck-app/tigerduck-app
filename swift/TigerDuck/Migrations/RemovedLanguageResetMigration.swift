import Defaults
import Foundation

/// Arabic, Persian, Hebrew and Urdu left the app (https://github.com/tigerduck-app/app-translation/pull/75).
/// A language picked in the app stays saved, so one of them would leave the Mac picker with no
/// choice and the Watch and the Live Activity formatting in it; it moves once to the system setting.
enum RemovedLanguageResetMigration {
    private static let doneKey = "RemovedLanguageResetMigration.v1.done"
    private static let removedLanguageCodes: Set<String> = ["ar", "fa", "he", "ur"]

    @discardableResult
    static func runIfNeeded() -> Bool {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return false }
        defer { AppUserDefaults.standard.set(true, forKey: doneKey) }
        let code = Locale(identifier: Defaults[.appLanguage]).language.languageCode?.identifier ?? ""
        guard removedLanguageCodes.contains(code) else { return false }
        Defaults[.appLanguage] = LanguageManager.system
        return true
    }
}
