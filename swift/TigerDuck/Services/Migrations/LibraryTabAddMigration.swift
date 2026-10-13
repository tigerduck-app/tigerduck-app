import Defaults
import Foundation

/// One-shot migration: pins Library, left of More, on an existing user's stored bottom bar that
/// has room for it.
///
/// Until 2.4.0 the library sat behind an opt-in switch, so most bars never had it. The switch is
/// gone and the library is always on. A bar the user never changed is not stored and already
/// reads `AppFeature.defaultTabs`, which has Library; a full bar stays as it is, and so does the
/// bar of a user who had the library on, which pinned it, and took it off since.
enum LibraryTabAddMigration {
    private static let doneKey = "LibraryTabAddMigration.v1.done"
    /// The opt-in switch's stored value, read once here and then deleted.
    private static let libraryOptInKey = "libraryFeatureEnabled"

    /// Returns whether it stored a new bar, so the caller can reload the bar it already read.
    @discardableResult
    static func runIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return false }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        let hadLibraryOn = UserDefaults.standard.bool(forKey: libraryOptInKey)
        UserDefaults.standard.removeObject(forKey: libraryOptInKey)
        guard !hadLibraryOn,
              let stored = AppState.decodeConfiguredTabs(Defaults[.configuredTabsData]),
              let tabs = tabsAddingLibrary(to: stored),
              let data = try? JSONEncoder().encode(tabs.map(\.rawValue)) else { return false }
        Defaults[.configuredTabsData] = data
        return true
    }

    /// `tabs` with Library last, which puts it left of More, or nil when the bar has it or is full.
    static func tabsAddingLibrary(to tabs: [AppFeature]) -> [AppFeature]? {
        guard !tabs.contains(.library), tabs.count < AppFeature.maxTabs else { return nil }
        return tabs + [.library]
    }
}
