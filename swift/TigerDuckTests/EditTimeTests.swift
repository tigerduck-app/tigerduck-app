import Foundation
import Testing
@testable import TigerDuck

struct EditTimeTests {
    private static func time(_ wall: TimeInterval, boot: TimeInterval?) -> EditTime {
        EditTime(wall: Date(timeIntervalSince1970: 1_790_000_000 + wall), sinceBoot: boot)
    }

    @Test("Within one boot an edit ages by the clock since boot, though the time was set an hour on or back", arguments: [3600.0, -3600])
    func ageWithinABootIgnoresTheTimeBeingSet(_ shift: TimeInterval) {
        let made = Self.time(0, boot: 5 * 86_400)

        #expect(made.seconds(until: Self.time(30 + shift, boot: 5 * 86_400 + 30)) == 30)
        #expect(made.ageMilliseconds(at: Self.time(30 + shift, boot: 5 * 86_400 + 30)) == 30_000)
    }

    @Test("Across a restart an edit ages by the wall clock, whether the new boot has run less or longer", arguments: [60.0, 3000])
    func ageAcrossARestartTakesTheWallClock(_ newBoot: TimeInterval) {
        #expect(Self.time(0, boot: 500).seconds(until: Self.time(7200, boot: newBoot)) == 7200)
    }

    @Test("An edit with no clock since boot, as an earlier build queued it, ages by the wall clock")
    func editWithoutABootClockAgesByTheWallClock() {
        #expect(Self.time(0, boot: nil).seconds(until: Self.time(30, boot: 999)) == 30)
        #expect(Self.time(0, boot: 500).seconds(until: Self.time(30, boot: nil)) == 30)
    }

    @Test("An age is never negative")
    func ageIsNeverNegative() {
        #expect(Self.time(30, boot: nil).ageMilliseconds(at: Self.time(0, boot: nil)) == 0)
    }

    @Test("A stamp taken just now reads the clock since boot, and one older than this boot reads none")
    func stampedReadsTheBootClock() {
        let now = EditTime.now()
        let stamped = EditTime.stamped(now.wall)

        #expect(stamped.wall == now.wall)
        #expect(stamped.sinceBoot != nil)
        #expect(abs(stamped.seconds(until: now)) < 1)
        #expect(EditTime.stamped(Date(timeIntervalSince1970: 0)).sinceBoot == nil)
    }
}
