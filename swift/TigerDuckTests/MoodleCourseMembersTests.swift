import Foundation
import os
import Testing
@testable import TigerDuck

/// A course's members in `MoodleCourseStore` over a stand-in `MoodleCourseAPI` and a cache in a
/// folder of its own, then the sections, the detail rows and the list states the screens draw
/// from them. Every person here is made up.
@MainActor
struct MoodleCourseMembersTests {
    private nonisolated static let courseId = 20119
    private nonisolated static let ownId = 42

    private nonisolated static func member(
        _ id: Int,
        _ fullName: String,
        idNumber: String? = nil,
        department: String? = nil,
        roles: [String] = ["student"],
        email: String? = nil,
        groups: [String] = [],
        fields: [MoodleMember.Field] = []
    ) -> MoodleMember {
        member(
            id, fullName, idNumber: idNumber, department: department, email: email, groups: groups, fields: fields,
            roleDetails: roles.enumerated().map { MoodleMember.Role(shortName: $0.element, name: "", sortOrder: $0.offset) }
        )
    }

    private nonisolated static func member(
        _ id: Int,
        _ fullName: String,
        idNumber: String? = nil,
        department: String? = nil,
        email: String? = nil,
        groups: [String] = [],
        fields: [MoodleMember.Field] = [],
        roleDetails: [MoodleMember.Role]
    ) -> MoodleMember {
        MoodleMember(
            id: id, fullName: fullName, idNumber: idNumber, department: department, email: email, groups: groups,
            roles: roleDetails, pictureURL: nil, description: "", interests: [], fields: fields
        )
    }

    /// A picture one pixel square.
    private nonisolated static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    private nonisolated static let me = member(ownId, "B11399001 @ Tiger Duck", idNumber: "B11399001")
    private nonisolated static let classmate = member(43, "B11399002 @ Duck Tiger", idNumber: "B11399002")

    /// What the stand-in site answers, and what the store asked it for.
    private final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var _functions: Set<String> = [MoodleCourseMembersService.membersFunction]
        private var _list = MoodleMemberList(ownId: MoodleCourseMembersTests.ownId, members: [me, classmate])
        private var _calls: [Int] = []
        private var _picture = MoodleCourseMembersTests.png
        private var _pictureCalls: [URL] = []

        func set(functions: Set<String>? = nil, members: [MoodleMember]? = nil, picture: Data? = nil) {
            lock.withLock {
                if let functions { _functions = functions }
                if let members { _list.members = members }
                if let picture { _picture = picture }
            }
        }

        var calls: [Int] { lock.withLock { _calls } }
        var pictureCalls: [URL] { lock.withLock { _pictureCalls } }

        /// `before` runs before members or a picture answer; it throws to fail the request.
        func api(before: @escaping @Sendable () async throws -> Void = {}) -> MoodleCourseAPI {
            MoodleCourseAPI(
                functions: { self.lock.withLock { self._functions } },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                members: { courseId in
                    self.lock.withLock { self._calls.append(courseId) }
                    try await before()
                    return self.lock.withLock { self._list }
                },
                picture: { url in
                    self.lock.withLock { self._pictureCalls.append(url) }
                    try await before()
                    return self.lock.withLock { self._picture }
                }
            )
        }
    }

    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleCourseMembersTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func store(
        _ folder: Folder,
        site: Site,
        account: String = "B11399001",
        signedIn: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: true),
        before: @escaping @Sendable () async throws -> Void = {},
        now: @escaping () -> Date = { Date() }
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [courseId],
            context: MoodleCacheContext(
                account: account, cache: folder.cache, isCurrent: { signedIn.withLock { $0 } }, now: now
            ),
            api: site.api(before: before)
        )
    }

    private func cached(_ folder: Folder, account: String = "B11399001") -> MoodleMemberList? {
        folder.cache.loadMoodleData(MoodleMemberList.self, name: "courses/\(Self.courseId)/members", account: account)?.value
    }

    // MARK: - Cache

    @Test("the members a refresh brings show from the cache the next time, for that account only")
    func cacheFirst() async {
        let folder = Folder()
        let site = Site()
        await Self.store(folder, site: site).refreshMembers()
        #expect(site.calls == [Self.courseId])

        let again = Self.store(folder, site: Site())
        #expect(again.members.value?.members.map(\.id) == [Self.ownId, 43])
        #expect(again.sectionRows == [MoodleSectionRow(kind: .members, count: 2, hasUnread: false)])
        #expect(Self.store(folder, site: Site(), account: "B11399002").members.value == nil)
    }

    @Test("an answer that lands after a sign-out is neither shown nor kept")
    func signOutWhileFetching() async throws {
        let folder = Folder()
        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let answer = ManualSleeper()
        let store = Self.store(folder, site: Site(), signedIn: signedIn) { await answer.sleep(for: .zero) }

        let refresh = Task { await store.refreshMembers() }
        try await answer.waitUntilArmed()
        #expect(store.isSectionRefreshing)
        signedIn.withLock { $0 = false }
        await answer.fire()
        await refresh.value

        #expect(store.members.value == nil)
        #expect(cached(folder) == nil)
    }

    @Test("a post's author is found among the cached members by their Moodle user")
    func authorAmongMembers() async {
        let folder = Folder()
        let store = Self.store(folder, site: Site())
        #expect(store.member(43) == nil)

        await store.refreshMembers()

        #expect(store.member(43) == Self.classmate)
        #expect(store.member(999) == nil)
        #expect(store.member(nil) == nil)
    }

    @Test("signing out deletes the members")
    func signOutClearsThem() async {
        let folder = Folder()
        await Self.store(folder, site: Site()).refreshMembers()
        #expect(cached(folder) != nil)

        folder.cache.clearUserScopedData()

        #expect(cached(folder) == nil)
        #expect(Self.store(folder, site: Site()).sectionRows.isEmpty)
    }

    // MARK: - Section row

    @Test("a site that does not allow the members call hides the row without asking for members")
    func gatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: [MoodleForumService.forumsFunction])
        let store = Self.store(folder, site: site)

        await store.refreshMembers()

        #expect(site.calls.isEmpty)
        #expect(store.sectionRows.isEmpty)
        #expect(store.members.status == .ok)
    }

    @Test("a course that keeps its participants from the account hides the row instead of failing each time")
    func participantsHidden() async {
        let folder = Folder()
        let hidden = Self.store(folder, site: Site()) {
            throw MoodleWebserviceError.malformedResponse(detail: MoodleCourseMembersService.hiddenCode)
        }
        await hidden.refreshMembers()
        #expect(hidden.members.status == .ok)
        #expect(hidden.members.value?.members == [])
        #expect(hidden.sectionRows.isEmpty)

        let broken = Self.store(folder, site: Site()) {
            throw MoodleWebserviceError.malformedResponse(detail: "errorcoursecontextnotvalid")
        }
        await broken.refreshMembers()
        #expect(broken.members.status == .failed)
    }

    @Test("the row counts everyone the account can see, itself included, and hides with no one else", arguments: [
        ([
            MoodleCourseMembersTests.me, MoodleCourseMembersTests.classmate,
            MoodleCourseMembersTests.member(44, "Tiger Teacher", roles: ["editingteacher"]),
        ], 3),
        ([MoodleCourseMembersTests.me, MoodleCourseMembersTests.classmate], 2),
        ([MoodleCourseMembersTests.classmate], 1),
        ([MoodleCourseMembersTests.me], nil),
        ([], nil),
    ] as [([MoodleMember], Int?)])
    func rowCount(members: [MoodleMember], count: Int?) async {
        let folder = Folder()
        let site = Site()
        site.set(members: members)
        let store = Self.store(folder, site: site)

        await store.refreshMembers()

        #expect(store.sectionRows == count.map { [MoodleSectionRow(kind: .members, count: $0, hasUnread: false)] } ?? [])
    }

    @Test("a refresh that empties the list takes the row with it and leaves the screen empty")
    func emptiedListHidesTheRow() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.refreshMembers()
        #expect(!store.sectionRows.isEmpty)

        site.set(members: [])
        await store.refreshMembers()

        #expect(store.sectionRows.isEmpty)
        guard case .sections(let sections) = MoodleMembersView.Content(
            list: store.members.value, isRefreshing: false, failure: nil, query: ""
        ) else {
            Issue.record("an emptied list is not an empty state")
            return
        }
        #expect(sections.isEmpty)
    }

    // MARK: - Freshness

    @Test("members count as fresh for 30 minutes, then the section fetches them again")
    func freshFor30Minutes() async {
        let folder = Folder()
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        await Self.store(folder, site: Site(), now: { fetched }).refreshMembers()

        for (age, fresh) in [(0.0, true), (29 * 60, true), (30 * 60, false), (2 * 3_600, false)] {
            let now = fetched + age
            let reopened = Self.store(folder, site: Site(), now: { now })
            let wait = MoodleRefreshTimer.wait(
                fetchedAt: reopened.membersFetchedAt, lastTry: nil, ttl: reopened.members.ttl, now: now
            )
            #expect(reopened.members.ttl == 30 * 60)
            #expect((wait > 0) == fresh, "age \(age)")
            #expect(reopened.members.status == (fresh ? .ok : .unknown), "age \(age)")
        }
    }

    @Test("a failed refresh keeps the list it had, and turns the section's dot red")
    func failureKeepsTheList() async {
        let folder = Folder()
        await Self.store(folder, site: Site()).refreshMembers()
        let store = Self.store(folder, site: Site()) {
            throw MoodleWebserviceError.transientNetwork(underlying: "offline")
        }

        await store.refreshMembers()

        #expect(store.members.status == .failed)
        #expect(store.sectionStatus == .failed)
        #expect(store.sectionRows == [MoodleSectionRow(kind: .members, count: 2, hasUnread: false)])
        guard case .sections(let sections) = MoodleMembersView.Content(
            list: store.members.value, isRefreshing: false, failure: store.members.failure, query: ""
        ) else {
            Issue.record("a failed refresh hides the cached list")
            return
        }
        #expect(sections.flatMap(\.members).map(\.id) == [Self.ownId, 43])
    }

    // MARK: - Pictures

    private nonisolated static func withPicture(_ member: MoodleMember, rev: Int) -> MoodleMember {
        MoodleMember(
            id: member.id, fullName: member.fullName, idNumber: member.idNumber, department: member.department,
            email: member.email, groups: member.groups, roles: member.roles,
            // Each user has a context of their own, which the path names.
            pictureURL: URL(string: "https://moodle2.ntust.edu.tw/pluginfile.php/\(member.id + 1000)/user/icon/moove/f1?rev=\(rev)"),
            description: member.description, interests: member.interests, fields: member.fields
        )
    }

    private func pictures(_ folder: Folder, account: String = "B11399001") -> [String] {
        let dir = folder.cache.moodleFilesDir.appendingPathComponent(account).appendingPathComponent("pictures")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test("a member's own picture downloads once, then shows from the device in the account's Moodle files")
    func pictureDownloadsOnce() async throws {
        let folder = Folder()
        let site = Site()
        let member = Self.withPicture(Self.classmate, rev: 5)
        let store = Self.store(folder, site: site)

        await store.loadPicture(of: member)
        await store.loadPicture(of: member)

        #expect(store.pictures[try #require(member.pictureURL)] != nil)
        #expect(site.pictureCalls == [member.pictureURL])
        #expect(pictures(folder) == ["43-5"])

        let reopened = Self.store(folder, site: site)
        await reopened.loadPicture(of: member)
        #expect(reopened.pictures[try #require(member.pictureURL)] != nil)
        #expect(site.pictureCalls.count == 1)
    }

    @Test("Moodle's default picture is never downloaded, and a new upload replaces the old file")
    func pictureVersions() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)

        await store.loadPicture(of: Self.classmate)
        #expect(site.pictureCalls.isEmpty)
        #expect(store.pictures.isEmpty)

        await store.loadPicture(of: Self.withPicture(Self.classmate, rev: 5))
        await store.loadPicture(of: Self.withPicture(Self.classmate, rev: 6))
        #expect(pictures(folder) == ["43-6"])
    }

    @Test("a picture that is not an image, fails, or lands after a sign-out is neither shown nor kept")
    func pictureNotKept() async throws {
        let member = Self.withPicture(Self.classmate, rev: 5)
        let url = try #require(member.pictureURL)

        let folder = Folder()
        let site = Site()
        site.set(picture: Data("<html></html>".utf8))
        let store = Self.store(folder, site: site)
        await store.loadPicture(of: member)
        #expect(store.pictures[url] == nil)

        let failing = Self.store(folder, site: Site()) { throw MoodleWebserviceError.transientNetwork(underlying: "offline") }
        await failing.loadPicture(of: member)
        #expect(failing.pictures[url] == nil)

        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let answer = ManualSleeper()
        let late = Self.store(folder, site: Site(), signedIn: signedIn) { await answer.sleep(for: .zero) }
        let load = Task { await late.loadPicture(of: member) }
        try await answer.waitUntilArmed()
        signedIn.withLock { $0 = false }
        await answer.fire()
        await load.value
        #expect(late.pictures[url] == nil)
        #expect(pictures(folder).isEmpty)
    }

    @Test("pictures download one at a time in the order rows ask, and one whose row went away is skipped")
    func picturesInTurn() async throws {
        let folder = Folder()
        let site = Site()
        let answer = ManualSleeper()
        let store = Self.store(folder, site: site) { await answer.sleep(for: .zero) }
        let first = Self.withPicture(Self.me, rev: 1)
        let gone = Self.withPicture(Self.classmate, rev: 1)
        let last = Self.withPicture(Self.member(44, "B11399003 @ Duck Duck", idNumber: "B11399003"), rev: 1)

        let loadFirst = Task { await store.loadPicture(of: first) }
        try await answer.waitUntilArmed()
        let loadGone = Task { await store.loadPicture(of: gone) }
        let loadLast = Task { await store.loadPicture(of: last) }
        for _ in 0..<5 { await Task.yield() }
        #expect(site.pictureCalls == [first.pictureURL])

        loadGone.cancel()
        await answer.fire()
        try await answer.waitUntilArmed(atLeast: 2)
        await answer.fire()
        await loadFirst.value
        await loadGone.value
        await loadLast.value

        #expect(site.pictureCalls == [first.pictureURL, last.pictureURL])
        #expect(store.pictures[try #require(first.pictureURL)] != nil)
        #expect(store.pictures[try #require(gone.pictureURL)] == nil)
        #expect(store.pictures[try #require(last.pictureURL)] != nil)
    }

    @Test("signing out deletes the pictures with every other Moodle file")
    func signOutClearsPictures() async {
        let folder = Folder()
        await Self.store(folder, site: Site()).loadPicture(of: Self.withPicture(Self.classmate, rev: 5))
        #expect(!pictures(folder).isEmpty)

        folder.cache.clearUserScopedData()

        #expect(!FileManager.default.fileExists(atPath: folder.cache.moodleFilesDir.path))
    }

    // MARK: - Members screen

    @Test("with nothing fetched the list shows the first fetch's spinner, then its error, then the spinner on a retry")
    func firstLoad() {
        let error = MoodleWebserviceError.transientNetwork(underlying: "offline")
        guard case .firstLoad(let loading) = MoodleMembersView.Content(list: nil, isRefreshing: true, failure: nil, query: ""),
              case .firstLoad(let failed) = MoodleMembersView.Content(list: nil, isRefreshing: false, failure: error, query: ""),
              case .firstLoad(let retrying) = MoodleMembersView.Content(list: nil, isRefreshing: true, failure: error, query: "")
        else {
            Issue.record("a list never fetched shows something else")
            return
        }
        #expect(loading == nil)
        #expect(failed != nil)
        #expect(retrying == nil)
    }

    @Test("sections run instructors, assistants, other roles by Moodle's order, auditors, then students")
    func sectionOrder() {
        let sections = MoodleMemberSection.sections(of: [
            Self.member(1, "B11399005 @ Student", idNumber: "B11399005"),
            Self.member(2, "B11299044 @ Auditor", idNumber: "B11299044", roles: ["auditor_student"]),
            Self.member(9, "Observer", roleDetails: [MoodleMember.Role(shortName: "observer", name: "Course observer", sortOrder: 9)]),
            Self.member(4, "M11399012 @ Assistant", idNumber: "M11399012", roles: ["teacher"]),
            Self.member(5, "Instructor", roles: ["editingteacher"]),
            // Moodle sends no name for a role that keeps its language pack's name.
            Self.member(8, "Guide", roleDetails: [MoodleMember.Role(shortName: "guide", name: "", sortOrder: 7)]),
            Self.member(7, "No role", roleDetails: []),
        ])

        #expect(sections.map(\.placement.title) == [
            String(localized: "course_detail_instructor_label"),
            String(localized: "course_members_tas"),
            "guide",
            "Course observer",
            String(localized: "course_members_auditors"),
            String(localized: "course_members_students"),
        ])
        #expect(sections.map { $0.members.map(\.id) } == [[5], [4], [8], [9], [2], [1, 7]])
    }

    @Test("a person with several roles shows once, in the first of their sections")
    func severalRoles() {
        let both = Self.member(1, "B11399001 @ Tiger Duck", idNumber: "B11399001", roles: ["student", "teacher"])

        let sections = MoodleMemberSection.sections(of: [both, Self.classmate])

        #expect(sections.map(\.placement) == [.assistants, .students])
        #expect(sections.map { $0.members.map(\.id) } == [[1], [43]])
    }

    @Test("staff list by name and students by student ID, with a student without one last")
    func order() {
        let sections = MoodleMemberSection.sections(of: [
            Self.member(1, "Zed", roles: ["editingteacher"]),
            Self.member(2, "Amy", roles: ["editingteacher"]),
            Self.member(3, "B11399010 @ Ann", idNumber: "B11399010"),
            Self.member(4, "B11399002 @ Zoe"),
            Self.member(5, "Nobody"),
            Self.member(6, "B11299001 @ Bo", idNumber: "B11299001"),
        ])

        #expect(sections.map { $0.members.map(\.id) } == [[2, 1], [6, 4, 3, 5]])
        #expect(sections[1].members.map(\.studentId) == ["B11299001", "B11399002", "B11399010", nil])
        #expect(sections[1].members.map(\.name) == ["Bo", "Zoe", "Ann", "Nobody"])
    }

    @Test("search matches a name, a student ID or a department here, and a search no one matches says so")
    func search() {
        let members = [
            Self.member(1, "B11399001 @ 王小明", idNumber: "B11399001", department: "資訊工程系"),
            Self.member(2, "B11399002 @ Duck Tiger", idNumber: "B11399002", department: "Information Management"),
            Self.member(3, "Tiger Teacher", department: "Computer Science", roles: ["editingteacher"]),
        ]
        func ids(_ query: String) -> [Int] {
            MoodleMemberSection.sections(of: members, matching: query).flatMap { $0.members.map(\.id) }
        }

        #expect(ids("小明") == [1])
        #expect(ids("b113990") == [1, 2])
        #expect(ids("information") == [2])
        #expect(ids("tiger") == [3, 2])
        #expect(ids("  ") == [3, 1, 2])
        guard case .noMatches(let query) = MoodleMembersView.Content(
            list: MoodleMemberList(ownId: nil, members: members), isRefreshing: false, failure: nil, query: " nobody "
        ) else {
            Issue.record("a search with no match shows something else")
            return
        }
        #expect(query == "nobody")
    }

    // MARK: - Member detail

    @Test("the detail lists the student ID, department, email, groups and custom fields, each only when there is one")
    func detailRows() {
        let full = Self.member(
            1, "B11399001 @ Tiger Duck", idNumber: "B11399001", department: "Information Management",
            email: "b11399001@example.edu.tw", groups: ["Group 3", "Group 4"],
            fields: [MoodleMember.Field(name: "Office", value: "TR-412")]
        )

        #expect(MoodleMemberProfile.rows(of: full) == [
            .init(label: String(localized: "sign_in_student_id"), value: .text("B11399001")),
            .init(label: String(localized: "course_member_department"), value: .text("Information Management")),
            .init(label: String(localized: "course_member_email"), value: .email("b11399001@example.edu.tw")),
            .init(label: String(localized: "course_member_groups"), value: .text("Group 3、Group 4")),
            .init(label: "Office", value: .text("TR-412")),
        ])
        #expect(MoodleMemberProfile.rows(of: Self.member(2, "Tiger Teacher")).isEmpty)
        #expect(MoodleMemberProfile.rows(of: Self.member(3, "B11399003 @ Duck")) == [
            .init(label: String(localized: "sign_in_student_id"), value: .text("B11399003")),
        ])
    }

    @Test("a name splits into the part after the @ and the student ID before it")
    func names() {
        #expect(Self.member(1, "B11399001 @ 王小明").name == "王小明")
        #expect(Self.member(1, "B11399001 @ 王小明").studentId == "B11399001")
        #expect(Self.member(1, "B11399001 @ 王小明", idNumber: "B11399009").studentId == "B11399009")
        #expect(Self.member(1, "Tiger Teacher").name == "Tiger Teacher")
        #expect(Self.member(1, "Tiger Teacher").studentId == nil)
        #expect(Self.member(1, " @ 王小明").studentId == nil)
    }
}
