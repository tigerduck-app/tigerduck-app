import Foundation
import Testing
@testable import TigerDuck

/// The clock NTUST publishes for its 14 teaching periods. Asserted verbatim
/// because every other time in the app — slot spans, "current class", widget
/// timelines — is derived from it, so a single typo here is silently wrong
/// everywhere at once.
struct PeriodScheduleTests {
    private static let published: [(String, String, String)] = [
        ("1", "08:10", "09:00"),
        ("2", "09:10", "10:00"),
        ("3", "10:20", "11:10"),
        ("4", "11:20", "12:10"),
        ("5", "12:20", "13:10"),
        ("6", "13:20", "14:10"),
        ("7", "14:20", "15:10"),
        ("8", "15:30", "16:20"),
        ("9", "16:30", "17:20"),
        ("10", "17:30", "18:20"),
        ("A", "18:25", "19:15"),
        ("B", "19:20", "20:10"),
        ("C", "20:15", "21:05"),
        ("D", "21:10", "22:00"),
    ]

    @Test func periodTimes_matchThePublishedTimetable() {
        for (id, start, end) in Self.published {
            let times = AppConstants.PeriodTimes.mapping[id]
            #expect(times?.start == start, "period \(id) start")
            #expect(times?.end == end, "period \(id) end")
        }
        #expect(AppConstants.PeriodTimes.mapping.count == Self.published.count)
    }

    /// `chronologicalOrder` is what every grid sorts by; if it ever drifts out
    /// of clock order, rows render shuffled with no other symptom.
    @Test func chronologicalOrder_isActuallyChronological() {
        let minutes = AppConstants.Periods.chronologicalOrder.map { id -> (Int, Int) in
            guard let t = AppConstants.PeriodTimes.mapping[id] else {
                Issue.record("period \(id) has no time")
                return (0, 0)
            }
            return (Self.minuteOfDay(t.start), Self.minuteOfDay(t.end))
        }
        for (previous, current) in zip(minutes, minutes.dropFirst()) {
            #expect(previous.0 < previous.1, "period ends before it starts")
            #expect(previous.1 <= current.0, "periods overlap or run backwards")
        }
    }

    /// The "always show all periods" toggle unions in `chronologicalOrder`, so
    /// the default rows have to be a subset of it or the toggle would drop rows.
    @Test func defaultVisible_isSubsetOfChronologicalOrder() {
        #expect(Set(AppConstants.Periods.defaultVisible)
            .isSubset(of: Set(AppConstants.Periods.chronologicalOrder)))
    }

    private static func minuteOfDay(_ hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return -1 }
        return parts[0] * 60 + parts[1]
    }
}
