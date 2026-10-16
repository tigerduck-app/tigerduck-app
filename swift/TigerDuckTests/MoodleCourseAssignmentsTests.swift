import Foundation
import os
import Testing
@testable import TigerDuck

/// A course's assignments in `MoodleCourseStore`, from what an assignment round left in a cache in
/// a folder of its own, and each one's submission over a stand-in `MoodleCourseAPI`: the section's
/// row, the page's cached copy, the calls the site's functions allow, and what a sign-out leaves.
/// Every name and id here is made up.
@MainActor
struct MoodleCourseAssignmentsTests {
    private nonisolated static let courseId = 20119
    private nonisolated static let otherCourseId = 20103
    private nonisolated static let account = "B11399001"
    private nonisolated static let due = Date(timeIntervalSince1970: 1_790_600_000)

    private nonisolated static func record(_ id: Int, course: Int = courseId, team: Bool = false) -> MoodleAssignmentRecord {
        MoodleAssignmentRecord(
            assignId: id, cmId: id + 9000, courseId: course, name: "HW \(id)", dueDate: due, cutoffDate: nil,
            allowSubmissionsFromDate: nil, intro: "<p>About HW \(id)</p>", noSubmissions: false,
            introAttachments: [], teamSubmission: team
        )
    }

    private static func assignment(_ id: Int) -> SDAssignment {
        SDAssignment(
            assignmentId: String(id), courseNo: "CS3105301", courseName: "Data Structures", title: "HW \(id)",
            dueDate: due, moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=\(id + 9000)"
        )
    }

    private nonisolated static let file = MoodleFile(
        name: "hw.pdf", size: 870_400,
        url: "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/123/assignsubmission_file/submission_files/5501/hw.pdf",
        mimeType: "application/pdf", modified: Date(timeIntervalSince1970: 1_790_500_000), path: "/"
    )

    private nonisolated static let handedIn = MoodleAssignmentSubmission(
        status: "submitted", modified: Date(timeIntervalSince1970: 1_790_500_000), files: [file], onlineText: nil,
        id: 5501, takesComments: true, groupId: 31
    )

    private nonisolated static let comment = MoodleSubmissionComment(
        id: 901, authorName: "T00001 @ Duck Teacher", created: Date(timeIntervalSince1970: 1_790_505_000),
        content: "<p>Please check page 2.</p>"
    )

    /// What an assignment round leaves: its records for the account, and the assignments Home
    /// lists, which leave out `unlisted`.
    private static func round(
        _ records: [MoodleAssignmentRecord], unlisted: Set<Int> = [], in folder: Folder, account: String = account
    ) {
        folder.cache.saveMoodleData(records, fetchedAt: Date(), name: MoodleAssignmentRecord.cacheName, account: account)
        folder.cache.saveAssignments(records.filter { !unlisted.contains($0.assignId) }.map { assignment($0.assignId) })
    }

    /// What the stand-in site answers, and what the store asked it for.
    private final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var _functions: Set<String> = [
            MoodleAssignmentService.commentsFunction, MoodleAssignmentService.groupsFunction,
            MoodleCourseContentsService.contentsFunction, MoodleGradeService.gradeItemsFunction,
        ]
        private var _submission = MoodleCourseAssignmentsTests.handedIn
        private var _commentsError: (any Error)?
        private var _groupsError: (any Error)?
        private var _calls: [String] = []

        func set(
            functions: Set<String>? = nil,
            submission: MoodleAssignmentSubmission? = nil,
            commentsError: (any Error)? = nil,
            groupsError: (any Error)? = nil
        ) {
            lock.withLock {
                if let functions { _functions = functions }
                if let submission { _submission = submission }
                _commentsError = commentsError
                _groupsError = groupsError
            }
        }

        var calls: [String] { lock.withLock { _calls } }

        private func called(_ call: String) {
            lock.withLock { _calls.append(call) }
        }

        /// `before` runs before the submission answers; it can fail or suspend the request.
        func api(before: @escaping @Sendable () async throws -> Void = {}) -> MoodleCourseAPI {
            MoodleCourseAPI(
                functions: { self.lock.withLock { self._functions } },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                materials: { _ in
                    MoodleCourseMaterials(sections: [MoodleMaterialSection(id: 100, name: "Week 1", materials: [
                        MoodleMaterial(id: 9301, instance: 301, module: "resource", name: "Slides",
                                       content: .file(MoodleCourseAssignmentsTests.file)),
                    ])])
                },
                gradeItems: { _ in
                    [MoodleGradeItem(id: 1, name: "HW 1", type: "mod", module: "assign", cmid: 9701, grade: "90",
                                     maxGrade: 100, isHidden: false, feedback: "")]
                },
                submission: { assignId in
                    self.called("submission \(assignId)")
                    try await before()
                    return self.lock.withLock { self._submission }
                },
                comments: { cmid, submissionId in
                    self.called("comments \(cmid) \(submissionId)")
                    if let error = self.lock.withLock({ self._commentsError }) { throw error }
                    return [MoodleCourseAssignmentsTests.comment]
                },
                groups: { courseId in
                    self.called("groups \(courseId)")
                    if let error = self.lock.withLock({ self._groupsError }) { throw error }
                    return [31: "Group 3", 32: "Lab B"]
                }
            )
        }
    }

    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleCourseAssignmentsTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func context(
        _ folder: Folder,
        account: String = account,
        signedIn: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: true)
    ) -> MoodleCacheContext {
        MoodleCacheContext(account: account, cache: folder.cache, isCurrent: { signedIn.withLock { $0 } })
    }

    private static func store(
        _ folder: Folder,
        site: Site,
        signedIn: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: true),
        before: @escaping @Sendable () async throws -> Void = {}
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [courseId],
            context: context(folder, signedIn: signedIn),
            api: site.api(before: before)
        )
    }

    private func cachedSubmission(_ folder: Folder, of id: Int) -> MoodleAssignmentSubmission? {
        folder.cache.loadMoodleData(
            MoodleAssignmentSubmission.self, name: "courses/\(Self.courseId)/assignments/\(id)", account: Self.account
        )?.value
    }

    // MARK: - Section row

    @Test("the row counts the course's assignments that Home lists, after the materials and before the grades")
    func sectionRow() async {
        let folder = Folder()
        Self.round(
            [Self.record(701), Self.record(702), Self.record(703), Self.record(801, course: Self.otherCourseId)],
            unlisted: [703], in: folder
        )
        let store = Self.store(folder, site: Site())
        await store.refreshMaterials()
        await store.refreshGrades()

        #expect(store.sectionRows.map(\.kind) == [.materials, .assignments, .grades])
        #expect(store.sectionRows.first { $0.kind == .assignments }?.count == 2)
        #expect(store.assignments.list.map(\.assignmentId) == ["701", "702"])
        #expect(MoodleCourseSection.route(for: .assignments, in: store) == .assignments)
    }

    @Test("a course with no assignments of its own has no row")
    func noRow() {
        let folder = Folder()
        Self.round([Self.record(801, course: Self.otherCourseId)], in: folder)

        #expect(Self.store(folder, site: Site()).sectionRows.isEmpty)
    }

    @Test("a round that ends while the course detail shows brings the row once the assignments reload")
    func reload() {
        let folder = Folder()
        let store = Self.store(folder, site: Site())
        #expect(store.sectionRows.isEmpty)

        Self.round([Self.record(701)], in: folder)
        store.assignments.reload()

        #expect(store.sectionRows.map(\.kind) == [.assignments])
        #expect(store.assignments.record(of: Self.assignment(701))?.intro == "<p>About HW 701</p>")
    }

    // MARK: - List

    /// Due `offset` after `due`, which is the list's clock, and handed in `submitted` after it.
    private static func listed(
        _ id: Int, due offset: TimeInterval, submitted: TimeInterval? = nil, cutoff: TimeInterval? = nil,
        ignored: Bool = false, markedDone: Bool = false
    ) -> SDAssignment {
        SDAssignment(
            assignmentId: String(id), courseNo: "CS3105301", courseName: "Data Structures", title: "HW \(id)",
            dueDate: due + offset, isCompleted: submitted != nil, isArchived: ignored, isLocallyCompleted: markedDone,
            cutoffDate: cutoff.map { due + $0 }, submittedAt: submitted.map { due + $0 }
        )
    }

    @Test("the list shows what is to come first, nearest first, then the past, latest first, each as Moodle sees it")
    func listOrderAndStatuses() {
        let day: TimeInterval = 86_400
        let rows = MoodleAssignmentsView.rows(of: [
            Self.listed(1, due: -10 * day, submitted: -11 * day),
            Self.listed(2, due: 7 * day),
            Self.listed(3, due: -2 * day, submitted: -1 * day),
            Self.listed(4, due: 2 * day),
            Self.listed(5, due: -5 * day, cutoff: -1 * day),
            Self.listed(6, due: -1 * day, ignored: true),
            Self.listed(7, due: 3 * day, markedDone: true),
        ], now: Self.due)

        #expect(rows.map(\.id) == ["4", "7", "2", "6", "3", "5", "1"])
        #expect(rows.map(\.status) == [nil, nil, nil, .overdueAcceptable, .submittedLate, .overdueAcceptable, .submitted])
        #expect(rows.compactMap { $0.status?.badgeLabel } == [
            String(localized: "assignment_status_overdue"), String(localized: "assignment_status_submitted_late"),
            String(localized: "assignment_status_overdue"), String(localized: "assignment_status_submitted"),
        ])
    }

    // MARK: - Submission

    @Test("an assignment's page shows the submission it showed last time until the fetch answers")
    func submissionCacheFirst() async {
        let folder = Folder()
        Self.round([Self.record(701)], in: folder)
        await Self.store(folder, site: Site()).assignments.refreshSubmission(of: Self.assignment(701))

        let reopened = Self.store(folder, site: Site())
        #expect(reopened.assignments.submission(of: Self.assignment(701)).value?.files == [Self.file])
    }

    @Test("comments and the group's name come where the site offers their calls")
    func commentsAndGroup() async {
        let folder = Folder()
        Self.round([Self.record(701, team: true)], in: folder)
        let site = Site()
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.assignment(701))

        let submission = store.assignments.submission(of: Self.assignment(701)).value
        #expect(submission?.comments == [Self.comment])
        #expect(submission?.groupName == "Group 3")
        #expect(site.calls == ["submission 701", "comments 9701 5501", "groups 20119"])
        #expect(cachedSubmission(folder, of: 701)?.groupName == "Group 3")
    }

    @Test("a site that does not offer the comments or the groups call shows neither, without asking")
    func callsNotOffered() async {
        let folder = Folder()
        Self.round([Self.record(701, team: true)], in: folder)
        let site = Site()
        site.set(functions: [])
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.assignment(701))

        let submission = store.assignments.submission(of: Self.assignment(701)).value
        #expect(submission?.id == 5501)
        #expect(submission?.comments == nil)
        #expect(submission?.groupName == nil)
        #expect(site.calls == ["submission 701"])
    }

    @Test("a comments or groups call Moodle refuses leaves out only its part")
    func callsRefused() async {
        let folder = Folder()
        Self.round([Self.record(701, team: true)], in: folder)
        let site = Site()
        site.set(
            commentsError: MoodleWebserviceError.accessDenied,
            groupsError: MoodleWebserviceError.malformedResponse(detail: "nopermissions")
        )
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.assignment(701))

        let feed = store.assignments.submission(of: Self.assignment(701))
        #expect(feed.status == .ok)
        #expect(feed.value?.files == [Self.file])
        #expect(feed.value?.comments == nil)
        #expect(feed.value?.groupName == nil)
    }

    @Test("a fetch that cannot reach Moodle keeps what the page showed")
    func unreachable() async {
        let folder = Folder()
        Self.round([Self.record(701, team: true)], in: folder)
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.assignments.refreshSubmission(of: Self.assignment(701))

        site.set(submission: MoodleAssignmentSubmission(
            status: "new", modified: nil, files: [], onlineText: nil, id: 5501, takesComments: true, groupId: 31
        ), commentsError: MoodleWebserviceError.transientNetwork(underlying: "offline"))
        await store.assignments.refreshSubmission(of: Self.assignment(701))

        let feed = store.assignments.submission(of: Self.assignment(701))
        #expect(feed.status == .failed)
        #expect(feed.value?.files == [Self.file])
        #expect(feed.value?.comments == [Self.comment])
    }

    @Test("an individual assignment asks for no group, and one that takes no comments asks for none")
    func onlyWhatApplies() async {
        let folder = Folder()
        Self.round([Self.record(701)], in: folder)
        let site = Site()
        site.set(submission: MoodleAssignmentSubmission(
            status: "submitted", modified: nil, files: [], onlineText: "<p>Answer</p>", id: 5501,
            takesComments: false, groupId: 31
        ))
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.assignment(701))

        #expect(site.calls == ["submission 701"])
        #expect(store.assignments.submission(of: Self.assignment(701)).value?.onlineText == "<p>Answer</p>")
    }

    @Test("an assignment no round recorded still fetches its submission, without comments or a group")
    func withoutRecord() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.assignment(701))

        #expect(site.calls == ["submission 701"])
        #expect(store.assignments.submission(of: Self.assignment(701)).value?.id == 5501)
    }

    // MARK: - Sign-out

    @Test("a sign-out while the submission is on its way writes nothing")
    func signOutDuringFetch() async {
        let folder = Folder()
        Self.round([Self.record(701)], in: folder)
        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let store = Self.store(folder, site: Site(), signedIn: signedIn) {
            signedIn.withLock { $0 = false }
        }

        await store.assignments.refreshSubmission(of: Self.assignment(701))

        #expect(store.assignments.submission(of: Self.assignment(701)).value == nil)
        #expect(cachedSubmission(folder, of: 701) == nil)
    }

    @Test("signing out deletes the assignment records and every submission")
    func signOutClears() async {
        let folder = Folder()
        Self.round([Self.record(701)], in: folder)
        await Self.store(folder, site: Site()).assignments.refreshSubmission(of: Self.assignment(701))
        #expect(!MoodleCourseAssignments.records(in: Self.context(folder)).isEmpty)
        #expect(cachedSubmission(folder, of: 701) != nil)

        folder.cache.clearUserScopedData()

        #expect(MoodleCourseAssignments.records(in: Self.context(folder)).isEmpty)
        #expect(cachedSubmission(folder, of: 701) == nil)
        #expect(Self.store(folder, site: Site()).sectionRows.isEmpty)
    }

    // MARK: - Opening from Home

    @Test("an assignment opened outside a course detail gets the store of the course its record names")
    func storeForAssignment() {
        let folder = Folder()
        Self.round([Self.record(801, course: Self.otherCourseId)], in: folder)

        #expect(MoodleCourseStore.forAssignment("801", context: Self.context(folder))?.courseId == Self.otherCourseId)
        #expect(MoodleCourseStore.forAssignment("802", context: Self.context(folder)) == nil)
        #expect(MoodleCourseStore.forAssignment("801", context: Self.context(folder, account: "B11399002")) == nil)
    }
}
