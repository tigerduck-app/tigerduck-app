#if DEBUG
import Foundation
import os

/// Reports how long the main thread goes unresponsive, and for how long.
///
/// This exists to settle one question about the Library freeze that
/// watching the screen cannot answer. A `ProgressView` spinner is a
/// CoreAnimation animation driven by the render server, so it keeps
/// turning even when the app's main thread is completely blocked.
/// "The screen still moves but nothing responds" is therefore equally
/// consistent with a blocked main thread and with touches being swallowed
/// somewhere in the view hierarchy — and those two have nothing in common
/// as fixes, so guessing between them is how the wrong thing gets fixed.
///
/// A background timer posts an empty block to the main queue and measures
/// how long it waits. A long wait means the main thread was busy for at
/// least that long. **Silence during a freeze is itself the answer**: the
/// main thread was healthy and the touches were going somewhere else.
///
/// DEBUG only, and cheap — one timer, one empty main-queue block per tick.
/// Delete once the Library freeze is understood; it is scaffolding, not a
/// feature.
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
