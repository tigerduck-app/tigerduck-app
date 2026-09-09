import Foundation
import Testing
@testable import TigerDuck

/// The today carousel scrolls itself to whichever class is happening now.
/// The offset is the part that cannot be eyeballed — it is off-screen by
/// definition, and being wrong by one card looks like the feature simply not
/// working.
///
/// Geometry it encodes: a 16pt start inset inside the scrollable content,
/// 140pt ordinary cards, 200pt ongoing ones, 12pt between, and a 36pt sliver
/// of the previous card left visible.
struct CarouselScrollTargetTests {

    private func ordinary(_ count: Int) -> [Bool] { Array(repeating: false, count: count) }

    @Test func nothingOngoingLeavesTheRowAtTheStartOfTheDay() {
        #expect(carouselScrollTarget(isOngoing: ordinary(4), firstOngoingIndex: -1) == 0)
    }

    @Test func anOngoingFirstClassNeedsNoOffset() {
        // Nothing precedes it.
        #expect(carouselScrollTarget(isOngoing: ordinary(4), firstOngoingIndex: 0) == 0)
    }

    @Test func theSecondClassScrollsPastExactlyOneCardLessThePeek() {
        // 16 inset + 140 card + 12 gap - 36 peek
        #expect(carouselScrollTarget(isOngoing: ordinary(4), firstOngoingIndex: 1) == 132)
    }

    @Test func theThirdClassScrollsPastTwo() {
        // 16 + (140 + 12) * 2 - 36
        #expect(carouselScrollTarget(isOngoing: ordinary(4), firstOngoingIndex: 2) == 284)
    }

    @Test func aWiderOngoingCardBeforeItIsCountedAtItsOwnWidth() {
        // Overlapping classes: index 0 is also ongoing, so it is the 200pt
        // card, not the 140pt one. 16 + 200 + 12 - 36.
        #expect(carouselScrollTarget(isOngoing: [true, true, false], firstOngoingIndex: 1) == 192)
    }

    @Test func thePeekNeverScrollsPastTheStartOfTheContent() {
        // A hypothetical card narrower than the peek must not produce a
        // negative offset — the scroll view would clamp it, but the intent is
        // "show the beginning", not "scroll backwards".
        #expect(carouselScrollTarget(isOngoing: [], firstOngoingIndex: 0) == 0)
    }
}
