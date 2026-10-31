#if os(iOS)
import Foundation
import os
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct MoodleAssignmentPageTests {
    nonisolated static let due = Date(timeIntervalSince1970: 1_790_600_000)

    nonisolated static let file = MoodleFile(
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

    nonisolated static func submission(
        _ status: String?, modified: Date? = due - 3600, files: [MoodleFile] = [], text: String? = nil
    ) -> MoodleAssignmentSubmission {
        MoodleAssignmentSubmission(
            status: status, modified: modified, files: files, onlineText: text, id: 5501, takesComments: false,
            groupId: nil
        )
    }

    static func store(
        in root: URL,
        answer: MoodleAssignmentSubmission = submission("submitted"),
        fetches: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0),
        asked: OSAllocatedUnfairLock<[Int]> = OSAllocatedUnfairLock(initialState: []),
        answering answered: Int = .max
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: 20119,
            termCourseIds: [20119],
            context: MoodleCacheContext(
                account: "B11399001",
                cache: TestCache(
                    cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                    persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
                ).moodle,
                isCurrent: { true }
            ),
            api: MoodleCourseAPI(
                functions: { [] },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                submission: { id in
                    let count = fetches.withLock { $0 += 1; return $0 }
                    asked.withLock { $0.append(id) }
                    guard count <= answered else { throw MoodleWebserviceError.httpStatus(code: 503) }
                    return answer
                }
            )
        )
    }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleAssignmentPageTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("the submission time is the fetched one, and before the first fetch answers, the one the round found")
    func submittedAt() {
        let foundByRound = Self.due - 7200
        let fetched = Self.due - 3600
        let listed = Self.assignment(submittedAt: foundByRound)

        #expect(MoodleAssignmentDetails.submittedAt(of: listed, submission: nil) == foundByRound)
        #expect(MoodleAssignmentDetails.submittedAt(of: listed, submission: Self.submission("submitted", modified: fetched))
            == fetched)
        #expect(MoodleAssignmentDetails.submittedAt(of: listed, submission: Self.submission("draft", modified: fetched)) == nil)
        #expect(MoodleAssignmentDetails.submittedAt(of: Self.assignment(submittedAt: nil), submission: nil) == nil)
        #expect(MoodleAssignmentDetails.submittedAt(of: nil, submission: nil) == nil)
    }

    @Test("whether it is handed in comes from the fetch, else Home's row, and nothing says so where Moodle takes nothing online")
    func handedIn() {
        let offline = MoodleAssignmentRecord(
            assignId: 702, cmId: 9702, courseId: 20119, name: "Poster", dueDate: Self.due, cutoffDate: nil,
            allowSubmissionsFromDate: nil, intro: "", noSubmissions: true
        )
        let handedIn = Self.assignment(submittedAt: Self.due - 3600)

        #expect(MoodleAssignmentDetails.isSubmitted(record: Self.record, listed: handedIn, submission: nil) == true)
        #expect(MoodleAssignmentDetails.isSubmitted(record: Self.record, listed: Self.assignment(submittedAt: nil), submission: nil)
            == false)
        #expect(MoodleAssignmentDetails.isSubmitted(record: Self.record, listed: handedIn, submission: Self.submission("draft"))
            == false)
        #expect(MoodleAssignmentDetails.isSubmitted(record: Self.record, listed: nil, submission: Self.submission("submitted"))
            == true)
        #expect(MoodleAssignmentDetails.isSubmitted(record: Self.record, listed: nil, submission: nil) == nil)
        #expect(MoodleAssignmentDetails.isSubmitted(record: offline, listed: handedIn, submission: nil) == nil)
    }

    @Test("the due date counts a later extension, the fetched one once there is one, else the one Home's row has")
    func dueWithExtension() {
        let extended = Self.due + 86_400
        let listed = Self.assignment(submittedAt: nil)
        listed.extend(to: extended)
        let withRow = MoodleCourseAssignments.Entry(record: Self.record, listed: listed)
        let withoutRow = MoodleCourseAssignments.Entry(record: Self.record, listed: nil)
        var answer = Self.submission("new")

        #expect(MoodleAssignmentDetails.due(of: withRow, submission: nil) == extended)
        #expect(MoodleAssignmentDetails.due(of: withRow, submission: answer) == Self.due)
        answer.extensionDueDate = extended
        #expect(MoodleAssignmentDetails.due(of: withoutRow, submission: answer) == extended)
        answer.extensionDueDate = Self.due - 60
        #expect(MoodleAssignmentDetails.due(of: withoutRow, submission: answer) == Self.due)
    }

    @Test("the badge says not submitted, submitted, or how early or late against the due date")
    func badge() {
        let due = Self.due
        #expect(MoodleAssignmentDetails.badge(isSubmitted: nil, submittedAt: nil, due: due) == nil)
        #expect(MoodleAssignmentDetails.badge(isSubmitted: false, submittedAt: nil, due: due) == .notSubmitted)
        #expect(MoodleAssignmentDetails.badge(isSubmitted: true, submittedAt: due - 60, due: nil) == .submitted)
        #expect(MoodleAssignmentDetails.badge(isSubmitted: true, submittedAt: nil, due: due) == .submitted)
        #expect(MoodleAssignmentDetails.badge(isSubmitted: true, submittedAt: due - 907_200, due: due) == .early(907_200))
        // Moodle counts a submission at the due time itself as on time.
        #expect(MoodleAssignmentDetails.badge(isSubmitted: true, submittedAt: due, due: due) == .early(0))
        #expect(MoodleAssignmentDetails.badge(isSubmitted: true, submittedAt: due + 4380, due: due) == .late(4380))

        #expect(MoodleAssignmentDetails.Badge.late(4380).text
            == String(format: String(localized: "assignment_detail_submitted_late_by"), MoodleAssignmentDetails.durationText(4380)))
        #expect(MoodleAssignmentDetails.Badge.early(60).text
            == String(format: String(localized: "assignment_detail_submitted_early"), MoodleAssignmentDetails.durationText(60)))
        #expect(MoodleAssignmentDetails.Badge.submitted.text == String(localized: "assignment_status_submitted"))
        #expect(MoodleAssignmentDetails.Badge.notSubmitted.text == String(localized: "assignment_detail_not_submitted"))
    }

    @Test("the deadline line counts down, then says the deadline passed, or by how long for one not handed in")
    func deadline() {
        let due = Self.due
        #expect(MoodleAssignmentDetails.deadline(due: due, isSubmitted: false, now: due - 100_800) == .left(100_800, urgent: true))
        #expect(MoodleAssignmentDetails.deadline(due: due, isSubmitted: true, now: due - 777_600) == .left(777_600, urgent: false))
        #expect(MoodleAssignmentDetails.deadline(due: due, isSubmitted: nil, now: due - 60) == .left(60, urgent: false))
        #expect(MoodleAssignmentDetails.deadline(due: due, isSubmitted: false, now: due) == .left(0, urgent: true))
        #expect(MoodleAssignmentDetails.deadline(due: due, isSubmitted: true, now: due + 1) == .passed)
        #expect(MoodleAssignmentDetails.deadline(due: due, isSubmitted: nil, now: due + 1) == .passed)
        #expect(MoodleAssignmentDetails.deadline(due: due, isSubmitted: false, now: due + 158_400) == .overdue(158_400))

        #expect(MoodleAssignmentDetails.Deadline.passed.text == String(localized: "assignment_detail_due_passed"))
        #expect(MoodleAssignmentDetails.Deadline.left(60, urgent: false).text
            == String(format: String(localized: "assignment_detail_time_left"), MoodleAssignmentDetails.durationText(60)))
        #expect(MoodleAssignmentDetails.Deadline.overdue(60).text
            == String(format: String(localized: "assignment_detail_overdue_by"), MoodleAssignmentDetails.durationText(60)))
    }

    @Test("each badge and deadline line has its colour, late in Home's, and only the urgent and the overdue lines are bold")
    func colours() {
        let badges: [(MoodleAssignmentDetails.Badge, text: Color, fill: Color)] = [
            (.notSubmitted, Color.textSecondary, Color.textSecondary.opacity(0.16)),
            (.submitted, .green, Color.green.opacity(0.16)),
            (.early(60), .green, Color.green.opacity(0.16)),
            (.late(60), AssignmentStatus.submittedLate.tint, AssignmentStatus.submittedLate.tint.opacity(0.16)),
        ]
        for (badge, text, fill) in badges {
            #expect(badge.tint == text, "\(badge)")
            #expect(badge.fill == fill, "\(badge)")
        }

        let lines: [(MoodleAssignmentDetails.Deadline, text: Color, isEmphasized: Bool, isOverdue: Bool)] = [
            (.left(60, urgent: true), .orange, true, false),
            (.left(60, urgent: false), Color.textSecondary, false, false),
            (.passed, Color.textSecondary, false, false),
            (.overdue(60), Color.badgeRedText, true, true),
        ]
        for (line, text, isEmphasized, isOverdue) in lines {
            #expect(line.tint == text, "\(line)")
            #expect(line.isEmphasized == isEmphasized, "\(line)")
            #expect(line.isOverdue == isOverdue, "\(line)")
        }
    }

    @Test("the submission's card shows for files, text or a submission time, and not for a record with none of them")
    func card() {
        #expect(MoodleAssignmentDetails.showsCard(Self.submission("submitted")))
        #expect(!MoodleAssignmentDetails.showsCard(Self.submission("submitted", modified: nil)))
        #expect(MoodleAssignmentDetails.showsCard(Self.submission("draft", files: [Self.file])))
        #expect(MoodleAssignmentDetails.showsCard(Self.submission("draft", text: "<p>Half done</p>")))
        #expect(!MoodleAssignmentDetails.showsCard(Self.submission("draft")))
        #expect(!MoodleAssignmentDetails.showsCard(Self.submission("new")))
    }

    @Test("points split into the score and the most it could be without the zeros ending them; other grades stay whole")
    func score() {
        #expect(MoodleAssignmentDetails.score(of: "85.00 / 100.00") == .init(value: "85", max: "100"))
        #expect(MoodleAssignmentDetails.score(of: "85.50 / 100.00") == .init(value: "85.5", max: "100"))
        #expect(MoodleAssignmentDetails.score(of: "7,25 / 10,00") == .init(value: "7,25", max: "10"))
        #expect(MoodleAssignmentDetails.score(of: "100 / 100") == .init(value: "100", max: "100"))
        #expect(MoodleAssignmentDetails.score(of: "0.00 / 100.00") == .init(value: "0", max: "100"))
        #expect(MoodleAssignmentDetails.score(of: "B+") == .init(value: "B+", max: nil))
        #expect(MoodleAssignmentDetails.score(of: "85.00 %") == .init(value: "85.00 %", max: nil))
        #expect(MoodleAssignmentDetails.score(of: "Pass / Fail") == .init(value: "Pass / Fail", max: nil))
        #expect(MoodleAssignmentDetails.Score(value: "85", max: "100").spoken
            == "85, \(String(format: String(localized: "course_moodle_grade_out_of"), "100"))")
        #expect(MoodleAssignmentDetails.Score(value: "B+", max: nil).spoken == "B+")
    }

    @Test("a length reads in at most two units, rounded down, and anything under a minute as one minute")
    func durations() {
        let zh = Locale(identifier: "zh-Hant-TW")
        let en = Locale(identifier: "en_US")
        let tenDaysAndAHalf: TimeInterval = 10 * 86_400 + 12 * 3_600 + 40 * 60
        let overAnHour: TimeInterval = 3_600 + 13 * 60 + 40

        #expect(MoodleAssignmentDetails.durationText(tenDaysAndAHalf, locale: zh) == "10天12小時")
        #expect(MoodleAssignmentDetails.durationText(tenDaysAndAHalf, locale: en) == "10 days, 12 hr")
        #expect(MoodleAssignmentDetails.durationText(overAnHour, locale: zh) == "1小時13分鐘")
        #expect(MoodleAssignmentDetails.durationText(overAnHour, locale: en) == "1 hr, 13 min")
        #expect(MoodleAssignmentDetails.durationText(9 * 86_400, locale: zh) == "9天")
        #expect(MoodleAssignmentDetails.durationText(20, locale: en) == "1 min")
        #expect(MoodleAssignmentDetails.durationText(0, locale: zh) == "1分鐘")
    }

    @Test("the small times read the month, day, weekday and time in Taipei, without the seconds")
    func smallTimes() {
        let date = Date(timeIntervalSince1970: 1_792_065_839)
        let zh = Locale(identifier: "zh-Hant-TW")

        #expect(MoodleAssignmentDetails.timeText(date, locale: zh) == "10月15日週四 20:03")
        #expect(MoodleAssignmentDetails.timeText(date, locale: Locale(identifier: "en_US")) == "Thu, Oct 15 at 20:03")
        #expect(MoodleAssignmentDetails.monthText(date, locale: zh) == "10月")
        #expect(MoodleAssignmentDetails.weekdayTimeText(date, locale: zh) == "\(String(localized: "weekday_thu_caption")) 20:03")
    }

    @Test("times show the app's date and time to the minute, never the seconds")
    func minuteTimes() {
        #expect(Date(timeIntervalSince1970: 1_792_337_000).absoluteMinuteString == "10/18 23:23")
        #expect(Date(timeIntervalSince1970: 1_792_337_040).absoluteMinuteString == "10/18 23:24")
    }

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
        try await Task.sleep(for: .milliseconds(300))
        #expect(fetches.withLock { $0 } == 1)
        phase.value = .active
        try await waitUntil { fetches.withLock { $0 } == 2 }
        #expect(store.assignments.submission(of: Self.record).value?.isSubmitted == true)
    }

    @Observable
    final class Shown {
        var entry: MoodleCourseAssignments.Entry

        init(_ record: MoodleAssignmentRecord) {
            entry = MoodleCourseAssignments.Entry(record: record, listed: nil)
        }
    }

    private struct SwitchingHost: View {
        let shown: Shown
        let store: MoodleCourseStore

        var body: some View {
            NavigationStack {
                MoodleAssignmentView(
                    store: store, entry: shown.entry, courseName: "Data Structures",
                    policy: VisualStylePolicy(preset: .default), accent: .blue
                )
            }
        }
    }

    @Test("a page that another assignment takes over in place fetches that assignment")
    func switchedPageFetches() async throws {
        let root = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let store = Self.store(in: root, asked: asked)
        let shown = Shown(Self.record)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = UIHostingController(rootView: SwitchingHost(shown: shown, store: store))
        window.isHidden = false
        defer { window.isHidden = true }

        try await waitUntil { asked.withLock { $0 } == [701] }
        shown.entry = MoodleCourseAssignments.Entry(record: MoodleAssignmentRecord(
            assignId: 702, cmId: 9702, courseId: 20119, name: "HW 3", dueDate: Self.due, cutoffDate: nil,
            allowSubmissionsFromDate: nil, intro: "", noSubmissions: false
        ), listed: nil)
        try await waitUntil(timeout: .seconds(10)) { asked.withLock { $0 } == [701, 702] }
    }

    @Test("each piece of HTML is converted once, however often the page draws it")
    func htmlIsConvertedOnce() {
        let html = "<p>\(UUID().uuidString)</p>"
        var conversions = 0
        let convert = { (_: String) -> String in
            conversions += 1
            return "Converted"
        }
        #expect(MoodleAssignmentDetails.markdown(ofHTML: html, convert: convert) == "Converted")
        #expect(MoodleAssignmentDetails.markdown(ofHTML: html, convert: convert) == "Converted")
        #expect(conversions == 1)
    }

    @Test("an assignment opened while the course sheet covers Home closes the sheet, then shows over Home")
    func overCourseSheet() {
        let root = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = MoodleAssignmentPage(
            entry: MoodleCourseAssignments.Entry(record: Self.record, listed: nil),
            store: Self.store(in: root), courseName: "Data Structures"
        )
        let viewModel = HomeViewModel()

        viewModel.sheets.show(page)
        #expect(viewModel.sheets.shownAssignment == page)

        viewModel.sheets.closeAssignment()
        viewModel.sheets.selectedCourse = SDCourse(courseNo: "CS3105301", courseName: "Data Structures")
        viewModel.sheets.show(page)
        #expect(viewModel.sheets.selectedCourse == nil)
        #expect(viewModel.sheets.shownAssignment == nil)

        viewModel.sheets.courseSheetDismissed()
        #expect(viewModel.sheets.shownAssignment == page)

        viewModel.sheets.closeAssignment()
        viewModel.sheets.selectedCourse = SDCourse(courseNo: "CS3105301", courseName: "Data Structures")
        viewModel.sheets.show(page)
        viewModel.sheets.closeAssignment()
        viewModel.sheets.courseSheetDismissed()
        #expect(viewModel.sheets.shownAssignment == nil)
    }

    @Test("with a sheet over the course sheet that refused to close, the page goes in behind and the course sheet stays")
    func behindAKeptCourseSheet() {
        let root = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = MoodleAssignmentPage(
            entry: MoodleCourseAssignments.Entry(record: Self.record, listed: nil),
            store: Self.store(in: root), courseName: "Data Structures"
        )
        let viewModel = HomeViewModel()
        viewModel.sheets.selectedCourse = SDCourse(courseNo: "CS3105301", courseName: "Data Structures")

        viewModel.sheets.show(page, closingSheet: false)

        #expect(viewModel.sheets.selectedCourse != nil)
        #expect(viewModel.sheets.shownAssignment == page)
    }
}
#endif
