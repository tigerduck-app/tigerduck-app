#if os(iOS)
import CoreMotion
import Foundation

/// Detects a sustained "phone face-down" gesture using CoreMotion's device-
/// motion stream. Pure helpers (`isFaceDown`, `nextState`) carry the math
/// and the debounce machine; the rest is `CMMotionManager` glue.
///
/// Emits exactly one `onFaceDown` callback per Upright → FaceDown transition;
/// flickers under the debounce window are filtered out. The cold-start
/// `Unknown` phase ensures opening the app while the phone is already
/// face-down does NOT auto-fire.
///
/// Phone-only — `CMMotionManager` is iOS-only and the gesture is only wired
/// up under `UIDevice.current.userInterfaceIdiom == .phone`. This mirrors the
/// Android port (`FlipDetector.kt`), modulo the coordinate flip: Android uses
/// `R[8] <= -0.85` on the world-frame screen-normal Z; iOS gravity in the
/// device frame points to +Z when the screen faces the ground, so the same
/// "within ~32° of perfectly inverted" window is `gravity.z >= 0.85`.
final class FlipDetector {

    /// `gravity.z >= faceDownThreshold` captures both "screen facing the
    /// ground" and "within ~32 degrees of flat" in one comparison. Tighter
    /// (more positive) = fewer false positives but harder to trigger.
    static let faceDownThreshold: Double = 0.85

    /// Debounce window — the predicate must hold for at least this long
    /// before a transition is committed.
    static let debounceInterval: TimeInterval = 0.4

    enum Phase { case unknown, upright, faceDown }

    /// Immutable state for the debounce machine.
    struct State: Equatable {
        var phase: Phase
        var pendingFaceDown: Bool
        /// Timestamp (CoreMotion `motion.timestamp`, monotonic seconds since
        /// boot) of the first event in the current window. `nil` before the
        /// first event is delivered.
        var windowStart: TimeInterval?
        /// `true` iff this transition fired the `onFaceDown` callback;
        /// callers consume and reset this on each step.
        var didFire: Bool

        static let initial = State(
            phase: .unknown,
            pendingFaceDown: false,
            windowStart: nil,
            didFire: false
        )
    }

    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "org.ntust.app.TigerDuck.FlipDetector"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let onFaceDown: () -> Void
    private var state = State.initial

    init(onFaceDown: @escaping () -> Void) {
        self.onFaceDown = onFaceDown
    }

    /// `true` iff this device exposes a device-motion sensor we can register
    /// against. Settings reads this to decide whether the toggle is shown.
    static var isSupported: Bool {
        CMMotionManager().isDeviceMotionAvailable
    }

    /// Idempotent. No-op if already active or if the device lacks the sensor.
    func start() {
        guard !motionManager.isDeviceMotionActive else { return }
        guard motionManager.isDeviceMotionAvailable else { return }
        // Reset the state machine each time we (re-)register so a sensor
        // event from a previous session can't leak into the new debounce
        // window.
        state = .initial
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(gravityZ: motion.gravity.z, timestamp: motion.timestamp)
        }
    }

    /// Idempotent.
    func stop() {
        guard motionManager.isDeviceMotionActive else { return }
        motionManager.stopDeviceMotionUpdates()
        state = .initial
    }

    private func handle(gravityZ: Double, timestamp: TimeInterval) {
        let faceDown = Self.isFaceDown(gravityZ: gravityZ)
        state = Self.nextState(current: state, isFaceDown: faceDown, timestamp: timestamp)
        if state.didFire {
            DispatchQueue.main.async { [weak self] in self?.onFaceDown() }
        }
    }

    // MARK: - Pure logic (no CoreMotion dependency)

    static func isFaceDown(gravityZ: Double) -> Bool {
        gravityZ >= faceDownThreshold
    }

    /// Advance the debounce machine by one sensor event.
    ///
    /// The committed `phase` only transitions when the predicate has held for
    /// at least `debounceInterval`. `didFire` is `true` only on the specific
    /// transition Upright → FaceDown; all other transitions (including the
    /// cold-start Unknown → FaceDown) leave `didFire = false`.
    static func nextState(
        current: State,
        isFaceDown: Bool,
        timestamp: TimeInterval
    ) -> State {
        var next = current
        if next.windowStart == nil || isFaceDown != next.pendingFaceDown {
            next.pendingFaceDown = isFaceDown
            next.windowStart = timestamp
            next.didFire = false
            return next
        }
        let elapsed = timestamp - (next.windowStart ?? timestamp)
        if elapsed < debounceInterval {
            next.didFire = false
            return next
        }
        let target: Phase = isFaceDown ? .faceDown : .upright
        if target == next.phase {
            next.didFire = false
            return next
        }
        next.didFire = (next.phase == .upright && target == .faceDown)
        next.phase = target
        return next
    }
}
#endif
