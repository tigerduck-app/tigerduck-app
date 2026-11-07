import Foundation

/// When the user made an edit, on the wall clock and on the clock since boot, which counts sleep
/// and does not move when the time is set. The backend stamps an edit with the time it arrives
/// less the `age_ms` it is sent with, so no device time reaches the backend's time line.
nonisolated struct EditTime: Codable, Equatable, Sendable {
    let wall: Date
    var sinceBoot: TimeInterval? = nil

    static func now() -> EditTime {
        EditTime(wall: Date(), sinceBoot: TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000)
    }

    static func stamped(_ wall: Date) -> EditTime {
        let now = now()
        let sinceBoot = now.sinceBoot.map { $0 - now.wall.timeIntervalSince(wall) }
        return EditTime(wall: wall, sinceBoot: sinceBoot.flatMap { $0 > 0 ? $0 : nil })
    }

    func seconds(until later: EditTime) -> TimeInterval {
        // iOS gives an app no boot id. A later boot starts after this one has run `start` seconds,
        // so the wall time at boot moves on by more than that; setting the time moves it by the change.
        if let start = sinceBoot, let end = later.sinceBoot, end >= start,
           later.wall.addingTimeInterval(-end).timeIntervalSince(wall.addingTimeInterval(-start)) < start {
            return end - start
        }
        return later.wall.timeIntervalSince(wall)
    }

    func ageMilliseconds(at now: EditTime) -> Int64 {
        Int64(max(0, seconds(until: now)) * 1000)
    }
}
