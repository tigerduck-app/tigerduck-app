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

    private static func writer(store: WidgetSnapshotStore, people: People) -> WidgetSnapshotWriter {
        WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: WidgetReloadCoordinator(reloader: NoReload()),
            importedPeople: { people.list }
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

    @Test func deletingSomeonesTableChangesTheRevisionTheDevicesFollow() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WidgetClassTableChoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tables = ImportedClassTableStore(fileURL: folder.appending(path: "imported.json"), signedInStudentId: { nil })
        let before = tables.revision

        tables.removeAll()

        #expect(tables.revision != before)
    }
}
