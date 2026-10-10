import Foundation
import os

/// Persists the latest `LiveActivitySnapshot` so the Widget Extension can render it through the
/// shared App Group. Without the group the extension reads its own per-process defaults, never
/// sees what the app writes, and Live Activity silently renders empty.
///
/// Debug builds crash when the group is unreachable (a container-URL check, see
/// ``isAppGroupAvailable(_:)``), so an empty `com.apple.security.application-groups`
/// entitlement cannot ship unnoticed. Release falls back to `.standard` with a loud error, so a
/// user with a provisioning hiccup still launches.
nonisolated final class SharedSnapshotStore {
    // Bump this when LiveActivitySnapshot's wire shape changes incompatibly.
    // The widget extension and main app must agree on the version key so a
    // stale-schema snapshot cannot decode as nil silently and blank the UI.
    static let snapshotKey = "LA-current-snapshot-v1"
    static let defaultAppGroupIdentifier = "group.org.ntust.app.TigerDuck"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")

    /// Whether this process can actually reach the shared App Group.
    ///
    /// `UserDefaults(suiteName:)` cannot tell: it returns nil only for reserved names and hands
    /// back a valid process-local store for a group the process has no entitlement for, which is
    /// the "renders empty" failure described above. `WidgetSnapshotStore.isAppGroupAvailable(_:)`
    /// has the full rationale. The check is duplicated because the two files sit in different
    /// synchronized folders, and a shared home would need a new target-membership exception in
    /// the project file.
    static func isAppGroupAvailable(_ identifier: String) -> Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) != nil
    }

    init(appGroupIdentifier: String? = SharedSnapshotStore.defaultAppGroupIdentifier) {
        // Only the shipping App Group has to be *reachable*. An injected
        // identifier is a test seam pointing at an ordinary UserDefaults
        // suite, which has no container and never will.
        if let id = appGroupIdentifier,
           id != Self.defaultAppGroupIdentifier || Self.isAppGroupAvailable(id),
           let suite = UserDefaults(suiteName: id) {
            self.defaults = suite
        } else {
            let identifierForLog = appGroupIdentifier ?? "nil"
            assertionFailure(
                "App Group suite '\(identifierForLog)' unavailable — verify `com.apple.security.application-groups` is populated in BOTH the app and Live Activity extension entitlements and that the App Group capability is enabled on each target."
            )
            self.defaults = .standard
            logger.error("App Group suite '\(identifierForLog, privacy: .public)' unavailable — Live Activity widget will not see app-side snapshots")
        }
    }

    func readSnapshot() -> LiveActivitySnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return nil }
        do {
            return try decoder.decode(LiveActivitySnapshot.self, from: data)
        } catch {
            // Schema mismatch shouldn't silently null every snapshot —
            // surface it so we notice when the wire shape drifts.
            logger.error("snapshot decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func writeSnapshot(_ snapshot: LiveActivitySnapshot?) {
        guard let snapshot else {
            defaults.removeObject(forKey: Self.snapshotKey)
            return
        }
        do {
            let data = try encoder.encode(snapshot)
            defaults.set(data, forKey: Self.snapshotKey)
        } catch {
            logger.error("snapshot encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
