import Defaults
import Foundation
import os

/// Sends the holidays the user asked to be reminded on, one upload at a time.
@MainActor
final class HolidaySettingSender {
    /// Runs after a holiday's setting changed here, before it is sent.
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

    func setHolidayNotify(_ notify: Bool, holidayID: Int) {
        guard AcademicCalendarStore.shared.setNotify(notify, forHoliday: holidayID) else {
            return
        }
        onChange()
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)
        guard Defaults[.cloudSyncEnabled] else { return }
        enqueueHolidayUpload(holidayID: holidayID)
        poller.noteActivity()
    }

    func cancelUploads() {
        tail?.cancel()
        tail = nil
    }

    func retryUnacknowledged() {
        guard Defaults[.cloudSyncEnabled] else { return }
        for holidayID in AcademicCalendarStore.shared.unacknowledgedHolidayIDs {
            enqueueHolidayUpload(holidayID: holidayID)
        }
    }

    private func enqueueHolidayUpload(holidayID: Int) {
        let previous = tail
        let store = AcademicCalendarStore.shared
        store.setHolidayAcknowledged(false, holidayID: holidayID)
        store.beginHolidayUpload()
        tail = account.task { [weak self] ticket in
            _ = await previous?.value
            defer { AcademicCalendarStore.shared.endHolidayUpload() }
            guard let self, account.isCurrent(ticket) else { return }
            await Self.uploadHolidayOverride(holidayID, from: .shared, via: push.registration)
        }
    }

    /// Sends the holiday's setting with the time it was made, so a retry is not a newer edit, and
    /// acknowledges it only when no edit came after it while it was out. A setting another device
    /// made later, which the backend kept, replaces it here.
    static func uploadHolidayOverride(
        _ holidayID: Int, from store: AcademicCalendarStore, via registration: PushRegistrationService
    ) async {
        let sent = store.holidayEdit(holidayID)
        do {
            let reply = try await registration.uploadHolidayOverride(
                holidayID: holidayID, notify: sent.notify, madeAt: sent.madeAt ?? Date()
            )
            guard store.holidayEdit(holidayID) == sent else { return }
            if !reply.applied { store.applyKeptNotify(reply.notify, forHoliday: holidayID) }
            store.setHolidayAcknowledged(true, holidayID: holidayID)
        } catch {
            AppLogger.sync.error(
                "holiday override upload failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }
}
