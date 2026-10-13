#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// What a tapped push opens, read from the keys the backend puts in the payload. Its standard
/// alerts send every extra key as a string.
@MainActor
struct PushTapRoutingTests {

    // MARK: - Bulletins

    @Test func aSubscriptionBulletinOpensTheBulletin() {
        let link = AppState.bulletinDeepLink(from: ["kind": "bulletin", "bulletin_id": "4821"])
        #expect(link == .bulletin(4821))
    }

    @Test func aCustomPushBulletinOpensTheBulletin() {
        // A Double-tagged NSNumber, which `as? Int` does not accept.
        let link = AppState.bulletinDeepLink(
            from: ["kind": "custom_push_bulletin", "bulletin_id": NSNumber(value: 77.0)]
        )
        #expect(link == .bulletin(77))
    }

    @Test func otherKindsAndBadIdsOpenNoBulletin() {
        #expect(AppState.bulletinDeepLink(from: ["kind": "custom_push_popup", "bulletin_id": 1]) == nil)
        #expect(AppState.bulletinDeepLink(from: ["kind": "bulletin"]) == nil)
        #expect(AppState.bulletinDeepLink(from: ["kind": "bulletin", "bulletin_id": "abc"]) == nil)
    }

    // MARK: - Assignment reminders

    private static let assignments = [
        SDAssignment(
            assignmentId: "901", courseNo: "CS101", courseName: "Algorithms",
            title: "Lab 1", dueDate: Date(timeIntervalSince1970: 1_790_000_000),
            moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=5501"
        ),
        SDAssignment(
            assignmentId: "902", courseNo: "CS101", courseName: "Algorithms",
            title: "Lab 2", dueDate: Date(timeIntervalSince1970: 1_790_100_000),
            moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=5502"
        ),
    ]

    @Test func anAssignmentReminderFindsItsAssignment() {
        let found = AppState.remindedAssignment(
            from: ["kind": "assignment_reminder", "moodle_assignment_id": "902", "moodle_course_id": "0"],
            in: Self.assignments
        )
        #expect(found?.assignmentId == "902")
        #expect(found?.moodleWebURL?.absoluteString == "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=5502")
    }

    @Test func aReminderFindsNothingItDoesNotName() {
        #expect(AppState.remindedAssignment(
            from: ["kind": "assignment_reminder", "moodle_assignment_id": "903"],
            in: Self.assignments
        ) == nil)
        #expect(AppState.remindedAssignment(
            from: ["kind": "bulletin", "moodle_assignment_id": "901"],
            in: Self.assignments
        ) == nil)
        #expect(AppState.remindedAssignment(from: ["kind": "assignment_reminder"], in: Self.assignments) == nil)
    }
}
#endif
