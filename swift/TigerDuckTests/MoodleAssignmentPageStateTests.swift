#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MoodleAssignmentPageStateTests {
    private static let spec = MoodleFile(
        name: "spec.pdf", size: 250_880,
        url: "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/123/mod_assign/introattachment/0/spec.pdf",
        mimeType: "application/pdf", modified: nil, path: "/"
    )

    private static func record(
        due: Date?, attachments: [MoodleFile] = [], noSubmissions: Bool = false
    ) -> MoodleAssignmentRecord {
        MoodleAssignmentRecord(
            assignId: 701, cmId: 9701, courseId: 20119, name: "HW 3", dueDate: due, cutoffDate: nil,
            allowSubmissionsFromDate: nil, intro: "<p>Implement a binary search tree.</p>",
            noSubmissions: noSubmissions, introAttachments: attachments
        )
    }

    private static func comment(_ id: Int, _ text: String) -> MoodleSubmissionComment {
        MoodleSubmissionComment(
            id: id, authorName: "B11399001 @ Tiger Duck", created: Date(timeIntervalSince1970: 1_792_000_000 + Double(id)),
            content: "<p>\(text)</p>"
        )
    }

    private static func spoken(
        _ record: MoodleAssignmentRecord,
        answer: MoodleAssignmentSubmission = MoodleAssignmentPageTests.submission("new"),
        once shown: String
    ) async throws -> [String] {
        let root = MoodleAssignmentPageTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = MoodleAssignmentView(
            store: MoodleAssignmentPageTests.store(in: root, answer: answer),
            entry: MoodleCourseAssignments.Entry(record: record, listed: nil),
            courseName: "Data Structures", policy: VisualStylePolicy(preset: .default), accent: .blue
        )
        return try await withAccessibilityAutomation {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 2400)
            let host = UIHostingController(rootView: NavigationStack { page })
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            try await waitUntil { exposedAccessibilityTexts(in: host.view).contains { $0.contains(shown) } }
            return exposedAccessibilityTexts(in: host.view)
        }
    }

    private enum Read: CustomStringConvertible {
        case exactly(String)
        case holding(String)
        case row(String, String)

        func matches(_ text: String) -> Bool {
            switch self {
            case .exactly(let string): text == string
            case .holding(let string): text.contains(string)
            case .row(let label, let value): text.contains(label) && text.contains(value)
            }
        }

        var description: String {
            switch self {
            case .exactly(let string), .holding(let string): string
            case .row(let label, let value): "\(label): \(value)"
            }
        }
    }

    private static func order(of parts: [Read], in texts: [String]) -> [Int?] {
        parts.map { part in texts.firstIndex(where: part.matches) }
    }

    private static func key(_ value: String.LocalizationValue) -> String { String(localized: value) }

    @Test("graded after a late hand-in with a group: the deadline passed, the group, then submission, comments and grade")
    func gradedLateWithAGroup() async throws {
        let due = AppClock.now() - 2 * 86_400
        let submittedAt = due + 4_380
        var answer = MoodleAssignmentPageTests.submission("submitted", modified: submittedAt, files: [MoodleAssignmentPageTests.file])
        answer.groupName = "Group 3"
        answer.comments = [Self.comment(1, "The fifth answer is on the last page."), Self.comment(2, "Noted.")]
        answer.grade = MoodleAssignmentGrade(
            grade: "85.00 / 100.00", gradedAt: due + 86_400, feedback: "<p>Case 7 misses the empty tree.</p>"
        )
        let late = MoodleAssignmentView.Badge.late(4_380).text

        let texts = try await Self.spoken(Self.record(due: due, attachments: [Self.spec]), answer: answer, once: late)

        let parts: [Read] = [
            .row(Self.key("assignment_detail_due"), Self.key("assignment_detail_due_passed")),
            .row(Self.key("assignment_detail_group"), "Group 3"),
            .exactly(Self.key("assignment_detail_description")), .holding("binary search tree"),
            .exactly(Self.key("school_mail_attachments")), .holding("spec.pdf"),
            .exactly(Self.key("assignment_detail_submission")), .exactly(late),
            .row(Self.key("assignment_detail_submitted_at"), MoodleAssignmentView.timeText(submittedAt)), .holding("hw.pdf"),
            .exactly(Self.key("assignment_detail_comments")), .holding("The fifth answer"), .holding("Noted."),
            .exactly(Self.key("assignment_detail_grade")), .exactly(MoodleAssignmentView.Score(value: "85", max: "100").spoken),
            .row(Self.key("assignment_detail_graded_at"), MoodleAssignmentView.timeText(due + 86_400)),
            .exactly(Self.key("assignment_detail_feedback")), .holding("Case 7"),
            .exactly(Self.key("assignment_detail_submit_on_moodle")),
        ]
        let found = Self.order(of: parts, in: texts)
        #expect(found.allSatisfy { $0 != nil }, "missing: \(zip(parts, found).filter { $0.1 == nil }.map(\.0))")
        #expect(found.compactMap { $0 } == found.compactMap { $0 }.sorted(), "\(texts)")
    }

    @Test("a draft before the due date: the time left, not submitted, and the draft's file, with no group, comments or grade")
    func draftBeforeTheDueDate() async throws {
        let left: TimeInterval = 86_400 + 4 * 3_600 + 1_800
        let draftedAt = AppClock.now() - 600
        let answer = MoodleAssignmentPageTests.submission("draft", modified: draftedAt, files: [MoodleAssignmentPageTests.file])
        let notSubmitted = Self.key("assignment_detail_not_submitted")

        let texts = try await Self.spoken(Self.record(due: AppClock.now() + left), answer: answer, once: notSubmitted)

        let timeLeft = MoodleAssignmentView.Deadline.left(86_400 + 4 * 3_600, urgent: true).text
        let found = Self.order(of: [
            .row(Self.key("assignment_detail_due"), timeLeft), .exactly(notSubmitted),
            .row(Self.key("assignment_detail_draft"), MoodleAssignmentView.timeText(draftedAt)), .holding("hw.pdf"),
        ], in: texts)
        #expect(found.allSatisfy { $0 != nil }, "\(texts)")
        #expect(found.compactMap { $0 } == found.compactMap { $0 }.sorted(), "\(texts)")
        for absent in [
            Self.key("assignment_detail_group"), Self.key("school_mail_attachments"), Self.key("assignment_detail_comments"),
            Self.key("assignment_detail_grade"), Self.key("assignment_detail_submitted_at"),
        ] {
            #expect(!texts.contains { $0.contains(absent) }, "\(absent) shows")
        }
    }

    @Test("handed in early: the time left in grey, the early badge, the text and a comment, and no grade yet")
    func handedInEarly() async throws {
        let due = AppClock.now() + 9 * 86_400 + 2 * 3_600 + 1_800
        let submittedAt = due - (10 * 86_400 + 12 * 3_600)
        var answer = MoodleAssignmentPageTests.submission(
            "submitted", modified: submittedAt, text: "<p>The work split is on the last page.</p>"
        )
        answer.groupName = "Project team A"
        answer.comments = [Self.comment(1, "This is the final draft.")]
        let early = MoodleAssignmentView.Badge.early(10 * 86_400 + 12 * 3_600).text

        let texts = try await Self.spoken(Self.record(due: due), answer: answer, once: early)

        let parts: [Read] = [
            .row(Self.key("assignment_detail_due"), MoodleAssignmentView.Deadline.left(9 * 86_400 + 2 * 3_600, urgent: false).text),
            .row(Self.key("assignment_detail_group"), "Project team A"),
            .exactly(early),
            .row(Self.key("assignment_detail_submitted_at"), MoodleAssignmentView.timeText(submittedAt)), .holding("work split"),
            .exactly(Self.key("assignment_detail_comments")), .holding("final draft"),
        ]
        let found = Self.order(of: parts, in: texts)
        #expect(found.allSatisfy { $0 != nil }, "missing: \(zip(parts, found).filter { $0.1 == nil }.map(\.0))")
        #expect(found.compactMap { $0 } == found.compactMap { $0 }.sorted(), "\(texts)")
        #expect(!texts.contains { $0.contains(Self.key("assignment_detail_grade")) })
    }

    @Test("past the due date and not handed in: overdue by how long, not submitted, and nothing under it")
    func overdue() async throws {
        let late: TimeInterval = 86_400 + 20 * 3_600 + 600
        let notSubmitted = Self.key("assignment_detail_not_submitted")

        let texts = try await Self.spoken(Self.record(due: AppClock.now() - late), once: notSubmitted)

        let overdueBy = MoodleAssignmentView.Deadline.overdue(86_400 + 20 * 3_600).text
        #expect(texts.contains(where: Read.row(Self.key("assignment_detail_due"), overdueBy).matches), "\(texts)")
        for absent in [
            Self.key("assignment_detail_submitted_at"), Self.key("assignment_detail_draft"),
            Self.key("assignment_detail_comments"), Self.key("assignment_detail_grade"),
        ] {
            #expect(!texts.contains { $0.contains(absent) }, "\(absent) shows")
        }
        #expect(texts.contains(where: Read.exactly(Self.key("assignment_detail_submit_on_moodle")).matches))
    }

    @Test("a refresh that fails over the submission the page shows puts up the failure note")
    func refreshFailureNote() async throws {
        let root = MoodleAssignmentPageTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = Self.record(due: AppClock.now() + 86_400)
        let store = MoodleAssignmentPageTests.store(in: root, answering: 1)
        let page = MoodleAssignmentView(
            store: store, entry: MoodleCourseAssignments.Entry(record: record, listed: nil),
            courseName: "Data Structures", policy: VisualStylePolicy(preset: .default), accent: .blue
        )
        try await withAccessibilityAutomation {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            let host = UIHostingController(rootView: NavigationStack { page })
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            let note = Self.key("course_moodle_refresh_failed")
            try await waitUntil { store.assignments.submission(of: record).value != nil }
            #expect(accessibilityElement(labeled: note, in: host.view) == nil)

            await store.assignments.refreshSubmission(of: record)

            try await waitUntil(timeout: .seconds(10)) { accessibilityElement(labeled: note, in: host.view) != nil }
        }
    }

    @Test("with no due date there is no deadline card, and a hand-in reads as submitted")
    func noDueDate() async throws {
        let submitted = Self.key("assignment_status_submitted")
        let answer = MoodleAssignmentPageTests.submission("submitted", files: [MoodleAssignmentPageTests.file])

        let texts = try await Self.spoken(Self.record(due: nil), answer: answer, once: "hw.pdf")

        #expect(texts.contains(where: Read.exactly(submitted).matches), "\(texts)")
        #expect(!texts.contains { $0.contains(Self.key("assignment_detail_due")) })
    }

    @Test("one Moodle takes nothing online for keeps its due time but shows no submission and no button")
    func noOnlineSubmission() async throws {
        let due = AppClock.now() + 3 * 86_400 + 5 * 3_600 + 1_800

        let texts = try await Self.spoken(
            Self.record(due: due, noSubmissions: true), once: Self.key("assignment_detail_due")
        )

        let timeLeft = MoodleAssignmentView.Deadline.left(3 * 86_400 + 5 * 3_600, urgent: false).text
        #expect(texts.contains(where: Read.row(Self.key("assignment_detail_due"), timeLeft).matches), "\(texts)")
        for absent in [
            Self.key("assignment_detail_submission"), Self.key("assignment_detail_not_submitted"),
            Self.key("assignment_detail_submit_on_moodle"),
        ] {
            #expect(!texts.contains { $0.contains(absent) }, "\(absent) shows")
        }
    }
}
#endif
