import Foundation
import os
import UserNotifications

/// Converts assignments + user-selected offsets into pending local notifications.
///
/// Request identifiers follow `"LA-reminder-\(assignmentId)_\(offset)"` so a
/// reschedule cleanly replaces previous entries. iOS caps pending notifications
/// at 64; we keep a soft cap of 60 (closest-to-fire wins) to leave headroom.
@MainActor
final class AssignmentReminderScheduler {
    static let requestPrefix = "LA-reminder-"
    /// iOS hard limit is 64 pending per app; leave headroom for any other source.
    static let maximumPendingNotifications = 60

    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Returns true if the user has (or just granted) alert authorization.
    func ensureAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Cancel every pending request this scheduler owns and re-enqueue fresh ones.
    func reschedule(
        assignments: [SDAssignment],
        offsets: Set<AssignmentReminderOffset>,
        now: Date = Date()
    ) async {
        await cancelAllOwnedRequests()

        guard !offsets.isEmpty else { return }
        guard await ensureAuthorization() else {
            logger.info("Skipping reschedule — notifications not authorized")
            return
        }

        let payloads = Self.buildPayloads(assignments: assignments, offsets: offsets, now: now)
        let capped = Array(
            payloads.sorted { $0.fireDate < $1.fireDate }
                .prefix(Self.maximumPendingNotifications)
        )

        for payload in capped {
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.sound = .default
            content.userInfo = [
                "assignmentId": payload.assignmentId,
                "offset": payload.offset.rawValue
            ]

            let interval = payload.fireDate.timeIntervalSinceNow
            guard interval > 0 else { continue }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.requestPrefix + payload.id,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                logger.error("Failed to schedule reminder \(payload.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Cancel pending requests for a single assignment across all offsets.
    func cancelReminders(for assignmentId: String) {
        let ids = AssignmentReminderOffset.allCases.map {
            Self.requestPrefix + "\(assignmentId)_\($0.rawValue)"
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
                        id: "\(assignment.assignmentId)_\(offset.rawValue)",
                        fireDate: fireDate,
                        title: "作業提醒：\(assignment.courseName)",
                        body: offset.notificationBody(
                            assignmentTitle: assignment.title,
                            courseName: assignment.courseName
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
