import Foundation
import os

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

nonisolated enum AppClock {

    typealias ObserverToken = ClockCore.ObserverToken

    static let persistenceKey = "debug.clock.override"

    #if os(watchOS)
    private static func defaultsStore() -> UserDefaults { .standard }
    #else
    static let appGroupSuiteName = "group.org.ntust.app.TigerDuck"
    private static func defaultsStore() -> UserDefaults {
        AppUserDefaults.suite(appGroupSuiteName) ?? .standard
    }
    #endif

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
