import Defaults
import Foundation

enum LibraryTabAddMigration {
    private static let doneKey = "LibraryTabAddMigration.v1.done"
    private static let libraryOptInKey = "libraryFeatureEnabled"

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

    static func tabsAddingLibrary(to tabs: [AppFeature]) -> [AppFeature]? {
        guard !tabs.contains(.library), tabs.count < AppFeature.maxTabs else { return nil }
        return tabs + [.library]
    }
}
