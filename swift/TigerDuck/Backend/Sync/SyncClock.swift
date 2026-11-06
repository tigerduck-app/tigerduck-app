import Defaults
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

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
    private let protectedDataReadable: @Sendable () async -> Bool
    private let held = OSAllocatedUnfairLock(initialState: Readings())

    init(
        storage: Storage = .defaults,
        now: @escaping @Sendable () -> Date = { Date() },
        protectedDataReadable: @escaping @Sendable () async -> Bool = { await SyncClock.isProtectedDataAvailable() }
    ) {
        self.storage = storage
        self.now = now
        self.protectedDataReadable = protectedDataReadable
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
    /// stamp past its clock plus `backendLead`, so no stamp above that has landed. Ignored while
    /// protected data is unavailable: before the first unlock `UserDefaults` reads as empty, and a
    /// write then would replace the stored values with lower ones.
    func hear(_ serverClock: Int64) async {
        let arrivedAt = PushAPI.clock(of: now())
        guard Self.plausible.contains(serverClock), await protectedDataReadable() else { return }
        update { readings in
            let reach = serverClock + Self.backendLead
            let farAhead = reach + Self.answerSpread
            readings.lastSeen = readings.lastSeen > farAhead ? serverClock : max(readings.lastSeen, serverClock)
            if readings.lastIssued > farAhead { readings.lastIssued = reach }
            readings.heard = Heard(clock: serverClock, arrivedAt: arrivedAt)
        }
    }

    @discardableResult
    private func update<Result>(_ change: (inout Readings) -> Result) -> Result {
        held.withLockUnchecked { kept in
            var readings = Self.merged(kept, storage.load())
            let result = change(&readings)
            kept = readings
            storage.save(readings)
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

    static func isProtectedDataAvailable() async -> Bool {
        #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        #else
        true
        #endif
    }
}
