#if DEBUG
import Foundation
import os

/// Reports main-thread stalls and how long they last. DEBUG-only scaffolding, cheap at one
/// timer and one empty main-queue block per tick; delete once the Library freeze is understood.
///
/// A `ProgressView` spinner is a CoreAnimation animation the render server drives, so it keeps
/// turning while the main thread is blocked. A frozen screen with a moving spinner fits a
/// blocked main thread and touches swallowed in the view hierarchy alike, and the two need
/// unrelated fixes. A long wait for the empty block means the main thread was busy at least
/// that long; silence during a freeze means it was healthy and the touches went elsewhere.
enum MainThreadWatchdog {
    private static let log = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "Hang"
    )

    /// Below this, a stall is ordinary work — a heavy frame, a decode — and
    /// logging it would bury the interesting ones.
    private static let threshold: TimeInterval = 0.5
    private static let interval: TimeInterval = 0.25
    /// Long enough that a genuine hang is reported rather than waited out.
    private static let giveUpAfter: TimeInterval = 5

    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    static func start() {
        guard timer == nil else { return }
        let queue = DispatchQueue(label: "org.ntust.app.TigerDuck.hang-watchdog")
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler {
            let sentAt = CFAbsoluteTimeGetCurrent()
            let replied = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { replied.signal() }

            if replied.wait(timeout: .now() + giveUpAfter) == .timedOut {
                log.error("main thread unresponsive for over \(Int(giveUpAfter), privacy: .public)s")
                // Wait it out before the next tick, so one hang produces one
                // report rather than a tick's worth of duplicates.
                replied.wait()
                let total = CFAbsoluteTimeGetCurrent() - sentAt
                log.error("main thread recovered after \(Int(total * 1000), privacy: .public)ms")
                return
            }

            let waited = CFAbsoluteTimeGetCurrent() - sentAt
            if waited > threshold {
                log.error("main thread stalled \(Int(waited * 1000), privacy: .public)ms")
            }
        }
        source.resume()
        timer = source
    }
}
#endif
