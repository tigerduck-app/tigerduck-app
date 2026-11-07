import Foundation
import Testing
@testable import TigerDuck

struct EditTimeTests {
    private static func time(_ wall: TimeInterval, sinceBoot: TimeInterval?, boot: String? = "boot-a") -> EditTime {
        EditTime(wall: Date(timeIntervalSince1970: 1_790_000_000 + wall), sinceBoot: sinceBoot, boot: boot)
    }

    @Test(
        "Within one boot an edit ages by the clock since boot, though the time was set on or back, by more than the boot had run too",
        arguments: [(5 * 86_400.0, 3600.0), (5 * 86_400, -3600), (60, 7200)]
    )
    func ageWithinABootIgnoresTheTimeBeingSet(_ madeSinceBoot: TimeInterval, _ shift: TimeInterval) {
        let made = Self.time(0, sinceBoot: madeSinceBoot)
        let sent = Self.time(30 + shift, sinceBoot: madeSinceBoot + 30)

        #expect(made.seconds(until: sent) == 30)
        #expect(made.ageMilliseconds(at: sent) == 30_000)
    }

    @Test("Across a restart an edit ages by the wall clock, whether the new boot has run less or longer", arguments: [60.0, 3000])
    func ageAcrossARestartTakesTheWallClock(_ newBoot: TimeInterval) {
        #expect(Self.time(0, sinceBoot: 500).seconds(until: Self.time(7200, sinceBoot: newBoot, boot: "boot-b")) == 7200)
    }

    @Test("An edit with no clock since boot or no boot, as an earlier build queued it, ages by the wall clock")
    func editWithoutABootClockAgesByTheWallClock() {
        #expect(Self.time(0, sinceBoot: nil).seconds(until: Self.time(30, sinceBoot: 999)) == 30)
        #expect(Self.time(0, sinceBoot: 500).seconds(until: Self.time(30, sinceBoot: nil)) == 30)
        #expect(Self.time(0, sinceBoot: 500, boot: nil).seconds(until: Self.time(30, sinceBoot: 999, boot: nil)) == 30)
    }

    @Test("An age is never negative")
    func ageIsNeverNegative() {
        #expect(Self.time(30, sinceBoot: nil).ageMilliseconds(at: Self.time(0, sinceBoot: nil)) == 0)
    }

    @Test("A stamp taken just now reads the clock since boot, and one older than this boot reads none")
    func stampedReadsTheBootClock() {
        let now = EditTime.now()
        let stamped = EditTime.stamped(now.wall)

        #expect(now.boot != nil)
        #expect(stamped.wall == now.wall)
        #expect(stamped.sinceBoot != nil)
        #expect(stamped.boot == now.boot)
        #expect(abs(stamped.seconds(until: now)) < 1)
        #expect(EditTime.stamped(Date(timeIntervalSince1970: 0)) == EditTime(wall: Date(timeIntervalSince1970: 0)))
    }
}
