import Foundation
import os

/// the watch app and the widget. Both targets must declare the App Group
/// `group.org.ntust.app.TigerDuck.watch` in their entitlements.
nonisolated enum SharedAppGroup {
    static let identifier = "group.org.ntust.app.TigerDuck.watch"

    private static let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck.watchkitapp",
        category: "appgroup"
    )

    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        logger.error("App Group container missing for \(identifier, privacy: .public) — entitlement misconfigured; falling back to Caches directory (snapshot will not be shared with widget)")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var snapshotFileURL: URL {
        containerURL.appendingPathComponent("schedule.json", isDirectory: false)
    }

    static var defaults: UserDefaults {
        if let d = UserDefaults(suiteName: identifier) {
            return d
        }
        logger.error("UserDefaults(suiteName:) returned nil for \(identifier, privacy: .public); falling back to a non-shared instance (cooldown state will not persist across app/widget)")
        return UserDefaults()
    }
}
