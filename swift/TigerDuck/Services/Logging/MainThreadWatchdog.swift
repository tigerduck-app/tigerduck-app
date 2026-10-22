#if DEBUG
import Foundation
import os

enum MainThreadWatchdog {
    private static let log = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "Hang"
    )

    private static let threshold: TimeInterval = 0.5
    private static let interval: TimeInterval = 0.25
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
