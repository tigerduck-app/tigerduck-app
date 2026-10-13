import Foundation
import os

/// Single source of truth for the App Group identifier and paths shared by
/// the watch app and the widget. Both targets must declare the App Group
/// `group.org.ntust.app.TigerDuck.watch` in their entitlements.
///
/// If the App Group resolves to nil (provisioning or entitlement mismatch),
/// the helpers log it and fall back to the per-process Caches directory and
/// a fresh `UserDefaults`. These are not shared with the widget; they let a
/// misconfigured build show the "no snapshot yet" empty state, not crash.
nonisolated enum SharedAppGroup {
    static let identifier = "group.org.ntust.app.TigerDuck.watch"

    private static let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck.watchkitapp",
        category: "appgroup"
    )

    /// Directory inside the App Group container, or a per-process Caches
    /// fallback if the container is unavailable.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        logger.error("App Group container missing for \(identifier, privacy: .public) — entitlement misconfigured; falling back to Caches directory (snapshot will not be shared with widget)")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// File where the most recent decoded snapshot is persisted.
    static var snapshotFileURL: URL {
        containerURL.appendingPathComponent("schedule.json", isDirectory: false)
    }

    /// Shared UserDefaults suite for small watch-side preferences, or a
    /// fresh per-process instance if the suite is unavailable.
    static var defaults: UserDefaults {
        if let d = UserDefaults(suiteName: identifier) {
            return d
        }
        logger.error("UserDefaults(suiteName:) returned nil for \(identifier, privacy: .public); falling back to a non-shared instance (cooldown state will not persist across app/widget)")
        return UserDefaults()
    }
}
