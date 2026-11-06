import Defaults
import Foundation
import os

nonisolated final class SyncClock: Sendable {
    static let shared = SyncClock()

    /// tigerduck-backend refuses a stamp later than its own time plus this with 409 `clock_ahead`
    /// (`MAX_CLOCK_SKEW` in https://github.com/tigerduck-app/tigerduck-backend/blob/dev/server/sync/merge.py).
    static let backendLead: Int64 = 5_000_000
    private static let overflowSafeCeiling = Int64.max / 2
    /// TigerSync started in 2026, and a clock value past 2100 no longer survives a `Date` exactly.
    static let plausible: Range<Int64> = 1_767_225_600_000_000..<4_102_444_800_000_000
    // Longer than any backend request may take, so answers read out of order stay within it.
    private static let answerSpread: Int64 = 2 * 60 * 1_000_000

    nonisolated struct Heard: Equatable, Sendable {
        let clock: Int64
        let arrivedAt: Int64
    }

    nonisolated struct Readings: Equatable, Sendable {
        var lastIssued: Int64 = 0
        var lastSeen: Int64 = 0
        var heard: Heard?
    }

    /// The last stamp issued moved down from `top`, and no stamp issued since is below `ceiling`.
    nonisolated struct PullBack: Equatable, Sendable {
        let ceiling: Int64
        let top: Int64

        /// A time from before the pull-back, more than `backendLead` past `ceiling` and at most the
        /// next stamp after `top`, moves down by the pull-back's size: to at most `ceiling` plus one,
        /// in the order it had. Stamps issued in the five seconds after it stay within `backendLead`
        /// past `ceiling`, so a holder restamping then leaves them.
        func restamped(_ date: Date) -> Date {
            let value = PushAPI.clock(of: date)
            guard value > ceiling + SyncClock.backendLead, value <= top + 1 else { return date }
            return PushAPI.date(ofClock: value - (top - ceiling))
        }
    }

    /// The pull-backs made before a time was taken: read it first, then take the time.
    nonisolated struct Era: Sendable {
        let clock: SyncClock
        let pullBacks: Int

        /// `date`, taken in this era, moved as `restamp(after:)` moved the times kept since.
        func current(_ date: Date) -> Date {
            clock.pullBacks.withLock { Array($0.dropFirst(pullBacks)) }.reduce(date) { $1.restamped($0) }
        }
    }

    /// Only one process may use a store: the lock that keeps stamps apart is in memory.
    nonisolated struct Storage: Sendable {
        let load: @Sendable () -> Readings
        let save: @Sendable (Readings) -> Void

        static let defaults = Storage(
            load: {
                let heard = Defaults[.syncClockHeard].flatMap { clock in
                    Defaults[.syncClockHeardAt].map { Heard(clock: clock, arrivedAt: $0) }
                }
                return Readings(lastIssued: Defaults[.syncClockLastIssued], lastSeen: Defaults[.syncClockLastSeen], heard: heard)
            },
            save: { readings in
                Defaults[.syncClockLastIssued] = readings.lastIssued
                Defaults[.syncClockLastSeen] = readings.lastSeen
                Defaults[.syncClockHeard] = readings.heard?.clock
                Defaults[.syncClockHeardAt] = readings.heard?.arrivedAt
            }
        )
    }

    private let storage: Storage
    private let now: @Sendable () -> Date
    private let held = OSAllocatedUnfairLock(initialState: Readings())
    private let restampers = OSAllocatedUnfairLock<[@Sendable (PullBack) async -> Void]>(initialState: [])
    private let pullBacks = OSAllocatedUnfairLock<[PullBack]>(initialState: [])

    init(storage: Storage = .defaults, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.now = now
    }

    var era: Era {
        Era(clock: self, pullBacks: pullBacks.withLock(\.count))
    }

    var readings: Readings {
        held.withLock { Self.merged($0, storage.load()) }
    }

    /// Every stamp issued before this read is below it, and every one issued after is not.
    var lowestNextStamp: Date {
        PushAPI.date(ofClock: min(readings.lastIssued, Self.overflowSafeCeiling - 1) + 1)
    }

    /// A local event's time, for comparing with stamps and with `lowestNextMark`: later than every
    /// stamp issued before it, and never before the device's clock.
    func mark() -> Date {
        max(now(), stamp())
    }

    /// Every mark taken before this read is at or below it, and every one taken after is at or above it.
    var lowestNextMark: Date {
        max(now(), lowestNextStamp)
    }

    func stamp() -> Date {
        PushAPI.date(ofClock: update { readings in
            let device = PushAPI.clock(of: now())
            let backend = readings.heard.map { $0.clock + (device - $0.arrivedAt) + Self.backendLead }
            let latest = max(min(device, backend ?? device), readings.lastSeen, readings.lastIssued)
            readings.lastIssued = min(latest, Self.overflowSafeCeiling - 1) + 1
            return readings.lastIssued
        })
    }

    /// A last stamp or last server value further ahead of `serverClock` than any answer could be,
    /// as after a device clock set ahead, comes back to what the backend accepts: it refuses a
    /// stamp past its clock plus `backendLead`, so no stamp above that has landed. The caller
    /// passes the pull-back it returns to `restamp(after:)`.
    @discardableResult
    func hear(_ serverClock: Int64) -> PullBack? {
        let arrivedAt = PushAPI.clock(of: now())
        guard Self.plausible.contains(serverClock) else { return nil }
        return update { readings in
            let reach = serverClock + Self.backendLead
            let farAhead = reach + Self.answerSpread
            readings.lastSeen = readings.lastSeen > farAhead ? serverClock : max(readings.lastSeen, serverClock)
            readings.heard = Heard(clock: serverClock, arrivedAt: arrivedAt)
            guard readings.lastIssued > farAhead else { return nil }
            let pullBack = PullBack(ceiling: max(reach, readings.lastSeen), top: readings.lastIssued)
            readings.lastIssued = reach
            pullBacks.withLock { $0.append(pullBack) }
            return pullBack
        }
    }

    /// `restamp` moves every time it keeps with `PullBack.restamped`.
    func onPullBack(_ restamp: @escaping @Sendable (PullBack) async -> Void) {
        restampers.withLock { $0.append(restamp) }
    }

    func restamp(after pullBack: PullBack) async {
        for restamp in restampers.withLock({ $0 }) { await restamp(pullBack) }
    }

    @discardableResult
    private func update<Result>(_ change: (inout Readings) -> Result) -> Result {
        held.withLockUnchecked { kept in
            let before = Self.merged(kept, storage.load())
            var readings = before
            let result = change(&readings)
            // UserDefaults reads empty before the first unlock, so only a pull-back may save a
            // value below the stored one.
            var saved = Self.merged(readings, storage.load())
            if readings.lastIssued < before.lastIssued { saved.lastIssued = readings.lastIssued }
            if readings.lastSeen < before.lastSeen { saved.lastSeen = readings.lastSeen }
            kept = saved
            storage.save(saved)
            return result
        }
    }

    private static func merged(_ kept: Readings, _ stored: Readings) -> Readings {
        Readings(
            lastIssued: max(kept.lastIssued, stored.lastIssued),
            lastSeen: max(kept.lastSeen, stored.lastSeen),
            heard: [kept.heard, stored.heard].lazy.compactMap { $0 }.first {
                plausible.contains($0.clock) && plausible.contains($0.arrivedAt)
            }
        )
    }
}
