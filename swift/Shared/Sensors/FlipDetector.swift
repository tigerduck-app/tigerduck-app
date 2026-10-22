#if os(iOS)
import CoreMotion
import Foundation

final class FlipDetector {

    static let faceDownThreshold: Double = 0.85

    static let debounceInterval: TimeInterval = 0.4

    static let maxEventGap: TimeInterval = 1.0

    enum Phase: nonisolated Equatable { case unknown, upright, faceDown }

    struct State: Equatable {
        var phase: Phase
        var pendingFaceDown: Bool
        var windowStart: TimeInterval?
        var lastTimestamp: TimeInterval?
        var didFire: Bool

        static let initial = State(
            phase: .unknown,
            pendingFaceDown: false,
            windowStart: nil,
            lastTimestamp: nil,
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
    private let stateLock = NSLock()
    private var state = State.initial
    private var isActive = false

    init(onFaceDown: @escaping () -> Void) {
        self.onFaceDown = onFaceDown
    }

    deinit {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }

    static let isSupported: Bool = CMMotionManager().isDeviceMotionAvailable

    func start() {
        guard !motionManager.isDeviceMotionActive else { return }
        guard motionManager.isDeviceMotionAvailable else { return }
        stateLock.lock()
        state = .initial
        isActive = true
        stateLock.unlock()
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(gravityZ: motion.gravity.z, timestamp: motion.timestamp)
        }
    }

    func stop() {
        guard motionManager.isDeviceMotionActive else { return }
        stateLock.lock()
        isActive = false
        state = .initial
        stateLock.unlock()
        motionManager.stopDeviceMotionUpdates()
    }

    private func handle(gravityZ: Double, timestamp: TimeInterval) {
        let faceDown = Self.isFaceDown(gravityZ: gravityZ)
        let didFire: Bool = {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard isActive else { return false }
            state = Self.nextState(current: state, isFaceDown: faceDown, timestamp: timestamp)
            return state.didFire
        }()
        if didFire {
            DispatchQueue.main.async { [weak self] in self?.onFaceDown() }
        }
    }

    static func isFaceDown(gravityZ: Double) -> Bool {
        gravityZ >= faceDownThreshold
    }

    static func nextState(
        current: State,
        isFaceDown: Bool,
        timestamp: TimeInterval
    ) -> State {
        var next = current
        next.lastTimestamp = timestamp
        let discontinuity: Bool = {
            guard let last = current.lastTimestamp else { return false }
            let gap = timestamp - last
            return gap > maxEventGap || gap < 0
        }()
        if next.windowStart == nil || isFaceDown != next.pendingFaceDown || discontinuity {
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
