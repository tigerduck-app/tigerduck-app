import Foundation
import os

/// Persists the latest `LiveActivitySnapshot` so the Widget Extension can
/// render it via a shared App Group. The App Group is required: without
/// it the widget extension reads its own per-process defaults and never
/// sees what the app writes — i.e. Live Activity silently renders empty.
///
/// In DEBUG we crash hard if the suite is unavailable so the empty
/// `com.apple.security.application-groups` regression cannot ship
/// silently again. In release we still fall back to `.standard` with a
/// loud error so a user with a provisioning hiccup still launches.
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

    init(appGroupIdentifier: String? = SharedSnapshotStore.defaultAppGroupIdentifier) {
        if let id = appGroupIdentifier, let suite = UserDefaults(suiteName: id) {
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
