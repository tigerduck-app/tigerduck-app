#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct LibraryBrightnessCoordinatorTests {

    private final class FakePanel: BrightnessControllable {
        var brightness: CGFloat
        init(_ brightness: CGFloat) { self.brightness = brightness }
    }

    @Test
    func boostPinsTheScreenAndReleaseRestoresIt() {
        let panel = FakePanel(0.4)
        let c = LibraryBrightnessCoordinator()
        let token = UUID()

        c.boost(panel, token: token)
        #expect(panel.brightness == 1.0)

        c.release(token: token)
        #expect(panel.brightness == 0.4)
    }

    @Test
    func secondHolderDoesNotCaptureTheBoostedValue() {
        let panel = FakePanel(0.4)
        let c = LibraryBrightnessCoordinator()
        let a = UUID(), b = UUID()

        c.boost(panel, token: a)
        c.boost(panel, token: b)
        #expect(panel.brightness == 1.0)

        c.release(token: a)
        #expect(panel.brightness == 1.0, "one holder left — the panel stays pinned")

        c.release(token: b)
        #expect(panel.brightness == 0.4, "must be the user's value, not the boosted one")
    }

    @Test
    func repeatedBoostsFromOneHolderStillRestoreTheOriginal() {
        let panel = FakePanel(0.25)
        let c = LibraryBrightnessCoordinator()
        let token = UUID()

        c.boost(panel, token: token)
        c.boost(panel, token: token)
        c.boost(panel, token: token)
        c.release(token: token)
        #expect(panel.brightness == 0.25)
    }

    @Test
    func movingToAnotherScreenRestoresTheOneBeingLeft() {
        let inner = FakePanel(0.4), outer = FakePanel(0.7)
        let c = LibraryBrightnessCoordinator()
        let token = UUID()

        c.boost(inner, token: token)
        c.boost(outer, token: token)
        #expect(inner.brightness == 0.4, "the display we left must not stay pinned")
        #expect(outer.brightness == 1.0)

        c.release(token: token)
        #expect(outer.brightness == 0.7)
    }

    @Test
    func claimsOnSeparateDisplaysDoNotEvictEachOther() {
        let first = FakePanel(0.4), second = FakePanel(0.7)
        let c = LibraryBrightnessCoordinator()
        let a = UUID(), b = UUID()

        c.boost(first, token: a)
        c.boost(second, token: b)
        #expect(first.brightness == 1.0, "still showing a code — must stay pinned")
        #expect(second.brightness == 1.0)

        c.release(token: b)
        #expect(second.brightness == 0.7)
        #expect(first.brightness == 1.0, "releasing one display must not touch the other")

        c.release(token: a)
        #expect(first.brightness == 0.4)
    }

    @Test
    func releasingAnUnknownTokenLeavesAnActiveBoostAlone() {
        let panel = FakePanel(0.4)
        let c = LibraryBrightnessCoordinator()
        let held = UUID()

        c.boost(panel, token: held)
        c.release(token: UUID())
        #expect(panel.brightness == 1.0)

        c.release(token: held)
        #expect(panel.brightness == 0.4)
    }

    @Test
    func aDeallocatedScreenDropsTheOverrideCleanly() {
        let c = LibraryBrightnessCoordinator()
        let token = UUID()
        do {
            let transient = FakePanel(0.5)
            c.boost(transient, token: token)
            #expect(transient.brightness == 1.0)
        }
        c.release(token: token)

        let next = FakePanel(0.3)
        c.boost(next, token: token)
        #expect(next.brightness == 1.0)
        c.release(token: token)
        #expect(next.brightness == 0.3)
    }
}
#endif
