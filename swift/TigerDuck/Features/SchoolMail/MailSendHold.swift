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

    struct HiddenDraft: Hashable {
        let id: MailListRow.ID
        let signIn: SignIn
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
    private(set) var hiddenDrafts: Set<HiddenDraft> = []
    @ObservationIgnored private var sending: Set<ObjectIdentifier> = []
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
        if let id = model.context.draftID { hiddenDrafts.insert(HiddenDraft(id: id, signIn: model.signIn)) }
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
        reopened.append(model)
    }

    func hides(_ id: MailListRow.ID, for signIn: SignIn) -> Bool {
        hiddenDrafts.contains(HiddenDraft(id: id, signIn: signIn))
    }

    func composerClosed(_ model: MailComposeViewModel) {
        reopened.removeAll { $0 === model }
        guard held?.model !== model, !sending.contains(ObjectIdentifier(model)), !model.shouldClose else { return }
        if model.hasChanges, !model.status.discarded {
            reopened.insert(model, at: 0)
            return
        }
        guard let id = model.context.draftID, !model.status.mayHaveSent else { return }
        hiddenDrafts.remove(HiddenDraft(id: id, signIn: model.signIn))
    }

    func takeReopened() -> MailComposeViewModel? {
        reopened.isEmpty ? nil : reopened.removeFirst()
    }

    private func sendNow() {
        guard let model = release() else { return }
        let grant = beginBackgroundTask()
        sending.insert(ObjectIdentifier(model))
        Task { await self.deliver(model, grant: grant) }
    }

    private func drop() {
        _ = release()
        reopened.removeAll()
        hiddenDrafts.removeAll()
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
        sending.remove(ObjectIdentifier(model))
        deliveries += 1
        if !model.shouldClose { reopened.append(model) }
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
