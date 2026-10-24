#if os(iOS)
import AVFoundation
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

/// The flashlight toggle shows only for a running camera with a torch, and reads what the torch
/// does rather than what was tapped.
@MainActor
struct ScannerTorchTests {
    @Test("a camera without a torch shows no toggle")
    func noTorchNoToggle() {
        #expect(ScannerTorch.Control(hasTorch: false, isAvailable: true, isActive: false) == nil)
    }

    @Test("the toggle reads on only while the torch is lit")
    func toggleFollowsTheTorch() throws {
        let lit = try #require(ScannerTorch.Control(hasTorch: true, isAvailable: true, isActive: true))
        let dark = try #require(ScannerTorch.Control(hasTorch: true, isAvailable: true, isActive: false))

        #expect(lit.isOn && lit.isEnabled)
        #expect(!dark.isOn && dark.isEnabled)
    }

    @Test("a torch too hot to light keeps its toggle, off and disabled")
    func hotTorchIsDisabled() throws {
        let hot = try #require(ScannerTorch.Control(hasTorch: true, isAvailable: false, isActive: false))

        #expect(!hot.isOn)
        #expect(!hot.isEnabled)
    }

    @Test("no toggle before a session runs, for a session without a camera, or after it stops")
    func noRunningCameraNoToggle() {
        let torch = ScannerTorch()
        let before = torch.control

        torch.sessionStarted(AVCaptureSession())
        torch.turn(true)
        let cameraless = torch.control
        torch.sessionStarted(nil)
        torch.sessionStopped()

        #expect(before == nil)
        #expect(cameraless == nil)
        #expect(torch.control == nil)
    }
}
#endif
