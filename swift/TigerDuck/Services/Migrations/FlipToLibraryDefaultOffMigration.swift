import Defaults
import Foundation

/// One-shot migration for 2.5.0, where flip-to-library is off by default and offered after a
/// library sign-in, no longer on the first flip. A user who kept the gesture at that first flip
/// stored no value, as it defaulted on, and would lose it with the new default, so it is stored
/// on. Anyone who chose either way, at that prompt or in Settings, is not asked again.
enum FlipToLibraryDefaultOffMigration {
    private static let doneKey = "FlipToLibraryDefaultOffMigration.v1.done"

    /// Returns whether it stored the switch, which `AppState` read before it ran.
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

    /// Whether the switch was ever written. `Defaults` registers each key's default, which
    /// `object(forKey:)` returns too, so this reads the app's persistent domain alone.
    private static func hasStoredSwitch() -> Bool {
        let key = Defaults.Key<Bool>.flipToLibraryEnabled
        guard let domain = Bundle.main.bundleIdentifier else { return false }
        return key.suite.persistentDomain(forName: domain)?[key.name] != nil
    }
}
