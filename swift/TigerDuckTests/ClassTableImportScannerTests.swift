#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// The AVFoundation scanner reports a code on every frame that shows it; the filter lets it
/// through once while it stays in view.
@MainActor
struct RepeatedCodeFilterTests {
    private static let start = Date(timeIntervalSince1970: 1_791_871_500)

    @Test("a code held in front of the camera is let through once, and again after it leaves")
    func heldCodePassesOnce() {
        var filter = RepeatedCodeFilter()
        let first = filter.isNew("A", at: Self.start)
        let held = (1...90).map { frame in
            filter.isNew("A", at: Self.start.addingTimeInterval(Double(frame) / 30))
        }
        let back = filter.isNew("A", at: Self.start.addingTimeInterval(3 + RepeatedCodeFilter.gap + 0.1))

        #expect(first)
        #expect(!held.contains(true))
        #expect(back)
    }

    @Test("two codes in view are each let through once")
    func codesAreApart() {
        var filter = RepeatedCodeFilter()
        let firsts = [filter.isNew("A", at: Self.start), filter.isNew("B", at: Self.start)]
        let next = Self.start.addingTimeInterval(0.1)
        let repeats = [filter.isNew("A", at: next), filter.isNew("B", at: next)]

        #expect(firsts == [true, true])
        #expect(repeats == [false, false])
    }
}
#endif
