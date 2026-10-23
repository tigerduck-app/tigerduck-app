import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
struct MoodleCourseAssignmentsTests {
    private nonisolated static let courseId = 20119
    private nonisolated static let otherCourseId = 20103
    private nonisolated static let account = "B11399001"
    private nonisolated static let due = Date(timeIntervalSince1970: 1_790_600_000)

    private nonisolated static func record(
        _ id: Int, course: Int = courseId, team: Bool = false, due offset: TimeInterval? = 0,
        noSubmissions: Bool = false
    ) -> MoodleAssignmentRecord {
        MoodleAssignmentRecord(
            assignId: id, cmId: id + 9000, courseId: course, name: "HW \(id)", dueDate: offset.map { due + $0 },
            cutoffDate: nil, allowSubmissionsFromDate: nil, intro: "<p>About HW \(id)</p>", noSubmissions: noSubmissions,
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

    private static func round(_ records: [MoodleAssignmentRecord], in folder: Folder, account: String = account) {
        folder.cache.saveMoodleData(records, fetchedAt: Date(), name: MoodleAssignmentRecord.cacheName, account: account)
        folder.cache.saveAssignments(records.filter { $0.dueDate != nil && !$0.noSubmissions }.map { assignment($0.assignId) })
    }

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

    @Test("the row counts every assignment of the course the round recorded, after the materials, before the grades")
    func sectionRow() async {
        let folder = Folder()
        Self.round([
            Self.record(701), Self.record(702), Self.record(703, due: nil), Self.record(704, noSubmissions: true),
            Self.record(801, course: Self.otherCourseId),
        ], in: folder)
        let store = Self.store(folder, site: Site())
        await store.refreshMaterials()
        await store.refreshGrades()

        #expect(store.sectionRows.map(\.kind) == [.materials, .assignments, .grades])
        #expect(store.sectionRows.first { $0.kind == .assignments }?.count == 4)
        #expect(store.assignments.list.map(\.id) == [701, 702, 703, 704])
        #expect(store.assignments.list.map { $0.listed?.assignmentId } == ["701", "702", nil, nil])
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
        #expect(store.assignments.list.first?.record.intro == "<p>About HW 701</p>")
    }

    @Test("Home's row opens the page with its record, and one no round has recorded has none, which opens Moodle")
    func entryForHomeRow() {
        let folder = Folder()
        Self.round([Self.record(701)], in: folder)
        let store = Self.store(folder, site: Site())
        let listed = Self.assignment(701)

        let entry = store.assignments.entry(for: listed)
        #expect(entry?.record == Self.record(701))
        #expect(entry?.listed === listed)
        #expect(store.assignments.entry(for: Self.assignment(702)) == nil)
    }

    private static func entry(
        _ id: Int, due offset: TimeInterval?, submitted: TimeInterval? = nil, cutoff: TimeInterval? = nil,
        ignored: Bool = false, markedDone: Bool = false, listed: Bool = true
    ) -> MoodleCourseAssignments.Entry {
        let record = Self.record(id, due: offset)
        guard listed, let offset else { return MoodleCourseAssignments.Entry(record: record, listed: nil) }
        return MoodleCourseAssignments.Entry(record: record, listed: SDAssignment(
            assignmentId: String(id), courseNo: "CS3105301", courseName: "Data Structures", title: "HW \(id)",
            dueDate: due + offset, isCompleted: submitted != nil, isArchived: ignored, isLocallyCompleted: markedDone,
            cutoffDate: cutoff.map { due + $0 }, submittedAt: submitted.map { due + $0 }
        ))
    }

    @Test("the list shows what is to come by due time, then the undated in Moodle's order, then the past, latest first")
    func listOrderAndStatuses() {
        let day: TimeInterval = 86_400
        let rows = MoodleAssignmentsView.rows(of: [
            Self.entry(1, due: -10 * day, submitted: -11 * day),
            Self.entry(8, due: nil),
            Self.entry(2, due: 7 * day),
            Self.entry(3, due: -2 * day, submitted: -1 * day),
            Self.entry(4, due: 2 * day),
            Self.entry(9, due: -3 * day, listed: false),
            Self.entry(5, due: -5 * day, cutoff: -1 * day),
            Self.entry(6, due: -1 * day, ignored: true),
            Self.entry(10, due: nil),
            Self.entry(7, due: 3 * day, markedDone: true),
        ], now: Self.due)

        #expect(rows.map(\.id) == [4, 7, 2, 8, 10, 6, 3, 9, 5, 1])
        #expect(rows.map(\.status) == [
            nil, nil, nil, nil, nil, .overdueAcceptable, .submittedLate, nil, .overdueAcceptable, .submitted,
        ])
        #expect(rows.compactMap { $0.status?.badgeLabel } == [
            String(localized: "assignment_status_overdue"), String(localized: "assignment_status_submitted_late"),
            String(localized: "assignment_status_overdue"), String(localized: "assignment_status_submitted"),
        ])
    }

    @Test("an assignment extended for the student stays with those to come until its extension")
    func extendedStaysToCome() throws {
        let day: TimeInterval = 86_400
        let extended = Self.entry(1, due: -1 * day)
        let listed = try #require(extended.listed)
        listed.extensionDueDate = Self.due + 2 * day
        listed.dueDate = Self.due + 2 * day

        let rows = MoodleAssignmentsView.rows(
            of: [Self.entry(2, due: -2 * day), extended, Self.entry(3, due: 3 * day)], now: Self.due
        )

        #expect(rows.map(\.id) == [1, 3, 2])
        #expect(rows.map(\.status) == [nil, nil, .overdueAcceptable])
    }

    @Test("an assignment's page shows the submission it showed last time until the fetch answers")
    func submissionCacheFirst() async {
        let folder = Folder()
        Self.round([Self.record(701)], in: folder)
        await Self.store(folder, site: Site()).assignments.refreshSubmission(of: Self.record(701))

        let reopened = Self.store(folder, site: Site())
        #expect(reopened.assignments.submission(of: Self.record(701)).value?.files == [Self.file])
    }

    @Test("comments and the group's name come where the site offers their calls")
    func commentsAndGroup() async {
        let folder = Folder()
        Self.round([Self.record(701, team: true)], in: folder)
        let site = Site()
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        let submission = store.assignments.submission(of: Self.record(701)).value
        #expect(submission?.comments == [Self.comment])
        #expect(submission?.groupName == "Group 3")
        #expect(site.calls == ["submission 701", "comments 9701 5501", "groups 20119"])
        #expect(cachedSubmission(folder, of: 701)?.groupName == "Group 3")
    }

    @Test("a site that does not offer the comments or the groups call shows neither, without asking")
    func callsNotOffered() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: [])
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        let submission = store.assignments.submission(of: Self.record(701)).value
        #expect(submission?.id == 5501)
        #expect(submission?.comments == nil)
        #expect(submission?.groupName == nil)
        #expect(site.calls == ["submission 701"])
    }

    @Test("a comments or groups call Moodle refuses leaves out only its part")
    func callsRefused() async {
        let folder = Folder()
        let site = Site()
        site.set(
            commentsError: MoodleWebserviceError.accessDenied,
            groupsError: MoodleWebserviceError.malformedResponse(detail: "nopermissions")
        )
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        let feed = store.assignments.submission(of: Self.record(701))
        #expect(feed.status == .ok)
        #expect(feed.value?.files == [Self.file])
        #expect(feed.value?.comments == nil)
        #expect(feed.value?.groupName == nil)
    }

    @Test("a fetch that cannot reach Moodle keeps what the page showed")
    func unreachable() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        site.set(submission: MoodleAssignmentSubmission(
            status: "new", modified: nil, files: [], onlineText: nil, id: 5501, takesComments: true, groupId: 31
        ), commentsError: MoodleWebserviceError.transientNetwork(underlying: "offline"))
        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        let feed = store.assignments.submission(of: Self.record(701))
        #expect(feed.status == .failed)
        #expect(feed.value?.files == [Self.file])
        #expect(feed.value?.comments == [Self.comment])
    }

    @Test("the status the page shows goes on to Home's writer with when it was asked; one it does not show does not")
    func statusHandedOn() async throws {
        let folder = Folder()
        let site = Site()
        let requested = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        let handed = OSAllocatedUnfairLock<[(status: MoodleSubmissionStatus, askedAt: ContinuousClock.Instant)]>(
            initialState: []
        )
        var api = site.api { requested.withLock { $0 = .now } }
        api.submissionFetched = { status, askedAt, _ in handed.withLock { $0.append((status, askedAt)) } }
        let store = MoodleCourseStore(
            courseId: Self.courseId, termCourseIds: [Self.courseId], context: Self.context(folder), api: api
        )

        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        let first = try #require(handed.withLock { $0 }.first)
        #expect(first.status.assignId == 701)
        #expect(first.status.isSubmitted)
        #expect(first.status.submittedAt == Self.handedIn.modified)
        #expect(try first.askedAt <= #require(requested.withLock { $0 }))

        site.set(submission: MoodleAssignmentSubmission(
            status: "new", modified: nil, files: [], onlineText: nil, id: 5501, takesComments: true, groupId: 31
        ), commentsError: MoodleWebserviceError.transientNetwork(underlying: "offline"))
        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        #expect(handed.withLock { $0 }.count == 1)
    }

    @Test("an individual assignment asks for no group, and one that takes no comments asks for none")
    func onlyWhatApplies() async {
        let folder = Folder()
        let site = Site()
        site.set(submission: MoodleAssignmentSubmission(
            status: "submitted", modified: nil, files: [], onlineText: "<p>Answer</p>", id: 5501,
            takesComments: false, groupId: 31
        ))
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.record(701))

        #expect(site.calls == ["submission 701"])
        #expect(store.assignments.submission(of: Self.record(701)).value?.onlineText == "<p>Answer</p>")
    }

    @Test("an assignment that takes no online submission asks Moodle for none")
    func noOnlineSubmission() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)

        await store.assignments.refreshSubmission(of: Self.record(704, noSubmissions: true))

        #expect(site.calls.isEmpty)
        #expect(store.assignments.submission(of: Self.record(704)).value == nil)
    }

    @Test("a sign-out while the submission is on its way writes nothing and asks for no comments or group")
    func signOutDuringFetch() async {
        let folder = Folder()
        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let site = Site()
        let store = Self.store(folder, site: site, signedIn: signedIn) {
            signedIn.withLock { $0 = false }
        }

        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        #expect(site.calls == ["submission 701"])
        #expect(store.assignments.submission(of: Self.record(701)).value == nil)
        #expect(cachedSubmission(folder, of: 701) == nil)
    }

    @Test("a sign-out while the submission is on its way asks for no group either")
    func signOutBeforeGroup() async {
        let folder = Folder()
        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let site = Site()
        site.set(functions: [MoodleAssignmentService.groupsFunction])
        let store = Self.store(folder, site: site, signedIn: signedIn) {
            signedIn.withLock { $0 = false }
        }

        await store.assignments.refreshSubmission(of: Self.record(701, team: true))

        #expect(site.calls == ["submission 701"])
    }

    @Test("signing out deletes the assignment records and every submission")
    func signOutClears() async {
        let folder = Folder()
        Self.round([Self.record(701)], in: folder)
        await Self.store(folder, site: Site()).assignments.refreshSubmission(of: Self.record(701))
        #expect(!MoodleCourseAssignments.records(in: Self.context(folder)).isEmpty)
        #expect(cachedSubmission(folder, of: 701) != nil)

        folder.cache.clearUserScopedData()

        #expect(MoodleCourseAssignments.records(in: Self.context(folder)).isEmpty)
        #expect(cachedSubmission(folder, of: 701) == nil)
        #expect(Self.store(folder, site: Site()).sectionRows.isEmpty)
    }

    @Test("an assignment opened outside a course detail gets the store of the course its record names")
    func storeForAssignment() {
        let folder = Folder()
        Self.round([Self.record(801, course: Self.otherCourseId)], in: folder)

        #expect(MoodleCourseStore.forAssignment("801", context: Self.context(folder))?.courseId == Self.otherCourseId)
        #expect(MoodleCourseStore.forAssignment("802", context: Self.context(folder)) == nil)
        #expect(MoodleCourseStore.forAssignment("801", context: Self.context(folder, account: "B11399002")) == nil)
    }
}
