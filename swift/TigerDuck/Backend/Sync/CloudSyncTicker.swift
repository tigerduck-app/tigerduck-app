import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class CloudSyncTicker {
    private var started = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var timer: Timer?

    func start(
        every interval: TimeInterval,
        tick: @escaping @MainActor () async -> Void,
        becameActive: @escaping @MainActor () -> Void
    ) {
        guard !started else { return }
        started = true

        #if canImport(UIKit)
        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { becameActive() }
        }
        notificationTokens.append(token)
        #endif

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                await tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens = []
        started = false
    }
}
