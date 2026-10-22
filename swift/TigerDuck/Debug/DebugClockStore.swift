#if DEBUG
import Foundation

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
