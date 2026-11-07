import Foundation

/// When the user made an edit, on the wall clock and on the clock since boot, which counts sleep
/// and does not move when the time is set. The backend stamps an edit with the time it arrives
/// less the `age_ms` it is sent with, so no device time reaches the backend's time line.
nonisolated struct EditTime: Codable, Equatable, Sendable {
    let wall: Date
    var sinceBoot: TimeInterval? = nil
    var boot: String? = nil

    /// The kernel's `kern.bootsessionuuid`, new at every boot.
    static let currentBoot = Sysctl.text(named: "kern.bootsessionuuid")

    static func now() -> EditTime {
        EditTime(
            wall: Date(), sinceBoot: TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
            boot: currentBoot
        )
    }

    static func stamped(_ wall: Date) -> EditTime {
        let now = now()
        guard let sinceBoot = now.sinceBoot.map({ $0 - now.wall.timeIntervalSince(wall) }), sinceBoot > 0 else {
            return EditTime(wall: wall)
        }
        return EditTime(wall: wall, sinceBoot: sinceBoot, boot: now.boot)
    }

    func seconds(until later: EditTime) -> TimeInterval {
        if let boot, boot == later.boot, let start = sinceBoot, let end = later.sinceBoot { return end - start }
        return later.wall.timeIntervalSince(wall)
    }

    func ageMilliseconds(at now: EditTime) -> Int64 {
        Int64(max(0, seconds(until: now)) * 1000)
    }
}
