#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// `UIScreen` cannot be constructed, so the coordinator works against a
/// protocol and these tests drive it with a fake panel. That is the whole
/// reason the seam exists: the bug this type was written to fix only shows
/// up with two holders and a real screen would mean mutating the display
/// brightness of whatever machine the suite runs on.
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

    /// The bug this type exists for. `LibraryView` is built three times —
    /// the Library tab plus the embedded copies Home and More push — so two
    /// instances can boost the same panel. With per-view state the second
    /// captured the already-boosted 1.0 as the "pre-boost" value and the
    /// panel could never be restored.
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

        // onAppear, then a scene-phase change, then a screen report.
        c.boost(panel, token: token)
        c.boost(panel, token: token)
        c.boost(panel, token: token)
        c.release(token: token)
        #expect(panel.brightness == 0.25)
    }

    /// Moving between displays — a fold, or a window dragged to another
    /// screen — has to hand the panel being left its brightness back.
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

    /// Releasing a token nobody registered must not restore anything — the
    /// view calls this unconditionally from teardown paths.
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

    /// A panel can be unplugged while boosted. The coordinator holds it
    /// weakly, so the restore finds nothing and must simply drop the state
    /// rather than write into a dead object or strand the next boost.
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

        // The next boost must capture afresh rather than reuse the stale
        // saved value from the screen that went away.
        let next = FakePanel(0.3)
        c.boost(next, token: token)
        #expect(next.brightness == 1.0)
        c.release(token: token)
        #expect(next.brightness == 0.3)
    }
}
#endif
