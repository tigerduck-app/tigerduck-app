import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct UndatedAssignmentTests {
    private static let now = Date(timeIntervalSince1970: 1_790_600_000)
    private static let hour: TimeInterval = 3_600

    private static func assignment(_ id: String, due offset: TimeInterval?) -> SDAssignment {
        SDAssignment(
            assignmentId: id, courseNo: "CS3105301", courseName: "Data Structures", title: "HW \(id)",
            dueDate: offset.map { now + $0 }
        )
    }

    @Test("every list keeps the dated in today's order and puts the undated after them, by title")
    func undatedFollowTheDatedByTitle() {
        let assignments = [
            Self.assignment("10", due: nil),
            Self.assignment("soon", due: 2 * Self.hour),
            Self.assignment("2", due: nil),
            Self.assignment("past", due: -Self.hour),
            Self.assignment("later", due: 48 * Self.hour),
        ]

        #expect(assignments.upcomingSorted().map(\.assignmentId) == ["past", "soon", "later", "2", "10"])
        #expect(assignments.unfinished(for: "CS3105301").map(\.assignmentId) == ["past", "soon", "later", "2", "10"])
        #expect(assignments.partitionedByDueDate(now: Self.now).map(\.assignmentId) == ["soon", "later", "past", "2", "10"])
        #expect(assignments.sortedByDueDate(by: >).map(\.assignmentId) == ["later", "soon", "past", "2", "10"])
        assignments.forEach { $0.isArchived = true }
        #expect(assignments.ignoredSorted().map(\.assignmentId) == ["past", "soon", "later", "2", "10"])
    }

    @Test("an undated assignment is never late or overdue, and its date and time left read as a dash")
    func undatedHasNoDeadline() {
        let open = Self.assignment("1", due: nil)
        let handedIn = Self.assignment("2", due: nil)
        handedIn.isCompleted = true
        handedIn.submittedAt = Self.now

        #expect(open.moodleStatus(now: .distantFuture) == .pending)
        #expect(!open.isOverdue)
        #expect(handedIn.moodleStatus(now: .distantFuture) == .submitted)
        #expect(open.dueLabel(now: Self.now, absolute: false) == "\u{2014}")
        #expect(open.dueLabel(now: Self.now, absolute: true) == "\u{2014}")
    }

    @Test("an extension gives an undated assignment its due date, and taking it back leaves none")
    func extensionDatesAnUndatedAssignment() {
        let extended = Self.now + 24 * Self.hour
        let assignment = SDAssignment(
            assignmentId: "1", courseNo: "CS3105301", courseName: "Data Structures", title: "Essay", dueDate: nil,
            extensionDueDate: extended
        )
        #expect(assignment.dueDate == extended)

        assignment.extend(to: nil)
        #expect(assignment.dueDate == nil)

        let record = MoodleAssignmentRecord(
            assignId: 1, cmId: 1, courseId: 1, name: "Essay", dueDate: nil, cutoffDate: nil,
            allowSubmissionsFromDate: nil, intro: "", noSubmissions: false
        )
        #expect(MoodleCourseAssignments.Entry(record: record, listed: SDAssignment(
            assignmentId: "1", courseNo: "", courseName: "", title: "Essay", dueDate: nil, extensionDueDate: extended
        )).dueDate == extended)
        #expect(record.dueDate(extendedTo: nil) == nil)
    }

    @Test("the Live Activity and the 48-hour list the server starts activities from leave an undated assignment out")
    func liveActivityLeavesItOut() {
        let undated = Self.assignment("undated", due: nil)
        let dated = Self.assignment("dated", due: 2 * Self.hour)

        #expect(LiveActivityScenarioResolver.earliestUrgentAssignment(
            assignments: [undated], leadTime: 8 * Self.hour, now: Self.now
        ) == nil)
        #expect(LiveActivityScenarioResolver.earliestUrgentAssignment(
            assignments: [undated, dated], leadTime: 8 * Self.hour, now: Self.now
        )?.assignmentId == "dated")

        let inputs = ScheduleSyncService.Inputs(
            courses: [], assignments: [undated, dated], accentHex: 0x4A90E2,
            classPreparingLeadTime: 15 * 60, assignmentLeadTime: 3 * Self.hour,
            showClassPreparing: true, showInClass: true, showAssignmentScenario: true,
            liveActivityAvailable: true, term: "1151"
        )
        let events = ScheduleSyncService.buildEvents(inputs: inputs, now: Self.now, horizonEnd: Self.now + 48 * Self.hour)
        #expect(events.map(\.sourceId) == ["dated"])
    }

    @Test("the calendar has no event for an undated assignment")
    func calendarLeavesItOut() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TestCache(folders: CacheFolders(root: root)).assignments

        AssignmentAnswers.saveMoodleCalendarEvents(
            of: [Self.assignment("undated", due: nil), Self.assignment("dated", due: Self.hour)], in: store, for: testSignIn
        )

        #expect(store.loadCalendarEvents().map(\.eventId) == ["moodle-dated"])
    }

    @MainActor
    private final class Sent {
        var requests: [PushAPI.AssignmentUploadRequest] = []
    }

    @Test("the upload for TigerSync sends an undated assignment without a due time, never a made-up date")
    func uploadLeavesTheDueTimeOut() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.cloudSyncEnabled]
            let sent = Sent()
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            AssignmentAnswers.assignmentUploader = { request, _ in sent.requests.append(request) }
            defer {
                Defaults[.cloudSyncEnabled, for: testSignIn] = saved
                AssignmentAnswers.assignmentUploader = nil
            }

            AssignmentAnswers.uploadForReminders(
                [Self.assignment("701", due: nil), Self.assignment("702", due: Self.hour)], for: testSignIn
            )

            let request = try #require(sent.requests.first)
            let body = try #require(
                try JSONSerialization.jsonObject(with: BackendClient.encoder.encode(request)) as? [String: Any]
            )
            let entries = try #require(body["assignments"] as? [[String: Any]])
            #expect(entries.map { $0["moodle_assignment_id"] as? Int } == [701, 702])
            #expect(entries[0]["due_at"] == nil)
            #expect(entries[1]["due_at"] as? String == "2026-09-28T13:53:20Z")
        }
    }
}
