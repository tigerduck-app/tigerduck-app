#if os(iOS)
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class MailSendHold {
    struct Held {
        let model: MailComposeViewModel
        let until: Date

        func remaining(at date: Date) -> Double {
            max(0, until.timeIntervalSince(date)) / MailSendHold.seconds
        }
    }

    static let shared = MailSendHold()
    static let seconds: TimeInterval = 5

    private(set) var held: Held?
    private(set) var reopened: MailComposeViewModel?
    private(set) var deliveries = 0
    @ObservationIgnored private var countdown: Task<Void, Never>?
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private let beginBackgroundTask: () async -> @Sendable () async -> Void
    @ObservationIgnored private var listeners: [MailNotificationListener] = []

    init(
        sleep: @escaping (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) },
        beginBackgroundTask: @escaping () async -> @Sendable () async -> Void = {
            await AppBackgroundTask.begin(named: "School Mail send")
        },
        events: NotificationCenter = .default
    ) {
        self.sleep = sleep
        self.beginBackgroundTask = beginBackgroundTask
        // Undo is out of reach from the background, where iOS may end the app with the mail
        // still held, so it goes at once.
        listeners = [
            MailNotificationListener(center: events, name: UIApplication.didEnterBackgroundNotification) { [weak self] in
                self?.sendNow()
            },
            MailNotificationListener(center: events, name: MailAccountManager.didSignOut) { [weak self] in self?.drop() },
        ]
    }

    func hold(_ model: MailComposeViewModel) {
        guard held?.model !== model, !model.isSending, !model.shouldClose else { return }
        sendNow()
        held = Held(model: model, until: Date().addingTimeInterval(Self.seconds))
        countdown = Task {
            await self.sleep(.seconds(Self.seconds))
            guard !Task.isCancelled else { return }
            self.sendNow()
        }
    }

    func undo() {
        guard let model = release() else { return }
        reopened = model
    }

    func takeReopened() -> MailComposeViewModel? {
        defer { reopened = nil }
        return reopened
    }

    private func sendNow() {
        guard let model = release() else { return }
        Task { await self.deliver(model) }
    }

    private func drop() {
        _ = release()
        reopened = nil
    }

    private func release() -> MailComposeViewModel? {
        countdown?.cancel()
        countdown = nil
        defer { held = nil }
        return held?.model
    }

    private func deliver(_ model: MailComposeViewModel) async {
        let endBackgroundTask = await beginBackgroundTask()
        await model.send()
        await endBackgroundTask()
        deliveries += 1
        if !model.shouldClose { reopened = model }
    }
}
#endif
