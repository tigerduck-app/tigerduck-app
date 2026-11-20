#if os(iOS)
import Testing
import UIKit

// UIKit has no public call that delivers a touch, so this hands it a digitizer event as the screen
// does, through private IOKit, BackBoardServices and UIKit calls, the ones
// https://github.com/lyft/Hammer makes.
@MainActor
func fingerTap(at point: CGPoint, in window: UIWindow, holding: Duration = .milliseconds(50)) async throws {
    let finger = try Finger(in: window)
    try finger.down(at: point)
    try await Task.sleep(for: holding)
    try finger.up(at: point)
}

/// One finger that stays down while it slides, for a press that opens a menu and picks from it.
@MainActor
struct Finger {
    private let digitizer: Digitizer
    private let touch: UInt32
    private let window: UIWindow

    init(in window: UIWindow) throws {
        digitizer = try Digitizer()
        Digitizer.lastTouchID += 1
        touch = Digitizer.lastTouchID
        self.window = window
    }

    func down(at point: CGPoint) throws {
        try digitizer.send(touch: touch, at: point, phase: .down, to: window)
    }

    func up(at point: CGPoint) throws {
        try digitizer.send(touch: touch, at: point, phase: .up, to: window)
    }

    /// Slides in small steps, as a finger reports its way across the glass, and ends on its last
    /// step, so a lift right after it leaves with the speed of the slide.
    func slide(from start: CGPoint, to end: CGPoint, steps: Int = 12, pause: Duration = .milliseconds(16)) async throws {
        for step in 1...steps {
            try await Task.sleep(for: pause)
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
            try digitizer.send(touch: touch, at: point, phase: .moved, to: window)
        }
    }
}

/// Moves a finger from `start` to `end` in even steps over `duration` and lifts it at once, so the
/// speed it ends with is the distance over the duration.
@MainActor
func fingerDrag(from start: CGPoint, to end: CGPoint, over duration: Duration, in window: UIWindow, steps: Int = 12) async throws {
    let finger = try Finger(in: window)
    try finger.down(at: start)
    try await finger.slide(from: start, to: end, steps: steps, pause: duration / steps)
    try finger.up(at: end)
}

@MainActor
private struct Digitizer {
    private typealias CreateHandEvent = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Bool, Bool, UInt32
    ) -> Unmanaged<AnyObject>
    private typealias CreateFingerEvent = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32,
        CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Bool, Bool, UInt32
    ) -> Unmanaged<AnyObject>
    private typealias SetInteger = @convention(c) (AnyObject, UInt32, Int) -> Void
    private typealias SetFloat = @convention(c) (AnyObject, UInt32, CGFloat) -> Void
    private typealias Append = @convention(c) (AnyObject, AnyObject, UInt32) -> Void
    private typealias SetSender = @convention(c) (AnyObject, UInt64) -> Void
    private typealias SetDigitizerInfo = @convention(c) (
        AnyObject, UInt32, Bool, Bool, CFString?, CFTimeInterval, Float
    ) -> Void
    private typealias ContextID = @convention(c) (AnyObject, Selector) -> UInt32

    static var lastTouchID: UInt32 = 0

    private static let handTransducer: UInt32 = 3
    private static let rightIndexFinger: UInt32 = 2
    private static let rangeMask: UInt32 = 1 << 0
    private static let touchMask: UInt32 = 1 << 1
    private static let positionMask: UInt32 = 1 << 2
    private static let majorRadiusField: UInt32 = 0xB0014
    private static let minorRadiusField: UInt32 = 0xB0015
    private static let displayIntegratedField: UInt32 = 0xB0019
    private static let fingerRadius: CGFloat = 5
    private static let senderID: UInt64 = 0x1_2345_6789

    private let createHandEvent: CreateHandEvent
    private let createFingerEvent: CreateFingerEvent
    private let setInteger: SetInteger
    private let setFloat: SetFloat
    private let append: Append
    private let setSender: SetSender
    private let setDigitizerInfo: SetDigitizerInfo

    init() throws {
        let ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"
        let backBoard = "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices"
        createHandEvent = try Self.function("IOHIDEventCreateDigitizerEvent", in: ioKit)
        createFingerEvent = try Self.function("IOHIDEventCreateDigitizerFingerEvent", in: ioKit)
        setInteger = try Self.function("IOHIDEventSetIntegerValue", in: ioKit)
        setFloat = try Self.function("IOHIDEventSetFloatValue", in: ioKit)
        append = try Self.function("IOHIDEventAppendEvent", in: ioKit)
        setSender = try Self.function("IOHIDEventSetSenderID", in: ioKit)
        setDigitizerInfo = try Self.function("BKSHIDEventSetDigitizerInfo", in: backBoard)
    }

    enum Phase { case down, moved, up }

    func send(touch id: UInt32, at point: CGPoint, phase: Phase, to window: UIWindow) throws {
        let time = mach_absolute_time()
        let isDown = phase != .up
        let changed = phase == .moved ? Self.positionMask : Self.touchMask
        let hand = createHandEvent(
            nil, time, Self.handTransducer, 0, 0, changed, 0, 0, 0, 0, 0, 0, false, isDown, 0
        ).takeRetainedValue()
        setInteger(hand, Self.displayIntegratedField, 1)
        setSender(hand, Self.senderID)
        let finger = createFingerEvent(
            nil, time, id, Self.rightIndexFinger, phase == .moved ? Self.positionMask : Self.rangeMask | Self.touchMask,
            point.x, point.y, 0, 0, 0, isDown, isDown, 0
        ).takeRetainedValue()
        setFloat(finger, Self.majorRadiusField, Self.fingerRadius)
        setFloat(finger, Self.minorRadiusField, Self.fingerRadius)
        append(hand, finger, 0)
        setDigitizerInfo(hand, try Self.contextID(of: window), false, false, nil, 0, 0)

        let enqueue = NSSelectorFromString("_enqueueHIDEvent:")
        try #require(UIApplication.shared.responds(to: enqueue))
        UIApplication.shared.perform(enqueue, with: hand)
    }

    private static func contextID(of window: UIWindow) throws -> UInt32 {
        let selector = NSSelectorFromString("_contextId")
        try #require(window.responds(to: selector))
        return unsafeBitCast(window.method(for: selector), to: ContextID.self)(window, selector)
    }

    private static func function<Function>(_ name: String, in path: String) throws -> Function {
        let library = try #require(dlopen(path, RTLD_NOW))
        return unsafeBitCast(try #require(dlsym(library, name)), to: Function.self)
    }
}
#endif
