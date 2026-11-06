import Defaults
import Foundation
import os

@MainActor
final class HolidaySettingSender {
    var onChange: () -> Void = {}
    private let account: AccountSession
    private let push: PushCoordinator
    private let poller: RevisionPoller
    private var tail: Task<Void, Never>?

    init(account: AccountSession, push: PushCoordinator, poller: RevisionPoller) {
        self.account = account
        self.push = push
        self.poller = poller
    }

    func setHolidayNotify(_ notify: Bool, holidayID: Int, for signIn: SignIn) {
        guard AcademicCalendarStore.shared.setNotify(notify, forHoliday: holidayID, for: signIn) else {
            return
        }
        onChange()
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)
        guard Defaults[.cloudSyncEnabled] else { return }
        enqueueHolidayUpload(holidayID: holidayID, for: signIn)
        poller.noteActivity()
    }

    func cancelUploads() {
        tail?.cancel()
        tail = nil
    }

    func retryUnacknowledged(for signIn: SignIn) {
        guard Defaults[.cloudSyncEnabled] else { return }
        for holidayID in AcademicCalendarStore.shared.unacknowledgedHolidayIDs {
            enqueueHolidayUpload(holidayID: holidayID, for: signIn)
        }
    }

    private func enqueueHolidayUpload(holidayID: Int, for signIn: SignIn) {
        let previous = tail
        let store = AcademicCalendarStore.shared
        store.setHolidayAcknowledged(false, holidayID: holidayID, for: signIn)
        store.beginHolidayUpload()
        tail = account.task { [weak self] _ in
            _ = await previous?.value
            defer { AcademicCalendarStore.shared.endHolidayUpload() }
            guard let self, signIn.isCurrent else { return }
            await Self.uploadHolidayOverride(holidayID, from: .shared, via: push.registration, for: signIn)
        }
    }

    static func uploadHolidayOverride(
        _ holidayID: Int, from store: AcademicCalendarStore, via registration: PushRegistrationService, for signIn: SignIn
    ) async {
        let sent = store.holidayEdit(holidayID)
        do {
            let reply = try await BackendClient.$holdsResend.withValue({ !SyncPolicy.current.cloudSyncEnabled }) {
                try await registration.uploadHolidayOverride(
                    holidayID: holidayID, notify: sent.notify, madeAt: sent.madeAt ?? store.clock.stamp(), for: signIn
                )
            }
            guard store.holidayEdit(holidayID) == sent else { return }
            if !reply.applied { store.applyNotifyTheBackendKept(reply.notify, forHoliday: holidayID, for: signIn) }
            store.setHolidayAcknowledged(true, holidayID: holidayID, for: signIn)
        } catch {
            AppLogger.sync.error(
                "holiday override upload failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }
}
