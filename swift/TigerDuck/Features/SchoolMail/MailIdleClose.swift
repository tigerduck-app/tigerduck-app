#if os(iOS)
import Foundation

@MainActor
final class MailIdleClose {
    private let delay: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var task: Task<Void, Never>?
    private var armCount = 0

    init(delay: Duration, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.delay = delay
        self.sleep = sleep
    }

    func arm(_ fire: @escaping @MainActor () async -> Void) {
        task?.cancel()
        armCount += 1
        let armed = armCount
        let delay = self.delay
        let sleep = self.sleep
        task = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self, armed == self.armCount else { return }
            await fire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        armCount += 1
    }
}

final class MailNotificationListener {
    private let center: NotificationCenter
    nonisolated(unsafe) private var token: (any NSObjectProtocol)?

    init(center: NotificationCenter, name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
#endif
