#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// Tests for `FlipDetector`'s pure debounce machine. The CoreMotion glue
/// (`start` / `stop`) is intentionally not exercised — `nextState` is the
/// piece with non-trivial branching, and the file header documents it as
/// designed to be unit-testable.
struct FlipDetectorTests {

    private static let debounce = FlipDetector.debounceInterval
    private static let pastDebounce = debounce + 0.05

    // MARK: - isFaceDown

    @Test
    func isFaceDown_atAndAboveThreshold_isTrue() {
        #expect(FlipDetector.isFaceDown(gravityZ: FlipDetector.faceDownThreshold))
        #expect(FlipDetector.isFaceDown(gravityZ: 0.99))
        #expect(FlipDetector.isFaceDown(gravityZ: 1.0))
    }

    @Test
    func isFaceDown_belowThreshold_isFalse() {
        #expect(!FlipDetector.isFaceDown(gravityZ: FlipDetector.faceDownThreshold - 0.0001))
        #expect(!FlipDetector.isFaceDown(gravityZ: 0.0))
        #expect(!FlipDetector.isFaceDown(gravityZ: -1.0))
    }

    // MARK: - nextState — cold start (Unknown phase)

    /// Documented invariant: opening the app with the phone already face-down
    /// must NOT auto-fire. The first event anchors the window; once the
    /// debounce has elapsed, we commit to `.faceDown` but `didFire` stays
    /// false because the previous phase was `.unknown`, not `.upright`.
    @Test
    func coldStart_phoneAlreadyFaceDown_doesNotFire() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 0)
        #expect(!s.didFire)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: Self.pastDebounce)
        #expect(s.phase == .faceDown)
        #expect(!s.didFire, "Unknown → FaceDown must never fire onFaceDown")
    }

    @Test
    func coldStart_phoneUpright_doesNotFire() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)
        #expect(!s.didFire)
    }

    // MARK: - nextState — the actual flip

    /// Upright → FaceDown (held past debounce) is the ONE transition that
    /// fires. This is the whole point of the detector.
    @Test
    func upright_thenFaceDown_pastDebounce_fires() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce)
        #expect(s.phase == .faceDown)
        #expect(s.didFire)
    }

    // MARK: - nextState — debounce filters flicker

    @Test
    func flicker_underDebounce_doesNotFire() {
        var s = FlipDetector.State.initial
        // Establish upright phase.
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        // Brief face-down spike (0.1s) — predicate flips back before debounce.
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.1)
        #expect(!s.didFire)
        #expect(s.phase == .upright, "phase must not have committed mid-flicker")

        // Back to upright, also brief.
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 1.2)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 1.3)
        #expect(!s.didFire)
        #expect(s.phase == .upright)
    }

    // MARK: - nextState — second flip after returning upright

    @Test
    func faceDown_thenUpright_thenFaceDown_firesTwice() {
        var s = FlipDetector.State.initial
        // Cold start upright.
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        // First flip down — fires.
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce)
        #expect(s.didFire)

        // Return upright — no fire.
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 2.0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 2.0 + Self.pastDebounce)
        #expect(s.phase == .upright)
        #expect(!s.didFire)

        // Second flip down — fires again.
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 3.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 3.0 + Self.pastDebounce)
        #expect(s.didFire)
    }

    // MARK: - nextState — discontinuity / wake-from-sleep

    /// If consecutive events arrive with a gap greater than `maxEventGap`,
    /// treat the new event as a fresh window — otherwise a long sleep would
    /// make `timestamp - windowStart` instantly exceed `debounceInterval`
    /// and fire on the very first post-wake read.
    @Test
    func wakeFromSleep_largeGap_resetsWindow() {
        var s = FlipDetector.State.initial
        // Establish upright.
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        // Long sleep gap — single face-down event arrives much later.
        let postSleep = 100.0
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: postSleep)
        #expect(!s.didFire, "single post-wake event must not instantly fire")
        #expect(s.phase == .upright, "phase must not have committed off a single event")

        // Sustaining face-down past debounce after the discontinuity fires
        // normally — the debounce restarts from `postSleep`, not from the
        // pre-sleep window.
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: postSleep + Self.pastDebounce)
        #expect(s.didFire)
        #expect(s.phase == .faceDown)
    }

    @Test
    func backwardsTimestamp_resetsWindow() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 10.0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 10.0 + Self.pastDebounce)
        #expect(s.phase == .upright)

        // Negative delta — treated as discontinuity.
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 5.0)
        #expect(!s.didFire)
        #expect(s.phase == .upright)
    }

    // MARK: - nextState — identical timestamps

    @Test
    func identicalTimestamps_noFire() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        // Repeat the same event twice — zero elapsed, must not fire.
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        let twin = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        #expect(!twin.didFire)
        #expect(twin.phase == .upright)
    }

    // MARK: - nextState — already in target phase

    @Test
    func sustainedFaceDown_firesExactlyOnce() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce)
        #expect(s.didFire)

        // Subsequent sustained face-down events past the original window
        // must not re-fire — already committed to .faceDown.
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce + 0.05)
        #expect(!s.didFire)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce + 0.10)
        #expect(!s.didFire)
    }
}
#endif
