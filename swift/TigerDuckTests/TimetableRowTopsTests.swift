import CoreGraphics
import Testing
@testable import TigerDuck

struct TimetableRowTopsTests {
    private static func rows(_ tops: [String: CGFloat]) -> TimetableRowTops {
        TimetableRowTops(switchCount: 0, tops: tops)
    }

    @Test func followsTheGridWhenTheContentAboveItGoes() {
        let before = Self.rows(["1": -80, "2": -25, "3": 30, "4": 85])
        let after = Self.rows(["1": -230, "2": -175, "3": -120, "4": -65])
        #expect(TimetableRowTops.shift(from: before, to: after, visibleTop: 0) == -150)
    }

    @Test func keepsTheFirstRowAtOrBelowTheTop() {
        let before = Self.rows(["3": -20, "4": 35, "5": 90])
        let after = Self.rows(["3": -20, "Z": 35, "4": 90, "5": 145])
        #expect(TimetableRowTops.shift(from: before, to: after, visibleTop: 0) == 55)
    }

    @Test func keepsTheFirstRowBelowTheBars() {
        let before = Self.rows(["4": 40, "6": 95, "7": 150])
        let after = Self.rows(["4": 40, "5": 95, "6": 150, "7": 205])
        #expect(TimetableRowTops.shift(from: before, to: after, visibleTop: 0) == 0)
        #expect(TimetableRowTops.shift(from: before, to: after, visibleTop: 62) == 55)
    }

    @Test func skipsARowTheOtherClassTableDoesNotHave() {
        let before = Self.rows(["0": 10, "1": 65, "2": 120])
        let after = Self.rows(["1": 10, "2": 65])
        #expect(TimetableRowTops.shift(from: before, to: after, visibleTop: 0) == -55)
    }

    @Test func usesTheLowestRowWhenAllAreAboveTheTop() {
        let before = Self.rows(["9": -100, "10": -45])
        let after = Self.rows(["9": -250, "10": -195])
        #expect(TimetableRowTops.shift(from: before, to: after, visibleTop: 0) == -150)
    }

    @Test func staysWithoutARowInCommon() {
        #expect(TimetableRowTops.shift(from: Self.rows(["1": 10]), to: Self.rows(["A": 10]), visibleTop: 0) == 0)
    }
}
