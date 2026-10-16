#if os(iOS)
import Foundation
import os
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// What an assignment's page shows of its submission and its times, when it fetches, and how Home
/// brings it up. Every name here is made up.
@MainActor
struct MoodleAssignmentPageTests {
    private static let due = Date(timeIntervalSince1970: 1_790_600_000)

    private static let file = MoodleFile(
        name: "hw.pdf", size: 870_400,
        url: "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/123/assignsubmission_file/submission_files/5501/hw.pdf",
        mimeType: "application/pdf", modified: due, path: "/"
    )

    private static let record = MoodleAssignmentRecord(
        assignId: 701, cmId: 9701, courseId: 20119, name: "HW 2", dueDate: due, cutoffDate: nil,
        allowSubmissionsFromDate: nil, intro: "<p>Implement a list.</p>", noSubmissions: false
    )

    private static func assignment(submittedAt: Date?) -> SDAssignment {
        SDAssignment(
            assignmentId: "701", courseNo: "CS3105301", courseName: "Data Structures", title: "HW 2", dueDate: due,
            isCompleted: submittedAt != nil, submittedAt: submittedAt
        )
    }

    private static func submission(
        _ status: String?, modified: Date? = due - 3600, files: [MoodleFile] = [], text: String? = nil
    ) -> MoodleAssignmentSubmission {
        MoodleAssignmentSubmission(
            status: status, modified: modified, files: files, onlineText: text, id: 5501, takesComments: false,
            groupId: nil
        )
    }

    /// A store over a cache in a folder of its own that the test removes, whose site counts the
    /// submission fetches.
    private static func store(
        in root: URL, fetches: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)
    ) -> MoodleCourseStore {
        let answer = submission("submitted")
        return MoodleCourseStore(
            courseId: 20119,
            termCourseIds: [20119],
            context: MoodleCacheContext(
                account: "B11399001",
                cache: DataCache(
                    cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                    persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
                ),
                isCurrent: { true }
            ),
            api: MoodleCourseAPI(
                functions: { [] },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                submission: { _ in
                    fetches.withLock { $0 += 1 }
                    return answer
                }
            )
        )
    }

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleAssignmentPageTests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - What it shows

    @Test("the submission time is the fetched one, and before the first fetch answers, the one the round found")
    func submittedAt() {
        let foundByRound = Self.due - 7200
        let fetched = Self.due - 3600
        let listed = Self.assignment(submittedAt: foundByRound)

        #expect(MoodleAssignmentView.submittedAt(of: listed, submission: nil) == foundByRound)
        #expect(MoodleAssignmentView.submittedAt(of: listed, submission: Self.submission("submitted", modified: fetched))
            == fetched)
        #expect(MoodleAssignmentView.submittedAt(of: listed, submission: Self.submission("draft", modified: fetched)) == nil)
        #expect(MoodleAssignmentView.submittedAt(of: Self.assignment(submittedAt: nil), submission: nil) == nil)
        #expect(MoodleAssignmentView.submittedAt(of: nil, submission: nil) == nil)
    }

    @Test("the not-submitted line shows for anything not handed in, a draft with files or text included")
    func notSubmittedLine() {
        #expect(MoodleAssignmentView.showsNotSubmitted(Self.submission(nil)))
        #expect(MoodleAssignmentView.showsNotSubmitted(Self.submission("new")))
        #expect(MoodleAssignmentView.showsNotSubmitted(Self.submission("reopened")))
        #expect(MoodleAssignmentView.showsNotSubmitted(Self.submission("draft", files: [Self.file])))
        #expect(MoodleAssignmentView.showsNotSubmitted(Self.submission("draft", text: "<p>Half done</p>")))
        #expect(!MoodleAssignmentView.showsNotSubmitted(Self.submission("submitted")))
    }

    @Test("times show the app's date and time to the minute, never the seconds")
    func minuteTimes() {
        #expect(Date(timeIntervalSince1970: 1_792_337_000).absoluteMinuteString == "10/18 23:23")
        #expect(Date(timeIntervalSince1970: 1_792_337_040).absoluteMinuteString == "10/18 23:24")
    }

    // MARK: - When it fetches

    /// The page's scene phase, which the test moves as the system moves a scene's.
    @Observable
    final class Phase {
        var value: ScenePhase = .active
    }

    private struct Host: View {
        let phase: Phase
        let page: MoodleAssignmentView

        var body: some View {
            NavigationStack { page }
                .environment(\.scenePhase, phase.value)
        }
    }

    @Test("the page fetches the submission when it opens and again each time the app comes back")
    func fetchesOnReturn() async throws {
        let root = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let store = Self.store(in: root, fetches: fetches)
        let phase = Phase()
        let page = MoodleAssignmentView(
            store: store, entry: MoodleCourseAssignments.Entry(record: Self.record, listed: nil),
            courseName: "Data Structures", policy: VisualStylePolicy(preset: .default), accent: .blue
        )
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = UIHostingController(rootView: Host(phase: phase, page: page))
        window.isHidden = false
        defer { window.isHidden = true }

        try await waitUntil { fetches.withLock { $0 } == 1 }
        phase.value = .inactive
        // Leaving the app fetches nothing; the wait only gives a wrong fetch its chance to start.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fetches.withLock { $0 } == 1)
        phase.value = .active
        try await waitUntil { fetches.withLock { $0 } == 2 }
        #expect(store.assignments.submission(of: Self.record).value?.isSubmitted == true)
    }

    // MARK: - From Home

    @Test("an assignment opened while the course sheet covers Home closes the sheet, then shows over Home")
    func overCourseSheet() {
        let root = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = MoodleAssignmentPage(
            entry: MoodleCourseAssignments.Entry(record: Self.record, listed: nil),
            store: Self.store(in: root), courseName: "Data Structures"
        )
        let viewModel = HomeViewModel()

        viewModel.show(page)
        #expect(viewModel.shownAssignment == page)

        viewModel.closeAssignment()
        viewModel.selectedCourse = SDCourse(courseNo: "CS3105301", courseName: "Data Structures")
        viewModel.show(page)
        #expect(viewModel.selectedCourse == nil)
        #expect(viewModel.shownAssignment == nil)

        viewModel.courseSheetDismissed()
        #expect(viewModel.shownAssignment == page)

        // A sign-out while the sheet closes drops the page waiting for it.
        viewModel.closeAssignment()
        viewModel.selectedCourse = SDCourse(courseNo: "CS3105301", courseName: "Data Structures")
        viewModel.show(page)
        viewModel.closeAssignment()
        viewModel.courseSheetDismissed()
        #expect(viewModel.shownAssignment == nil)
    }
}
#endif
