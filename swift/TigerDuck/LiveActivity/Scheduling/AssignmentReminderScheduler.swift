import Foundation
import os
import UserNotifications

/// Converts assignments + user-selected offsets into pending local notifications.
///
/// Request identifiers follow `"LA-reminder-\(assignmentId)::\(offset)"` so a
/// reschedule cleanly replaces previous entries. The `::` separator avoids
/// collisions with assignment IDs that may legitimately contain `_`. iOS caps
/// pending notifications at 64; we keep a soft cap of 60 (closest-to-fire
/// wins) to leave headroom.
@MainActor
final class AssignmentReminderScheduler {
    static let requestPrefix = "LA-reminder-"
    /// Shared category id so a future `UNNotificationCategory` registration
    /// (with custom actions like "mark complete" / "snooze") attaches to
    /// every reminder we own without having to re-emit the pending requests.
    static let categoryIdentifier = "assignment-reminder"
    /// iOS hard limit is 64 pending per app; leave headroom for any other source.
    static let maximumPendingNotifications = 60

    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")

    /// Serialization for `reschedule`. Two concurrent reschedules
    /// (preference change + assignment refresh on the same tick) used
    /// to interleave their cancel + add steps and produced duplicates
    /// or zero pending requests. `@MainActor` doesn't eliminate
    /// cross-suspension reentry — a new generation each call means
    /// every awaited continuation can compare against the latest
    /// generation and bail if a newer reschedule has already taken
    /// over.
    private var rescheduleGeneration: UInt64 = 0
    /// In-flight task chain — each call waits for the previous task
    /// to finish before starting, guaranteeing strict serialization.
    private var pendingReschedule: Task<Void, Never>?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Returns whether notifications are currently authorized for the app.
    /// Never prompts the user — safe to call from any code path, including
    /// background syncs, preference refreshes, and theme tweaks.
    func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    /// Prompts for notification authorization only when the user has not yet
    /// decided. Must only be called from explicit user intent (e.g. opening
    /// the notification settings page) — never from a refresh path, otherwise
    /// the system permission alert appears at unrelated moments such as a
    /// theme color change or a background data sync.
    func requestAuthorizationIfNeeded() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                AppLogger.captureError(error, context: ["phase": "reminder.requestAuthorization"])
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Cancel every pending request this scheduler owns and re-enqueue fresh ones.
    /// Calls are strictly serialized — a second `reschedule` invoked
    /// while an earlier one is still in flight queues behind the prior
    /// task and bails early if a third call has bumped the generation
    /// past it.
    func reschedule(
        assignments: [SDAssignment],
        offsets: Set<AssignmentReminderOffset>,
        now: Date = AppClock.now()
    ) async {
        rescheduleGeneration &+= 1
        let myGeneration = rescheduleGeneration
        let previous = pendingReschedule
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.rescheduleGeneration == myGeneration else { return }
            await self.performReschedule(
                assignments: assignments,
                offsets: offsets,
                now: now,
                generation: myGeneration
            )
        }
        pendingReschedule = task
        await task.value
    }

    private func performReschedule(
        assignments: [SDAssignment],
        offsets: Set<AssignmentReminderOffset>,
        now: Date,
        generation: UInt64
    ) async {
        await cancelAllOwnedRequests()
        guard rescheduleGeneration == generation else { return }

        guard !offsets.isEmpty else { return }
        guard await isAuthorized() else {
            logger.info("Skipping reschedule — notifications not authorized (no prompt issued)")
            return
        }
        guard rescheduleGeneration == generation else { return }

        let payloads = Self.buildPayloads(assignments: assignments, offsets: offsets, now: now)
        let sorted = payloads.sorted { $0.fireDate < $1.fireDate }
        let capped = Array(sorted.prefix(Self.maximumPendingNotifications))
        // The hard 60-cap drops far-future reminders silently. When the
        // nearest reminders fire, `reschedule` runs again and the
        // dropped ones may already be past `fireDate > now` — i.e. they
        // are simply lost. Surface the count so the magnitude shows up
        // in logs / Sentry breadcrumbs and we can tell whether to raise
        // the cap or group-by-assignment-with-min-keep.
        let dropped = sorted.count - capped.count
        if dropped > 0 {
            logger.info("Reminder cap dropped \(dropped, privacy: .public) of \(sorted.count, privacy: .public) pending payloads")
        }

        for payload in capped {
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.sound = .default
            // Group reminders for the same assignment under one thread so
            // the lock screen stacks them instead of presenting N separate
            // banners; iOS uses the most recent in the stack as the
            // visible "head".
            content.threadIdentifier = "assignment-\(payload.assignmentId)"
            content.categoryIdentifier = Self.categoryIdentifier
            // `.timeSensitive` would let short-offset reminders break
            // through Focus modes, but it requires the
            // `com.apple.developer.usernotifications.time-sensitive`
            // entitlement which is not yet provisioned for this target.
            // `.active` is the implicit default; setting it explicitly
            // documents intent.
            content.interruptionLevel = .active
            content.userInfo = [
                "assignmentId": payload.assignmentId,
                "offset": payload.offset.rawValue
            ]

            guard payload.fireDate.timeIntervalSinceNow > 0 else { continue }

            // Calendar trigger (not interval) so DST transitions, sleep
            // gaps, or reschedules don't drift the "48h before" anchor
            // by up to an hour. We pin on the absolute fireDate using
            // the gregorian + Asia/Taipei calendar — matches the rest
            // of the schedule math (see Date+Formatting.scheduleCalendar).
            let components = Date.scheduleCalendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: payload.fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.requestPrefix + payload.id,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                logger.error("Failed to schedule reminder \(payload.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                AppLogger.captureError(error, context: [
                    "phase": "reminder.add",
                    "payloadId": payload.id,
                ])
            }
        }
    }

    /// Cancel pending requests for a single assignment across all offsets.
    func cancelReminders(for assignmentId: String) {
        let ids = AssignmentReminderOffset.allCases.map {
            Self.requestPrefix + "\(assignmentId)::\($0.rawValue)"
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Remove only the requests this scheduler owns (prefix match).
    func cancelAllOwnedRequests() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.requestPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Pure factory. Exposed for unit tests so we can verify payload shape
    /// without touching `UNUserNotificationCenter`.
    static func buildPayloads(
        assignments: [SDAssignment],
        offsets: Set<AssignmentReminderOffset>,
        now: Date
    ) -> [ReminderPayload] {
        var payloads: [ReminderPayload] = []
        for assignment in assignments where !assignment.isCompleted {
            for offset in offsets {
                let fireDate = assignment.dueDate.addingTimeInterval(-offset.timeInterval)
                guard fireDate > now else { continue }
                payloads.append(
                    ReminderPayload(
                        id: "\(assignment.assignmentId)::\(offset.rawValue)",
                        fireDate: fireDate,
                        title: String(format: String(localized: "notification_assignment_reminder_title"), assignment.displayCourseName),
                        body: offset.notificationBody(
                            assignmentTitle: assignment.displayTitle,
                            courseName: assignment.displayCourseName
                        ),
                        assignmentId: assignment.assignmentId,
                        offset: offset
                    )
                )
            }
        }
        return payloads
    }
}
