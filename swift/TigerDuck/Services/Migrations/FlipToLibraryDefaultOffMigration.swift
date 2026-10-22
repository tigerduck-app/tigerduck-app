import Defaults
import Foundation

enum FlipToLibraryDefaultOffMigration {
    private static let doneKey = "FlipToLibraryDefaultOffMigration.v1.done"

    @discardableResult
    static func runIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return false }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        if hasStoredSwitch() {
            FirstTriggerPromptCenter.shared.markSeen(.flipToLibrary)
            return false
        }
        guard FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary) else { return false }
        Defaults[.flipToLibraryEnabled] = true
        return true
    }

    private static func hasStoredSwitch() -> Bool {
        let key = Defaults.Key<Bool>.flipToLibraryEnabled
        guard let domain = Bundle.main.bundleIdentifier else { return false }
        return key.suite.persistentDomain(forName: domain)?[key.name] != nil
    }
}
