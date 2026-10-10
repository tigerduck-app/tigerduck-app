import Foundation
import os

/// Everything the app's clock does, with its state and persistence store
/// handed in rather than reached for.
///
/// `AppClock` is a static facade over the app's one instance. The split is for
/// tests: Swift Testing runs cases in parallel, so a process-global override
/// leaks a frozen clock into unrelated tests. Each test builds its own core.
/// `@unchecked Sendable`: `State` is only touched under `lock` and `UserDefaults`
/// is thread-safe, so any isolation can use it without a hop to `MainActor`.
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

    /// Translates an instant on the app's clock, possibly fake, into the real
    /// instant it should occur at: the trigger time for
    /// `UNCalendarNotificationTrigger` and `UNTimeIntervalNotificationTrigger`,
    /// so reminders fire at the right real moment. Identity with no override.
    ///
    /// Not idempotent when frozen: real now moves while fake now stays, so two
    /// calls for one target differ. Capture the result once at scheduling time.
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

/// The app's single source of "now". UI, class-status and scheduler code must
/// read time here so the debug override applies everywhere. Auth and network
/// code (session expiry, cookie and cache TTLs, login timestamps) reads the real
/// clock instead, since those expire in real time.
///
/// A forwarding shell: the behaviour lives on `ClockCore`, and this binds the
/// app's one instance to the App Group defaults. Test `ClockCore` directly, which
/// keeps tests parallel.
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
