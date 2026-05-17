import Foundation
import os

/// Single source of "now" for the app. All UI / class-status / scheduler code
/// MUST read time through this enum so the debug override applies uniformly.
///
/// Auth/network code (session expiry, cookie TTL, login timestamps, cache TTLs)
/// intentionally does NOT use AppClock — see spec for rationale.
enum AppClock {

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var override: ClockOverride?
        var didLoadPersisted: Bool = false
        var version: UInt64 = 0
        var observers: [UInt64: (UInt64) -> Void] = [:]
        var nextObserverID: UInt64 = 0
    }

    struct ObserverToken: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    static func now() -> Date {
        let override = lock.withLock { state -> ClockOverride? in
            loadPersistedIfNeeded(into: &state)
            return state.override
        }
        guard let o = override else { return Date() }
        if o.frozen { return o.instant }
        let elapsed = Date().timeIntervalSince(o.savedAtReal)
        return o.instant.addingTimeInterval(elapsed)
    }

    static func nowMillis() -> Int64 {
        Int64(now().timeIntervalSince1970 * 1000)
    }

    /// Translates a target instant in the app's clock (possibly fake) into
    /// the real wall-clock instant at which it should occur. Used as the
    /// trigger time for `UNCalendarNotificationTrigger` /
    /// `UNTimeIntervalNotificationTrigger` so reminders fire at the right
    /// real moment under fake time.
    ///
    /// Identity when no override is active.
    ///
    /// Not idempotent in frozen mode: real-now keeps moving while fake-now
    /// stays put, so two calls for the same target return different values.
    /// Capture the result once at scheduling time; do not re-call it for
    /// the same target.
    static func realTime(forApp appWall: Date) -> Date {
        guard let o = currentOverride() else { return appWall }
        if o.frozen {
            let delta = appWall.timeIntervalSince(o.instant)
            return Date().addingTimeInterval(delta)
        } else {
            let offset = o.instant.timeIntervalSince(o.savedAtReal)
            return appWall.addingTimeInterval(-offset)
        }
    }

    static func currentOverride() -> ClockOverride? {
        lock.withLock { state in
            loadPersistedIfNeeded(into: &state)
            return state.override
        }
    }

    static func setOverride(_ override: ClockOverride?) {
        let (newVersion, observers) = lock.withLock { state -> (UInt64, [(UInt64) -> Void]) in
            state.override = override
            state.didLoadPersisted = true
            state.version &+= 1
            return (state.version, Array(state.observers.values))
        }
        for block in observers { block(newVersion) }
    }

    // MARK: - Observers + version (filled in by Task 4)

    static func version() -> UInt64 {
        lock.withLock { $0.version }
    }

    @discardableResult
    static func observe(_ block: @escaping (UInt64) -> Void) -> ObserverToken {
        lock.withLock { state in
            state.nextObserverID &+= 1
            let id = state.nextObserverID
            state.observers[id] = block
            return ObserverToken(id: id)
        }
    }

    static func removeObserver(_ token: ObserverToken) {
        lock.withLock { state in
            _ = state.observers.removeValue(forKey: token.id)
        }
    }

    // MARK: - Persistence read

    /// Reads the persisted override on first access in this process, then caches.
    /// Caller must hold the lock.
    ///
    /// DEBUG-only: the writer (`DebugClockStore`) is itself `#if DEBUG`-gated,
    /// so the only way for the persisted key to exist is via a previous debug
    /// or TestFlight build. Without this gate, a user who upgrades from such a
    /// build to a release one would have the stale override loaded into the
    /// release `AppClock` on cold launch and every UI / scheduler / widget
    /// surface would render fake time.
    private static func loadPersistedIfNeeded(into state: inout State) {
        guard !state.didLoadPersisted else { return }
        state.didLoadPersisted = true
        #if DEBUG
        guard let data = defaultsStore().data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode(ClockOverride.self, from: data)
        else { return }
        state.override = decoded
        #endif
    }

    static let persistenceKey = "debug.clock.override"

    #if os(watchOS)
    private static func defaultsStore() -> UserDefaults { .standard }
    #else
    static let appGroupSuiteName = "group.org.ntust.app.TigerDuck"
    private static func defaultsStore() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }
    #endif

    #if DEBUG
    /// Resets in-memory state. For tests only.
    static func _resetForTests() {
        lock.withLock { state in
            state.override = nil
            state.didLoadPersisted = false
            state.observers.removeAll()
            state.version = 0
            state.nextObserverID = 0
        }
    }
    #endif
}
