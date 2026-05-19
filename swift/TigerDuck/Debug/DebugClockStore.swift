#if DEBUG
import Foundation

/// Phone-side persistence for the debug clock override. Backed by the App
/// Group `UserDefaults` so widgets and the LiveActivity extension read the
/// same value via `AppClock`'s lazy load.
///
/// Watch persistence is separate — the watch sandbox has no App Group with
/// the phone, so the watch keeps its own `.standard` copy populated by the
/// WatchConnectivity push.
struct DebugClockStore {
    static let key = AppClock.persistenceKey
    static let suiteName = AppClock.appGroupSuiteName

    private let defaults: UserDefaults

    init() {
        self.defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    func load() -> ClockOverride? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ClockOverride.self, from: data)
    }

    func save(_ override: ClockOverride) {
        guard let data = try? JSONEncoder().encode(override) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
#endif
