#if os(iOS)
import Accessibility
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

    struct BackgroundGrant {
        let isExpired: @MainActor () -> Bool
        let end: @MainActor () -> Void
    }

    static let shared = MailSendHold()
    static let seconds: TimeInterval = 5

    private(set) var held: Held?
    private(set) var reopened: [MailComposeViewModel] = []
    private(set) var deliveries = 0
    @ObservationIgnored private var countdown: Task<Void, Never>?
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private let beginBackgroundTask: @MainActor () -> BackgroundGrant
    @ObservationIgnored private let announce: @MainActor () -> Void
    @ObservationIgnored private var listeners: [MailNotificationListener] = []

    init(
        sleep: @escaping (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) },
        beginBackgroundTask: @escaping @MainActor () -> BackgroundGrant = {
            let task = AppBackgroundTask(named: "School Mail send")
            return BackgroundGrant(isExpired: { task.isExpired }, end: { task.end() })
        },
        announce: @escaping @MainActor () -> Void = { MailSendHold.announceHold() },
        events: NotificationCenter = .default
    ) {
        self.sleep = sleep
        self.beginBackgroundTask = beginBackgroundTask
        self.announce = announce
        // Undo is out of reach from the background, where iOS may end the app with the mail
        // still held, so it goes at once.
        listeners = [
            MailNotificationListener(center: events, name: UIApplication.didEnterBackgroundNotification) { [weak self] in
                self?.sendNow()
            },
            MailNotificationListener(center: events, name: MailAccountManager.didSignOut) { [weak self] in self?.drop() },
        ]
    }

    @discardableResult
    func hold(_ model: MailComposeViewModel) -> Bool {
        if held?.model === model { return true }
        guard !model.isSending, !model.shouldClose else { return false }
        sendNow()
        held = Held(model: model, until: Date().addingTimeInterval(Self.seconds))
        listsDraft(of: model, false)
        announce()
        countdown = Task {
            await self.sleep(.seconds(Self.seconds))
            guard !Task.isCancelled else { return }
            self.sendNow()
        }
        return true
    }

    func undo() {
        guard let model = release() else { return }
        listsDraft(of: model, true)
        reopened.append(model)
    }

    func takeReopened() -> MailComposeViewModel? {
        reopened.isEmpty ? nil : reopened.removeFirst()
    }

    private func sendNow() {
        guard let model = release() else { return }
        let grant = beginBackgroundTask()
        Task { await self.deliver(model, grant: grant) }
    }

    private func drop() {
        _ = release()
        reopened.removeAll()
    }

    private func release() -> MailComposeViewModel? {
        countdown?.cancel()
        countdown = nil
        defer { held = nil }
        return held?.model
    }

    private func deliver(_ model: MailComposeViewModel, grant: BackgroundGrant) async {
        await model.send(unless: grant.isExpired)
        grant.end()
        deliveries += 1
        if !model.didFinish, !model.mayHaveSent { listsDraft(of: model, true) }
        if !model.shouldClose { reopened.append(model) }
    }

    private func listsDraft(of model: MailComposeViewModel, _ isListed: Bool) {
        guard let id = model.draftID else { return }
        model.events.post(.draftHidden(id, isHidden: !isListed))
    }

    // A high priority keeps VoiceOver from cutting the announcement for the focus change the
    // closing composer brings.
    static func announceHold() {
        var text = AttributedString(String(localized: "school_mail_sending_hold"))
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
    }
}
#endif
