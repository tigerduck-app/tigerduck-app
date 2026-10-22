#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct FlipDetectorTests {

    private static let debounce = FlipDetector.debounceInterval
    private static let pastDebounce = debounce + 0.05

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

    @Test
    func flicker_underDebounce_doesNotFire() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.1)
        #expect(!s.didFire)
        #expect(s.phase == .upright, "phase must not have committed mid-flicker")

        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 1.2)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 1.3)
        #expect(!s.didFire)
        #expect(s.phase == .upright)
    }

    @Test
    func faceDown_thenUpright_thenFaceDown_firesTwice() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce)
        #expect(s.didFire)

        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 2.0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 2.0 + Self.pastDebounce)
        #expect(s.phase == .upright)
        #expect(!s.didFire)

        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 3.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 3.0 + Self.pastDebounce)
        #expect(s.didFire)
    }

    @Test
    func wakeFromSleep_largeGap_resetsWindow() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        let postSleep = 100.0
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: postSleep)
        #expect(!s.didFire, "single post-wake event must not instantly fire")
        #expect(s.phase == .upright, "phase must not have committed off a single event")

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

        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 5.0)
        #expect(!s.didFire)
        #expect(s.phase == .upright)
    }

    @Test
    func identicalTimestamps_noFire() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        #expect(s.phase == .upright)

        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        let twin = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        #expect(!twin.didFire)
        #expect(twin.phase == .upright)
    }

    @Test
    func sustainedFaceDown_firesExactlyOnce() {
        var s = FlipDetector.State.initial
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: 0)
        s = FlipDetector.nextState(current: s, isFaceDown: false, timestamp: Self.pastDebounce)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce)
        #expect(s.didFire)

        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce + 0.05)
        #expect(!s.didFire)
        s = FlipDetector.nextState(current: s, isFaceDown: true, timestamp: 1.0 + Self.pastDebounce + 0.10)
        #expect(!s.didFire)
    }
}
#endif
