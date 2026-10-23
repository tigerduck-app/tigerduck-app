import Foundation
import Testing
@testable import TigerDuck

struct CarouselScrollTargetTests {

    private func ordinary(_ count: Int) -> [Bool] { Array(repeating: false, count: count) }

    @Test func nothingOngoingLeavesTheRowAtTheStartOfTheDay() {
        #expect(carouselScrollTarget(isOngoing: ordinary(4), firstOngoingIndex: -1) == 0)
    }

    @Test func anOngoingFirstClassNeedsNoOffset() {
        #expect(carouselScrollTarget(isOngoing: ordinary(4), firstOngoingIndex: 0) == 0)
    }

    @Test func theSecondClassScrollsPastExactlyOneCardLessThePeek() {
        #expect(carouselScrollTarget(isOngoing: ordinary(4), firstOngoingIndex: 1) == 132)
    }

    @Test func theThirdClassScrollsPastTwo() {
        #expect(carouselScrollTarget(isOngoing: ordinary(4), firstOngoingIndex: 2) == 284)
    }

    @Test func aWiderOngoingCardBeforeItIsCountedAtItsOwnWidth() {
        #expect(carouselScrollTarget(isOngoing: [true, true, false], firstOngoingIndex: 1) == 192)
    }

    @Test func thePeekNeverScrollsPastTheStartOfTheContent() {
        #expect(carouselScrollTarget(isOngoing: [], firstOngoingIndex: 0) == 0)
    }
}
