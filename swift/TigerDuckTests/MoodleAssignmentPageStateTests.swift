#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// What VoiceOver reads on an assignment's page in each state the page draws: which sections
/// show, in which order. Times are set off the real clock, which the page reads. Every name here
/// is made up.
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

    /// The labels and values VoiceOver reaches on the page, in the order it reads them, once
    /// `shown` is one of them.
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
            try await waitUntil { texts(in: host.view).contains { $0.contains(shown) } }
            return texts(in: host.view)
        }
    }

    private static func texts(in node: NSObject) -> [String] {
        var found = [node.accessibilityLabel, node.accessibilityValue].compactMap { $0 }.filter { !$0.isEmpty }
        var children = node.accessibilityElements ?? []
        let count = node.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { node.accessibilityElement(at: $0) }
        }
        if let view = node as? UIView { children += view.subviews }
        for case let child as NSObject in children {
            found += texts(in: child)
        }
        return found
    }

    /// Where the first text holding each of `parts` comes; nil for a part that is not there.
    private static func order(of parts: [String], in texts: [String]) -> [Int?] {
        parts.map { part in texts.firstIndex { $0.contains(part) } }
    }

    private static func key(_ value: String.LocalizationValue) -> String { String(localized: value) }

    @Test("graded after a late hand-in with a group: the deadline passed, the group, then submission, comments and grade")
    func gradedLateWithAGroup() async throws {
        let due = Date() - 2 * 86_400
        var answer = MoodleAssignmentPageTests.submission("submitted", modified: due + 4_380, files: [MoodleAssignmentPageTests.file])
        answer.groupName = "Group 3"
        answer.comments = [Self.comment(1, "The fifth answer is on the last page."), Self.comment(2, "Noted.")]
        answer.grade = MoodleAssignmentGrade(
            grade: "85.00 / 100.00", gradedAt: due + 86_400, feedback: "<p>Case 7 misses the empty tree.</p>"
        )
        let late = MoodleAssignmentView.Badge.late(4_380).text

        let texts = try await Self.spoken(Self.record(due: due, attachments: [Self.spec]), answer: answer, once: late)

        let parts = [
            Self.key("assignment_detail_due"), Self.key("assignment_detail_due_passed"), "Group 3",
            Self.key("assignment_detail_description"), "binary search tree", Self.key("school_mail_attachments"), "spec.pdf",
            Self.key("assignment_detail_submission"), late, Self.key("assignment_detail_submitted_at"), "hw.pdf",
            Self.key("assignment_detail_comments"), "The fifth answer", "Noted.",
            Self.key("assignment_detail_grade"), MoodleAssignmentView.Score(value: "85", max: "100").spoken,
            Self.key("assignment_detail_graded_at"), Self.key("assignment_detail_feedback"), "Case 7",
            Self.key("assignment_detail_submit_on_moodle"),
        ]
        let found = Self.order(of: parts, in: texts)
        #expect(found.allSatisfy { $0 != nil }, "missing: \(zip(parts, found).filter { $0.1 == nil }.map(\.0))")
        #expect(found.compactMap { $0 } == found.compactMap { $0 }.sorted(), "\(texts)")
    }

    @Test("a draft before the due date: the time left, not submitted, and the draft's file, with no group, comments or grade")
    func draftBeforeTheDueDate() async throws {
        let left: TimeInterval = 86_400 + 4 * 3_600 + 1_800
        let answer = MoodleAssignmentPageTests.submission("draft", modified: Date() - 600, files: [MoodleAssignmentPageTests.file])
        let notSubmitted = Self.key("assignment_detail_not_submitted")

        let texts = try await Self.spoken(Self.record(due: Date() + left), answer: answer, once: notSubmitted)

        let timeLeft = MoodleAssignmentView.Deadline.left(86_400 + 4 * 3_600, urgent: true).text
        #expect(Self.order(of: [timeLeft, notSubmitted, Self.key("assignment_detail_draft"), "hw.pdf"], in: texts)
            .allSatisfy { $0 != nil }, "\(texts)")
        for absent in [
            Self.key("assignment_detail_group"), Self.key("school_mail_attachments"), Self.key("assignment_detail_comments"),
            Self.key("assignment_detail_grade"), Self.key("assignment_detail_submitted_at"),
        ] {
            #expect(!texts.contains { $0.contains(absent) }, "\(absent) shows")
        }
    }

    @Test("handed in early: the time left in grey, the early badge, the text and a comment, and no grade yet")
    func handedInEarly() async throws {
        // Half an hour past the hour, so the time left reads the same however slowly the page comes up.
        let due = Date() + 9 * 86_400 + 2 * 3_600 + 1_800
        var answer = MoodleAssignmentPageTests.submission(
            "submitted", modified: due - (10 * 86_400 + 12 * 3_600), text: "<p>The work split is on the last page.</p>"
        )
        answer.groupName = "Project team A"
        answer.comments = [Self.comment(1, "This is the final draft.")]
        let early = MoodleAssignmentView.Badge.early(10 * 86_400 + 12 * 3_600).text

        let texts = try await Self.spoken(Self.record(due: due), answer: answer, once: early)

        let parts = [
            MoodleAssignmentView.Deadline.left(9 * 86_400 + 2 * 3_600, urgent: false).text, "Project team A",
            early, Self.key("assignment_detail_submitted_at"), "work split", Self.key("assignment_detail_comments"),
            "final draft",
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

        let texts = try await Self.spoken(Self.record(due: Date() - late), once: notSubmitted)

        #expect(texts.contains { $0.contains(MoodleAssignmentView.Deadline.overdue(86_400 + 20 * 3_600).text) }, "\(texts)")
        for absent in [
            Self.key("assignment_detail_submitted_at"), Self.key("assignment_detail_draft"),
            Self.key("assignment_detail_comments"), Self.key("assignment_detail_grade"),
        ] {
            #expect(!texts.contains { $0.contains(absent) }, "\(absent) shows")
        }
        #expect(texts.contains(Self.key("assignment_detail_submit_on_moodle")))
    }

    @Test("with no due date there is no deadline card, and a hand-in reads as submitted")
    func noDueDate() async throws {
        let submitted = Self.key("assignment_status_submitted")
        let answer = MoodleAssignmentPageTests.submission("submitted", files: [MoodleAssignmentPageTests.file])

        let texts = try await Self.spoken(Self.record(due: nil), answer: answer, once: "hw.pdf")

        #expect(texts.contains(submitted), "\(texts)")
        #expect(!texts.contains { $0.contains(Self.key("assignment_detail_due")) })
    }

    @Test("one Moodle takes nothing online for keeps its due time but shows no submission and no button")
    func noOnlineSubmission() async throws {
        let due = Date() + 3 * 86_400 + 5 * 3_600 + 1_800

        let texts = try await Self.spoken(
            Self.record(due: due, noSubmissions: true), once: Self.key("assignment_detail_due")
        )

        #expect(texts.contains { $0.contains(MoodleAssignmentView.Deadline.left(3 * 86_400 + 5 * 3_600, urgent: false).text) },
                "\(texts)")
        for absent in [
            Self.key("assignment_detail_submission"), Self.key("assignment_detail_not_submitted"),
            Self.key("assignment_detail_submit_on_moodle"),
        ] {
            #expect(!texts.contains { $0.contains(absent) }, "\(absent) shows")
        }
    }
}
#endif
