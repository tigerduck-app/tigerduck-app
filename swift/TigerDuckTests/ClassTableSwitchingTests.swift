import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// Someone else's class table on the class table page: which one shows, the terms its picker
/// lists, and that nothing on it edits the user's class table or shows the user's assignments.
///
/// Serialized, and synchronous on the main actor where it can be: the tests swap the catalogue
/// cache and the stored term pick, as `ClassTableSemesterTests` does, and put both back.
@Suite(.serialized)
@MainActor
struct ClassTableSwitchingTests {
    private typealias Term = ClassTableShareCode.Term

    /// `SemesterCatalog.listKey`, which is private to the catalogue.
    private static let catalogueKey = "semesterCatalog.semesters"

    /// A folder removed when the test ends, holding the store's file.
    private final class Folder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassTableSwitchingTests-\(UUID().uuidString)", isDirectory: true)
        var file: URL { url.appendingPathComponent("imported_class_tables.json") }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// Ming shared 115-1 and 114-2; Hua shared 114-2 and 114-1.
    private struct People {
        let store: ImportedClassTableStore
        let ming: ImportedPerson
        let hua: ImportedPerson
    }

    private static func course(_ courseNo: String, _ name: String, semester: String, classroom: String = "") -> SDCourse {
        SDCourse(
            courseNo: courseNo, courseName: name, credits: 3, classroom: classroom,
            schedule: [1: ["3", "4"]], semester: semester
        )
    }

    private static func people(_ folder: Folder) throws -> People {
        let store = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { "B11300000" })
        let ming = try #require(store.add(
            ClassTableShareCode(format: .tigerDuck, studentId: "B11300001", sharedAt: nil, terms: [
                Term(semester: "1151", courseNos: ["CS1010001"]),
                Term(semester: "1142", courseNos: ["EE1010002"]),
            ]),
            nickname: "Ming",
            courses: [
                "1151": [course("CS1010001", "Data Structures", semester: "1151")],
                "1142": [course("EE1010002", "Circuits", semester: "1142")],
            ]
        ))
        let hua = try #require(store.add(
            ClassTableShareCode(format: .tigerDuck, studentId: "B11300002", sharedAt: nil, terms: [
                Term(semester: "1141", courseNos: ["MA1010001"]),
                Term(semester: "1142", courseNos: ["PE1010002"]),
            ]),
            nickname: "Hua",
            courses: [
                "1141": [course("MA1010001", "Calculus", semester: "1141")],
                "1142": [course("PE1010002", "Swimming", semester: "1142")],
            ]
        ))
        return People(store: store, ming: ming, hua: hua)
    }

    private static func withCatalogue(_ terms: [String], storedPick: String?, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let savedTerms = defaults.stringArray(forKey: catalogueKey)
        let savedPick = Defaults[.classTableSelectedSemester]
        defer {
            defaults.set(savedTerms, forKey: catalogueKey)
            Defaults[.classTableSelectedSemester] = savedPick
        }
        defaults.set(terms, forKey: catalogueKey)
        Defaults[.classTableSelectedSemester] = storedPick
        try body()
    }

    private static func show(_ id: UUID?, in people: People, on viewModel: ClassTableViewModel) {
        people.store.show(id)
        // What `ClassTableView` runs when the shown class table changes.
        viewModel.showShownTable()
    }

    // MARK: - Which class table shows

    @Test("a relaunch opens on the user's own class table")
    func relaunchOpensOnTheUser() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let folder = Folder()
            let people = try Self.people(folder)
            people.store.show(people.ming.id)

            let relaunched = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { "B11300000" })
            let viewModel = ClassTableViewModel(importedTables: relaunched)
            viewModel.reloadFromCache()

            #expect(relaunched.people.count == 2)
            #expect(viewModel.shownPerson == nil)
            #expect(viewModel.currentSemester == "1151")
            #expect(viewModel.availableSemesters == ["1151", "1142", "1141"])
            #expect(!viewModel.courses.contains { $0.courseNo == "CS1010001" })
        }
    }

    @Test("someone else's class table keeps the term on screen when they shared it")
    func switchKeepsTheTerm() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)

            Self.show(people.ming.id, in: people, on: viewModel)

            #expect(viewModel.shownPerson?.id == people.ming.id)
            #expect(viewModel.currentSemester == "1151")
            #expect(viewModel.availableSemesters == ["1151", "1142"])
            #expect(viewModel.courses.map(\.courseNo) == ["CS1010001"])
            #expect(viewModel.totalCredits == 3)
        }
    }

    @Test("someone else's class table without the term on screen opens on their latest term")
    func switchFallsBackToTheirLatestTerm() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)

            Self.show(people.hua.id, in: people, on: viewModel)

            #expect(viewModel.currentSemester == "1142")
            #expect(viewModel.availableSemesters == ["1142", "1141"])
            #expect(viewModel.courses.map(\.courseNo) == ["PE1010002"])
            // The move is not the user's pick: their own class table keeps following the newest term.
            #expect(Defaults[.classTableSelectedSemester] == nil)
        }
    }

    @Test("a term picked on someone else's class table is not stored as the user's pick")
    func pickOnAnotherTableIsNotStored() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: "1142") {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)
            Self.show(people.hua.id, in: people, on: viewModel)

            viewModel.currentSemester = "1141"

            #expect(viewModel.courses.map(\.courseNo) == ["MA1010001"])
            #expect(Defaults[.classTableSelectedSemester] == "1142")

            Self.show(nil, in: people, on: viewModel)

            #expect(viewModel.shownPerson == nil)
            #expect(viewModel.currentSemester == "1142")
            #expect(viewModel.availableSemesters == ["1151", "1142", "1141"])
            #expect(Defaults[.classTableSelectedSemester] == "1142")
        }
    }

    @Test("the user's own class table opens on its own term again, the newest when none was picked")
    func backToTheUsersOwnTerm() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)
            Self.show(people.hua.id, in: people, on: viewModel)
            #expect(viewModel.currentSemester == "1142")

            Self.show(nil, in: people, on: viewModel)

            #expect(viewModel.currentSemester == "1151")
            #expect(Defaults[.classTableSelectedSemester] == nil)
        }
    }

    @Test("deleting the shown person shows the user's own class table again")
    func deletingTheShownPersonReturnsToTheUser() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)
            Self.show(people.ming.id, in: people, on: viewModel)

            viewModel.startDeletingPerson()
            #expect(viewModel.isDeletingPerson)
            #expect(viewModel.personInAlert?.nickname == "Ming")
            viewModel.deletePersonInAlert()

            #expect(people.store.people.map(\.nickname) == ["Hua"])
            #expect(viewModel.shownPerson == nil)
            #expect(viewModel.availableSemesters == ["1151", "1142", "1141"])
            #expect(!viewModel.courses.contains { $0.courseNo == "CS1010001" })
            // The confirmation keeps its title while it closes.
            #expect(viewModel.personInAlert?.nickname == "Ming")
        }
    }

    @Test("an open rename or delete acts on the person it names, though another window switched since")
    func alertsActOnThePersonTheyName() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)
            Self.show(people.ming.id, in: people, on: viewModel)

            viewModel.startRenamingPerson()
            Self.show(people.hua.id, in: people, on: viewModel)
            viewModel.nicknameDraft = "Xiao Ming"
            viewModel.saveNickname()
            #expect(people.store.people.map(\.nickname) == ["Xiao Ming", "Hua"])

            Self.show(people.ming.id, in: people, on: viewModel)
            viewModel.startDeletingPerson()
            Self.show(people.hua.id, in: people, on: viewModel)
            viewModel.deletePersonInAlert()
            #expect(people.store.people.map(\.nickname) == ["Hua"])
        }
    }

    // MARK: - Read-only

    @Test("someone else's class table edits nothing and shows none of the user's assignments")
    func anotherTableIsReadOnly() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)
            Self.show(people.ming.id, in: people, on: viewModel)
            let assignment = SDAssignment(
                assignmentId: "1", courseNo: "CS1010001", courseName: "Data Structures",
                title: "Homework 1", dueDate: .distantFuture
            )
            viewModel.assignments = [assignment]
            let theirs = try #require(viewModel.courses.first)

            #expect(!viewModel.hasAssignment(for: "CS1010001"))
            #expect(viewModel.assignmentsFor(courseNo: "CS1010001").isEmpty)
            #expect(!viewModel.offersIgnoreAssignments)
            #expect(!viewModel.ignoresAssignments(of: "CS1010001"))
            #expect(viewModel.todayCourses.isEmpty)

            viewModel.startRename(theirs)
            viewModel.startRecolor(theirs)
            #expect(!viewModel.showRenameAlert)
            #expect(viewModel.courseToRename == nil)
            #expect(viewModel.courseToRecolor == nil)
            #expect(!viewModel.addCourse(Self.course("GE1010001", "Art", semester: "1151")))
            viewModel.deleteCourse(theirs)
            #expect(viewModel.courses.map(\.courseNo) == ["CS1010001"])

            // The user's own class table shows the same assignment.
            Self.show(nil, in: people, on: viewModel)
            viewModel.assignments = [assignment]
            #expect(viewModel.hasAssignment(for: "CS1010001"))
        }
    }

    @Test("a switch to someone else's class table closes the user's own edits, which then save nothing")
    func switchClosesTheUsersEdits() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)
            let own = Self.course("GE1010009", "Own course", semester: "1151")
            viewModel.courseToRename = own
            viewModel.renameText = "Renamed"
            viewModel.showRenameAlert = true
            viewModel.courseToRecolor = own
            viewModel.showAddCourse = true
            let customNames = DataCache.shared.loadCourseCustomNames()
            let userAdded = DataCache.shared.loadUserAddedCourses().map(\.courseNo)

            // Another window switches while the rename alert is up.
            Self.show(people.ming.id, in: people, on: viewModel)
            #expect(!viewModel.showRenameAlert)
            #expect(viewModel.courseToRecolor == nil)
            #expect(!viewModel.showAddCourse)

            viewModel.courseToRename = own
            viewModel.confirmRename()
            viewModel.revertRename(own)
            viewModel.removeUserAddedCourse(courseNo: "CS1010001")
            #expect(DataCache.shared.loadCourseCustomNames() == customNames)
            #expect(DataCache.shared.loadUserAddedCourses().map(\.courseNo) == userAdded)
        }
    }

    @Test("someone else's course numbers get no saved colour of the user's")
    func noSavedColoursForTheirCourses() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let folder = Folder()
            let store = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { "B11300000" })
            // New each run: the colour map is the test host's own, and a run that broke the rule
            // would have saved a colour for a fixed number.
            let theirs = "QQ" + UUID().uuidString.prefix(7)
            #expect(TigerDuckTheme.courseColorMap[theirs] == nil)
            let person = try #require(store.add(
                ClassTableShareCode(format: .tigerDuck, studentId: "B11300003", sharedAt: nil, terms: [
                    Term(semester: "1151", courseNos: [theirs]),
                ]),
                nickname: "Chen",
                courses: ["1151": [Self.course(theirs, "Rare course", semester: "1151")]]
            ))
            let viewModel = ClassTableViewModel(importedTables: store)

            store.show(person.id)
            viewModel.showShownTable()

            #expect(viewModel.courses.map(\.courseNo) == [theirs])
            #expect(TigerDuckTheme.courseColorMap[theirs] == nil)
        }
    }

    // MARK: - Rename

    @Test("Save waits for a nickname, and a saved one replaces the person's")
    func renameNeedsANickname() throws {
        try Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let people = try Self.people(Folder())
            let viewModel = ClassTableViewModel(importedTables: people.store)
            Self.show(people.ming.id, in: people, on: viewModel)

            viewModel.startRenamingPerson()
            #expect(viewModel.isRenamingPerson)
            #expect(viewModel.nicknameDraft == "Ming")
            #expect(viewModel.canSaveNickname)

            viewModel.nicknameDraft = " \n "
            #expect(!viewModel.canSaveNickname)

            viewModel.nicknameDraft = " Xiao Ming "
            #expect(viewModel.canSaveNickname)
            viewModel.saveNickname()

            #expect(viewModel.shownPerson?.nickname == "Xiao Ming")
            #expect(people.store.people.map(\.nickname) == ["Xiao Ming", "Hua"])
        }
    }

    // MARK: - Pull to refresh

    @Test("a pull on someone else's class table looks their term up again, and only that term")
    func pullLooksTheTermUpAgain() async throws {
        let defaults = UserDefaults.standard
        let savedTerms = defaults.stringArray(forKey: Self.catalogueKey)
        let savedPick = Defaults[.classTableSelectedSemester]
        defer {
            defaults.set(savedTerms, forKey: Self.catalogueKey)
            Defaults[.classTableSelectedSemester] = savedPick
        }
        defaults.set(["1151", "1142", "1141"], forKey: Self.catalogueKey)
        Defaults[.classTableSelectedSemester] = nil

        let people = try Self.people(Folder())
        var lookups: [(semester: String, courseNos: [String], current: [String])] = []
        var answers: [[SDCourse]?] = [
            [Self.course("CS1010001", "Data Structures", semester: "1151", classroom: "TR-313")],
            nil,
        ]
        let viewModel = ClassTableViewModel(importedTables: people.store) { semester, courseNos, current in
            lookups.append((semester, courseNos, current.map(\.courseNo)))
            return answers.removeFirst()
        }

        await viewModel.refreshShownPerson()
        #expect(lookups.isEmpty, "the user's own class table refreshes from the school as before")

        Self.show(people.ming.id, in: people, on: viewModel)
        await viewModel.refreshShownPerson()

        #expect(lookups.map(\.semester) == ["1151"])
        #expect(lookups.first?.courseNos == ["CS1010001"])
        #expect(lookups.first?.current == ["CS1010001"])
        #expect(viewModel.courses.map(\.classroom) == ["TR-313"])
        #expect(!viewModel.showsLookupFailed)
        #expect(!viewModel.isRefreshingShownPerson)
        var stored = try #require(people.store.people.first)
        #expect(stored.courses(in: "1151").map(\.classroom) == ["TR-313"])
        #expect(stored.courses(in: "1142").map(\.courseName) == ["Circuits"])

        // No lookup went through this time: the rows stay and the page says the refresh failed.
        await viewModel.refreshShownPerson()

        #expect(lookups.count == 2)
        #expect(viewModel.showsLookupFailed)
        stored = try #require(people.store.people.first)
        #expect(stored.courses(in: "1151").map(\.classroom) == ["TR-313"])
        #expect(viewModel.courses.map(\.classroom) == ["TR-313"])
    }

    // MARK: - Sign-out

    @Test("failed rename, delete and refresh saves preserve the table and surface a save error", arguments: ["rename", "delete", "refresh"])
    func failedPersonMutation(operation: String) async throws {
        let folder = Folder()
        let people = try Self.people(folder)
        let viewModel = ClassTableViewModel(importedTables: people.store) { _, _, _ in
            [Self.course("CS1010001", "Updated", semester: "1151")]
        }
        Self.show(people.ming.id, in: people, on: viewModel)
        viewModel.currentSemester = "1151"
        let before = try Data(contentsOf: folder.file)
        let shown = people.store.shownTable
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path) }

        switch operation {
        case "rename":
            viewModel.startRenamingPerson()
            viewModel.nicknameDraft = "New nickname"
            viewModel.saveNickname()
        case "delete":
            viewModel.startDeletingPerson()
            viewModel.deletePersonInAlert()
        default:
            await viewModel.refreshShownPerson()
        }

        #expect(viewModel.showsSaveFailed)
        #expect(!viewModel.showsLookupFailed)
        #expect(people.store.shownTable == shown)
        #expect(viewModel.shownPerson?.nickname == "Ming")
        #expect(viewModel.courses.map(\.courseName) == ["Data Structures"])
        #expect(try Data(contentsOf: folder.file) == before)
    }

    @Test("a refresh that finishes after reimporting the same course codes cannot replace the new import")
    func refreshAfterSameCodesReimport() async throws {
        let folder = Folder()
        let people = try Self.people(folder)
        let viewModel = ClassTableViewModel(importedTables: people.store) { semester, _, _ in
            _ = try? #require(people.store.add(
                ClassTableShareCode(format: .tigerDuck, studentId: "B11300001", sharedAt: nil, terms: [
                    Term(semester: semester, courseNos: ["CS1010001"]),
                ]),
                nickname: "Ming", courses: [semester: [Self.course("CS1010001", "New import", semester: semester)]],
                importedAt: people.ming.importedAt.addingTimeInterval(1)
            ))
            return [Self.course("CS1010001", "Older lookup", semester: semester)]
        }
        Self.show(people.ming.id, in: people, on: viewModel)
        viewModel.currentSemester = "1151"

        await viewModel.refreshShownPerson()

        #expect(people.store.shownPerson?.courses(in: "1151").map(\.courseName) == ["New import"])
        #expect(viewModel.courses.map(\.courseName) == ["New import"])
        #expect(!viewModel.showsSaveFailed)
        #expect(!viewModel.showsLookupFailed)
    }

    @Test("signing out asks first only while imported class tables would go with it")
    func signOutAsksOnlyWithImportedTables() throws {
        let folder = Folder()
        let store = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { "B11300000" })
        var asked = 0
        var signedOut = 0

        store.requestSignOut(confirm: { asked += 1 }, signOut: { signedOut += 1 })
        #expect(asked == 0)
        #expect(signedOut == 1)

        store.add(
            ClassTableShareCode(format: .tigerDuck, studentId: "B11300001", sharedAt: nil, terms: [
                Term(semester: "1151", courseNos: ["CS1010001"]),
            ]),
            nickname: "Ming", courses: [:]
        )
        store.requestSignOut(confirm: { asked += 1 }, signOut: { signedOut += 1 })
        #expect(asked == 1)
        #expect(signedOut == 1)
    }
}
