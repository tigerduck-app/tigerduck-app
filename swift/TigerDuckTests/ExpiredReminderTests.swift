#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ExpiredReminderTests {
    private static func epoch(hoursFromNow hours: Double) -> Int {
        Int(AppClock.now().addingTimeInterval(hours * 3600).timeIntervalSince1970)
    }

    /// The backend sends every extra key of a push as a string.
    private static func reminder(dueEpoch: Any) -> [AnyHashable: Any] {
        ["kind": "assignment_reminder", "moodle_assignment_id": "902", "due_epoch": dueEpoch]
    }

    @Test("A reminder past its due time goes and one not yet due stays, its due_epoch a string or a number",
          arguments: [true, false])
    func aReminderPastItsDueTimeGoes(dueEpochAsString: Bool) async {
        let due = { (hours: Double) -> Any in
            let epoch = Self.epoch(hoursFromNow: hours)
            return dueEpochAsString ? String(epoch) : epoch
        }
        let center = DeliveredNotificationsStub([
            ("due", "assignment", Self.reminder(dueEpoch: due(-1))),
            ("not-due", "assignment", Self.reminder(dueEpoch: due(1))),
            ("due-as-double", "assignment", Self.reminder(dueEpoch: NSNumber(value: Double(Self.epoch(hoursFromNow: -1))))),
        ])

        await center.removeExpiredReminders()

        #expect(center.delivered.map(\.identifier) == ["not-due"])
    }

    @Test("A reminder due within the next minute goes already; one due later stays")
    func aReminderDueWithinTheLeewayGoes() async {
        let now = 2_000_000_000
        let leeway = Int(reminderDueLeeway)
        let center = DeliveredNotificationsStub([
            ("at-the-leeway", "assignment", Self.reminder(dueEpoch: String(now + leeway))),
            ("past-the-leeway", "assignment", Self.reminder(dueEpoch: String(now + leeway + 1))),
        ])

        await center.removeExpiredReminders(now: Date(timeIntervalSince1970: TimeInterval(now)))

        #expect(center.delivered.map(\.identifier) == ["past-the-leeway"])
    }

    @Test("Class reminders, bulletins, school mail and operator pushes stay, even with a past due_epoch")
    func otherKindsStay() async {
        let past = String(Self.epoch(hoursFromNow: -1))
        let center = DeliveredNotificationsStub([
            ("class", "course", ["kind": "course_reminder", "start_epoch": past, "due_epoch": past]),
            ("bulletin", "other", ["kind": "bulletin", "bulletin_id": "7", "due_epoch": past]),
            ("operator", "other", ["kind": "custom_push_bulletin", "bulletin_id": "8", "due_epoch": past]),
            ("popup", "other", ["kind": "custom_push_popup", "due_epoch": past]),
            ("mail", MailConstants.notificationThread, ["kind": MailConstants.notificationKind, "due_epoch": past]),
            ("no-kind", "assignment", ["due_epoch": past]),
        ])

        await center.removeExpiredReminders()

        #expect(center.delivered.map(\.identifier) == ["class", "bulletin", "operator", "popup", "mail", "no-kind"])
    }

    @Test("A reminder whose due time cannot be read stays")
    func aReminderWithoutAReadableDueTimeStays() async {
        let center = DeliveredNotificationsStub([
            ("missing", "assignment", ["kind": "assignment_reminder", "moodle_assignment_id": "902"]),
            ("garbled", "assignment", Self.reminder(dueEpoch: "soon")),
            ("empty", "assignment", Self.reminder(dueEpoch: "")),
        ])

        await center.removeExpiredReminders()

        #expect(center.delivered.map(\.identifier) == ["missing", "garbled", "empty"])
    }
}
#endif
