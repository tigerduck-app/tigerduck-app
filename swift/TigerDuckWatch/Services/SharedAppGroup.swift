import Foundation

/// Single source of truth for App Group identifiers + paths shared between
/// the watch app and the widget. Both targets must declare the App Group
/// `group.tw.smashit.tigerduck.watch` in their entitlements.
enum SharedAppGroup {
    static let identifier = "group.tw.smashit.tigerduck.watch"

    /// Directory inside the App Group container.
    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            fatalError("App Group container missing — entitlement misconfigured")
        }
        return url
    }

    /// File where the most recent decoded snapshot is persisted.
    static var snapshotFileURL: URL {
        containerURL.appendingPathComponent("schedule.json", isDirectory: false)
    }

    /// Shared UserDefaults suite for small watch-side preferences.
    static var defaults: UserDefaults {
        guard let d = UserDefaults(suiteName: identifier) else {
            fatalError("UserDefaults(suiteName:) returned nil for \(identifier)")
        }
        return d
    }
}
