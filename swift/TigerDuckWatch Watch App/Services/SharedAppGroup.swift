import Foundation
import os

/// Single source of truth for App Group identifiers + paths shared between
/// the watch app and the widget. Both targets must declare the App Group
/// `group.org.ntust.app.TigerDuck.watch` in their entitlements.
///
/// If the App Group resolves to nil (provisioning / entitlement mismatch),
/// the helpers log the failure and fall back to the per-process Caches
/// directory and a fresh `UserDefaults` instance. Those fallbacks aren't
/// shared between the app and widget — they exist so a misconfigured
/// build degrades to the existing "no snapshot yet" empty state instead
/// of crashing the process.
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
