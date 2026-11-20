import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct WidgetClassTableChoiceTests {
    private struct NoReload: WidgetReloadCoordinator.Reloader {
        func reloadAllTimelines() {}
    }

    @MainActor
    private final class People {
        var list: [ImportedPerson] = []
    }

    private static func person(_ nickname: String, courses: [SDCourse]) -> ImportedPerson {
        let semester = CourseSelectionService.currentSemesterCode()
        return ImportedPerson(
            id: UUID(), studentId: nil, nickname: nickname, importedAt: Date(), sharedAt: nil,
            terms: [.init(semester: semester, courseNos: courses.map(\.courseNo), courses: courses)]
        )
    }

    private static func store() -> (WidgetSnapshotStore, suite: String) {
        let suite = "WidgetClassTableChoiceTests.\(UUID().uuidString)"
        return (WidgetSnapshotStore(appGroupIdentifier: suite), suite)
    }

    private static func writer(
        store: WidgetSnapshotStore, people: People, calendar: AcademicCalendar = .empty, optedIn: Set<Int> = []
    ) -> WidgetSnapshotWriter {
        WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: WidgetReloadCoordinator(reloader: NoReload()),
            importedPeople: { people.list },
            schoolCalendar: { (calendar, optedIn) }
        )
    }

    @Test func aWidgetWithNoChoiceShowsTheUsersOwnTable() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let own = WidgetFixtures.snapshot()
        store.writeSnapshot(own)
        store.writePeople([WidgetPersonSnapshot(id: UUID().uuidString, name: "Ming", snapshot: WidgetFixtures.snapshot(courses: []))])

        #expect(store.readSnapshot(of: nil) == own)
    }

    @Test func aWidgetSetToSomeoneShowsTheirTableUntilItIsDeleted() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let own = WidgetFixtures.snapshot()
        let theirs = WidgetFixtures.snapshot(courses: Array(WidgetFixtures.week().prefix(2)))
        let id = UUID().uuidString
        store.writeSnapshot(own)
        store.writePeople([WidgetPersonSnapshot(id: id, name: "Ming", snapshot: theirs)])

        #expect(store.readSnapshot(of: id) == theirs)

        store.writePeople([])
        #expect(store.readPeople().isEmpty)
        #expect(store.readSnapshot(of: id) == own)
    }

    @Test func theWriterSendsEachAddedTableOfThisTermAndDropsDeletedOnes() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let people = People()
        let ming = Self.person("Ming", courses: [
            SDCourse(courseNo: "ZZ1001", courseName: "Synthetic Course", classroom: "RB-101", schedule: [2: ["3", "4"]]),
        ])
        let hua = Self.person("Hua", courses: [])
        people.list = [ming, hua]
        let writer = Self.writer(store: store, people: people)

        writer.regenerate()

        let written = store.readPeople()
        #expect(written.map(\.id) == [ming.id.uuidString, hua.id.uuidString])
        #expect(written.map(\.name) == ["Ming", "Hua"])
        let course = try #require(written.first?.snapshot.courses.first)
        #expect(course.displayName == "Synthetic Course")
        #expect(course.classroom == "RB-101")
        #expect(course.schedule == [2: ["3", "4"]])
        #expect(written.last?.snapshot.courses.isEmpty == true)

        people.list = [hua]
        writer.regenerate()
        #expect(store.readPeople().map(\.id) == [hua.id.uuidString])

        people.list = []
        writer.regenerate()
        #expect(store.readPeople().isEmpty)
        #expect(store.readSnapshot(of: hua.id.uuidString) == store.readSnapshot())
    }

    @Test func aRenameReachesTheWidgetsChoice() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let people = People()
        let ming = Self.person("Ming", courses: [])
        people.list = [ming]
        let writer = Self.writer(store: store, people: people)
        writer.regenerate()

        people.list = [ImportedPerson(
            id: ming.id, studentId: nil, nickname: "Ming 2", importedAt: ming.importedAt, sharedAt: nil, terms: ming.terms
        )]
        writer.regenerate()

        #expect(store.readPeople().map(\.name) == ["Ming 2"])
    }

    @Test func aHolidayTheUserOptedIntoStaysQuietOnSomeoneElsesTable() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let people = People()
        people.list = [Self.person("Ming", courses: [])]
        let today = AcademicCalendar.startOfDay(AppClock.now())
        func day(_ offset: Int) throws -> Date {
            try #require(AcademicCalendar.calendar.date(byAdding: .day, value: offset, to: today))
        }
        let calendar = try AcademicCalendar(
            revision: 1,
            terms: [SemesterTerm(code: CourseSelectionService.currentSemesterCode(), start: day(-30), end: day(60))],
            holidays: [Holiday(id: 1, nameZh: "測試假日", nameEn: "Test Holiday", start: day(7), end: day(7))]
        )
        let holiday = try WidgetTimelineDerivation.dateKey(for: day(7))

        Self.writer(store: store, people: people, calendar: calendar, optedIn: [1]).regenerate()

        #expect(store.readSnapshot()?.quietDayKeys?.contains(holiday) == false)
        #expect(store.readPeople().first?.snapshot.quietDayKeys?.contains(holiday) == true)
    }

    @Test func oneUnreadablePersonLeavesTheOthersToTheWidget() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let ming = WidgetPersonSnapshot(id: UUID().uuidString, name: "Ming", snapshot: WidgetFixtures.snapshot())
        let hua = WidgetPersonSnapshot(id: UUID().uuidString, name: "Hua", snapshot: WidgetFixtures.snapshot(courses: []))
        store.writePeople([ming, hua])
        let defaults = try #require(UserDefaults(suiteName: suite))
        let written = try #require(defaults.data(forKey: WidgetSnapshot.peopleStoreKey))
        let elements = try #require(JSONSerialization.jsonObject(with: written) as? [Any])
        let unreadable: [Any] = [elements[0], ["id": 1], elements[1]]
        defaults.set(try JSONSerialization.data(withJSONObject: unreadable), forKey: WidgetSnapshot.peopleStoreKey)

        #expect(store.readPeople() == [ming, hua])
    }

    @Test func deletingSomeonesTableChangesTheRevisionTheDevicesFollow() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WidgetClassTableChoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tables = ImportedClassTableStore(fileURL: folder.appending(path: "imported.json"), signedInStudentId: { nil })
        let before = tables.revision

        tables.removeAll()

        #expect(tables.revision != before)
    }
}
