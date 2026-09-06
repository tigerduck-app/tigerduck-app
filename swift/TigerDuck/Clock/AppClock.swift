import Foundation
import os

/// Everything the app's clock does, with its state and its persistence store
/// handed in rather than reached for.
///
/// `AppClock` is a `static` facade over exactly one of these, and one is all
/// the app ever builds. The split exists for the test suite. The override
/// used to live on the facade, which made it process-global; Swift Testing
/// runs cases in parallel, so a test that froze the clock was visible to
/// every unrelated test running beside it. `ScheduleSyncServiceTests`
/// computed a notification fire time in 2082 because a sibling test had
/// pinned the clock to 1970 a moment earlier, and which tests failed changed
/// from run to run. Tests now build their own core and share nothing, so the
/// suite stays parallel and stays honest.
///
/// `@unchecked Sendable`: `State` is only ever touched under `lock`, and
/// `UserDefaults` is thread-safe, so any caller — UI, scheduler, Sendable
/// closures, background tasks — can use one of these from any isolation
/// without a hop to `MainActor`.
nonisolated final class ClockCore: @unchecked Sendable {

    struct ObserverToken: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    private struct State {
        var override: ClockOverride?
        var didLoadPersisted: Bool = false
        var version: UInt64 = 0
        var observers: [UInt64: (UInt64) -> Void] = [:]
        var nextObserverID: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    /// Where a previously persisted override is read from on first access,
    /// or `nil` to never read one. See `AppClock.persistedStoreForBuild` for
    /// why the release build passes `nil`.
    private let persistedStore: UserDefaults?
    private let persistenceKey: String

    init(persistedStore: UserDefaults?, persistenceKey: String) {
        self.persistedStore = persistedStore
        self.persistenceKey = persistenceKey
    }

    func now() -> Date {
        let override = lock.withLock { state -> ClockOverride? in
            loadPersistedIfNeeded(into: &state)
            return state.override
        }
        guard let o = override else { return Date() }
        if o.frozen { return o.instant }
        let elapsed = Date().timeIntervalSince(o.savedAtReal)
        return o.instant.addingTimeInterval(elapsed)
    }

    func nowMillis() -> Int64 {
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
    func realTime(forApp appWall: Date) -> Date {
        guard let o = currentOverride() else { return appWall }
        if o.frozen {
            let delta = appWall.timeIntervalSince(o.instant)
            return Date().addingTimeInterval(delta)
        } else {
            let offset = o.instant.timeIntervalSince(o.savedAtReal)
            return appWall.addingTimeInterval(-offset)
        }
    }

    func currentOverride() -> ClockOverride? {
        lock.withLock { state in
            loadPersistedIfNeeded(into: &state)
            return state.override
        }
    }

    func setOverride(_ override: ClockOverride?) {
        let (newVersion, observers) = lock.withLock { state -> (UInt64, [(UInt64) -> Void]) in
            state.override = override
            state.didLoadPersisted = true
            state.version &+= 1
            return (state.version, Array(state.observers.values))
        }
        for block in observers { block(newVersion) }
    }

    // MARK: - Observers + version

    func version() -> UInt64 {
        lock.withLock { $0.version }
    }

    @discardableResult
    func observe(_ block: @escaping (UInt64) -> Void) -> ObserverToken {
        lock.withLock { state in
            state.nextObserverID &+= 1
            let id = state.nextObserverID
            state.observers[id] = block
            return ObserverToken(id: id)
        }
    }

    func removeObserver(_ token: ObserverToken) {
        lock.withLock { state in
            _ = state.observers.removeValue(forKey: token.id)
        }
    }

    // MARK: - Persistence read

    /// Reads the persisted override on first access, then caches. Caller
    /// must hold the lock.
    private func loadPersistedIfNeeded(into state: inout State) {
        guard !state.didLoadPersisted else { return }
        state.didLoadPersisted = true
        guard let store = persistedStore,
              let data = store.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode(ClockOverride.self, from: data)
        else { return }
        state.override = decoded
    }
}

/// Single source of "now" for the app. All UI / class-status / scheduler code
/// MUST read time through this enum so the debug override applies uniformly.
///
/// Auth/network code (session expiry, cookie TTL, login timestamps, cache TTLs)
/// intentionally does NOT use AppClock — see spec for rationale.
///
/// This is a forwarding shell; the behaviour lives on `ClockCore` above, and
/// this binds the app's one instance to the App Group defaults. Nothing here
/// is worth a test of its own — test `ClockCore` directly and you get to keep
/// parallel execution.
nonisolated enum AppClock {

    typealias ObserverToken = ClockCore.ObserverToken

    static let persistenceKey = "debug.clock.override"

    #if os(watchOS)
    private static func defaultsStore() -> UserDefaults { .standard }
    #else
    static let appGroupSuiteName = "group.org.ntust.app.TigerDuck"
    private static func defaultsStore() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }
    #endif

    /// DEBUG-only: the writer (`DebugClockStore`) is itself `#if DEBUG`-gated,
    /// so the only way for the persisted key to exist is via a previous debug
    /// or TestFlight build. Without this gate, a user who upgrades from such a
    /// build to a release one would have the stale override loaded into the
    /// release clock on cold launch and every UI / scheduler / widget surface
    /// would render fake time.
    private static func persistedStoreForBuild() -> UserDefaults? {
        #if DEBUG
        return defaultsStore()
        #else
        return nil
        #endif
    }

    private static let core = ClockCore(
        persistedStore: persistedStoreForBuild(),
        persistenceKey: persistenceKey
    )

    static func now() -> Date { core.now() }

    static func nowMillis() -> Int64 { core.nowMillis() }

    static func realTime(forApp appWall: Date) -> Date { core.realTime(forApp: appWall) }

    static func currentOverride() -> ClockOverride? { core.currentOverride() }

    static func setOverride(_ override: ClockOverride?) { core.setOverride(override) }

    static func version() -> UInt64 { core.version() }

    @discardableResult
    static func observe(_ block: @escaping (UInt64) -> Void) -> ObserverToken {
        core.observe(block)
    }

    static func removeObserver(_ token: ObserverToken) { core.removeObserver(token) }
}
