import Foundation
import os

/// Persists the latest `LiveActivitySnapshot` so the Widget Extension can
/// render it via a shared App Group. When the App Group capability is not
/// yet configured (phase B still pending), the store falls back to
/// `UserDefaults.standard`. The app will still function; the extension
/// simply won't see the snapshot until the App Group is enabled.
nonisolated final class SharedSnapshotStore {
    static let snapshotKey = "LA-current-snapshot"
    static let defaultAppGroupIdentifier = "group.org.ntust.app.TigerDuck"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")

    init(appGroupIdentifier: String? = SharedSnapshotStore.defaultAppGroupIdentifier) {
        if let id = appGroupIdentifier, let suite = UserDefaults(suiteName: id) {
            self.defaults = suite
        } else {
            self.defaults = .standard
            logger.warning("App Group suite unavailable — snapshot will stay app-private until the extension is configured")
        }
    }

    func readSnapshot() -> LiveActivitySnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return nil }
        return try? decoder.decode(LiveActivitySnapshot.self, from: data)
    }

    func writeSnapshot(_ snapshot: LiveActivitySnapshot?) {
        guard let snapshot else {
            defaults.removeObject(forKey: Self.snapshotKey)
            return
        }
        if let data = try? encoder.encode(snapshot) {
            defaults.set(data, forKey: Self.snapshotKey)
        }
    }
}
