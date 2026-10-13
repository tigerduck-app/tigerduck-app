import Foundation
import Testing
@testable import TigerDuck

/// `ImportedClassTableStore` over a file in a folder of its own: the order and replacement rules,
/// the shown person, the file it keeps, and when it empties.
@MainActor
struct ImportedClassTableStoreTests {
    private typealias Term = ClassTableShareCode.Term

    /// A folder removed when the test ends, holding the store's file.
    private final class Folder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedClassTableStoreTests-\(UUID().uuidString)", isDirectory: true)
        var file: URL { url.appendingPathComponent("imported_class_tables.json") }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// The student ID the store reads as signed in; a test changes it to sign another account in.
    private final class Account {
        var studentId: String? = "B11300000"
    }

    private static func store(_ folder: Folder, _ account: Account = Account()) -> ImportedClassTableStore {
        ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { account.studentId })
    }

    private static func code(_ studentId: String?, _ terms: [Term], sharedAt: Date? = nil) -> ClassTableShareCode {
        ClassTableShareCode(format: studentId == nil ? .tat2 : .tigerDuck, studentId: studentId, sharedAt: sharedAt, terms: terms)
    }

    private static let fall = Term(semester: "1151", courseNos: ["CS1010001", "MA1010001"])
    private static let spring = Term(semester: "1142", courseNos: ["EE1010002"])

    @Test("people stay in the order they were imported")
    func importOrder() {
        let folder = Folder()
        let store = Self.store(folder)

        store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:])
        store.add(Self.code("B11300002", [Self.fall]), nickname: "B11300002", courses: [:])
        store.add(Self.code(nil, [Self.spring]), nickname: "Hua", courses: [:])

        #expect(store.people.map(\.nickname) == ["Ming", "B11300002", "Hua"])
        #expect(store.hasImportedClassTables)
    }

    @Test("importing a student ID again replaces its terms and keeps its nickname, entry and place")
    func reimportReplacesTerms() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let first = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        store.add(Self.code("B11300002", [Self.fall]), nickname: "Hua", courses: [:])
        let sharedAt = Date(timeIntervalSince1970: 1_791_871_500)

        let again = store.add(
            Self.code("B11300001", [Self.spring], sharedAt: sharedAt), nickname: "Someone else",
            courses: ["1142": [SDCourse(courseNo: "EE1010002", courseName: "Circuits")]]
        )

        #expect(store.people.map(\.nickname) == ["Ming", "Hua"])
        #expect(again?.id == first.id)
        let replaced = try #require(store.person(withStudentId: "B11300001"))
        #expect(replaced.id == first.id)
        #expect(replaced.sharedAt == sharedAt)
        #expect(replaced.terms.map(\.semester) == ["1142"])
        #expect(replaced.terms.first?.courseNos == ["EE1010002"])
        #expect(replaced.terms.first?.courses.map(\.courseName) == ["Circuits"])
    }

    @Test("a new person needs a nickname, and a code without a student ID is always a new person")
    func nicknameRequired() {
        let folder = Folder()
        let store = Self.store(folder)

        #expect(store.add(Self.code("B11300001", [Self.fall]), nickname: "  \n", courses: [:]) == nil)
        store.add(Self.code(nil, [Self.fall]), nickname: "Ming", courses: [:])
        store.add(Self.code(nil, [Self.fall]), nickname: " Ming ", courses: [:])

        #expect(store.people.map(\.nickname) == ["Ming", "Ming"])
    }

    @Test("rename changes the nickname but not to a blank one, and delete removes the person")
    func renameAndDelete() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let ming = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        let hua = try #require(store.add(Self.code("B11300002", [Self.fall]), nickname: "Hua", courses: [:]))

        store.rename(ming.id, to: " Xiao Ming ")
        store.rename(hua.id, to: " ")
        #expect(store.people.map(\.nickname) == ["Xiao Ming", "Hua"])

        store.delete(ming.id)
        #expect(store.people.map(\.id) == [hua.id])
    }

    @Test("deleting the shown person shows the user's own class table again, as a relaunch does")
    func shownPersonFallsBack() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let ming = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        let hua = try #require(store.add(Self.code("B11300002", [Self.fall]), nickname: "Hua", courses: [:]))

        store.show(hua.id)
        store.show(UUID())
        #expect(store.shownPerson?.id == hua.id)
        #expect(Self.store(folder).shownPersonID == nil)

        store.delete(ming.id)
        #expect(store.shownPersonID == hua.id)
        store.delete(hua.id)
        #expect(store.shownPersonID == nil)
        #expect(store.shownPerson == nil)
    }

    @Test("each next class table is the next person in import order, then the user's own again")
    func showNextCycles() throws {
        let folder = Folder()
        let store = Self.store(folder)
        store.showNext()
        #expect(store.shownPersonID == nil)
        let ming = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        let hua = try #require(store.add(Self.code("B11300002", [Self.fall]), nickname: "Hua", courses: [:]))

        store.showNext()
        #expect(store.shownPersonID == ming.id)
        store.showNext()
        #expect(store.shownPersonID == hua.id)
        store.showNext()
        #expect(store.shownPersonID == nil)
    }

    @Test("going back shows the class table before the current one, or the next one with none to go back to")
    func showPreviousSwapsBack() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let ming = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        let hua = try #require(store.add(Self.code("B11300002", [Self.fall]), nickname: "Hua", courses: [:]))

        store.showPrevious()
        #expect(store.shownPersonID == ming.id)
        store.showPrevious()
        #expect(store.shownPersonID == nil)

        store.show(hua.id)
        store.showPrevious()
        #expect(store.shownPersonID == nil)
        store.showPrevious()
        #expect(store.shownPersonID == hua.id)

        store.show(nil)
        store.delete(hua.id)
        store.showPrevious()
        #expect(store.shownPersonID == ming.id)
    }

    @Test("a new lookup replaces one term's course details, keeps the rest, and moves the shown table")
    func updateCourses() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let sharedAt = Date(timeIntervalSince1970: 1_791_871_500)
        let importedAt = Date(timeIntervalSince1970: 1_791_900_000)
        let ming = try #require(store.add(
            Self.code("B11300001", [Self.fall, Self.spring], sharedAt: sharedAt), nickname: "Ming",
            courses: ["1142": [SDCourse(courseNo: "EE1010002", courseName: "Circuits")]], importedAt: importedAt
        ))
        store.show(ming.id)
        let before = store.shownTable

        store.updateCourses(
            ming.id, semester: "1151", courseNos: Self.fall.courseNos,
            courses: [SDCourse(courseNo: "CS1010001", courseName: "Data Structures", classroom: "TR-313")],
            importedAt: ming.importedAt
        )
        store.updateCourses(
            UUID(), semester: "1151", courseNos: Self.fall.courseNos, courses: [], importedAt: ming.importedAt
        )

        #expect(store.shownTable != before)
        for person in [try #require(store.people.first), try #require(Self.store(folder).people.first)] {
            #expect(person.id == ming.id)
            #expect(person.nickname == "Ming")
            #expect(person.importedAt == importedAt)
            #expect(person.sharedAt == sharedAt)
            #expect(person.terms.map(\.courseNos) == [["CS1010001", "MA1010001"], ["EE1010002"]])
            #expect(person.courses(in: "1151").map(\.classroom) == ["TR-313"])
            #expect(person.courses(in: "1142").map(\.courseName) == ["Circuits"])
        }
    }

    @Test("a lookup that ran for the codes before a new import of the term leaves the new import alone")
    func updateCoursesAfterReimport() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let ming = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        let reimported = Term(semester: "1151", courseNos: ["GE1010001"])
        store.add(
            Self.code("B11300001", [reimported]), nickname: "Ming",
            courses: ["1151": [SDCourse(courseNo: "GE1010001", courseName: "Art")]]
        )
        let shown = store.shownTable

        store.updateCourses(
            ming.id, semester: "1151", courseNos: Self.fall.courseNos,
            courses: [SDCourse(courseNo: "CS1010001", courseName: "Data Structures")], importedAt: ming.importedAt
        )

        let person = try #require(store.people.first)
        #expect(person.terms.map(\.courseNos) == [["GE1010001"]])
        #expect(person.courses(in: "1151").map(\.courseName) == ["Art"])
        #expect(store.shownTable == shown)
    }

    @Test("importing the shown person again moves the shown table")
    func reimportMovesTheShownTable() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let ming = try #require(store.add(
            Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:],
            importedAt: Date(timeIntervalSince1970: 1_791_900_000)
        ))
        store.show(ming.id)
        let before = store.shownTable

        store.add(
            Self.code("B11300001", [Self.spring]), nickname: "Ming", courses: [:],
            importedAt: Date(timeIntervalSince1970: 1_791_990_000)
        )

        #expect(store.shownTable.personID == ming.id)
        #expect(store.shownTable != before)
    }

    @Test("someone's class table opens on the term on screen when they shared it, else on their latest")
    func termToOpenOn() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let ming = try #require(store.add(
            Self.code("B11300001", [Self.spring, Self.fall, Term(semester: "114H", courseNos: ["PE1010001"])]),
            nickname: "Ming", courses: [:]
        ))

        #expect(ming.semesters == ["1151", "114H", "1142"])
        #expect(ming.semester(keeping: "1142") == "1142")
        #expect(ming.semester(keeping: "1141") == "1151")
    }

    @Test("a new store reads back everything the last one kept")
    func persistence() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let importedAt = Date(timeIntervalSince1970: 1_791_900_000.5)
        let sharedAt = Date(timeIntervalSince1970: 1_791_871_500)
        let course = SDCourse(
            courseNo: "CS1010001", courseName: "資料結構", instructor: "Teacher", credits: 3, classroom: "TR-313",
            schedule: [2: ["3", "4"]], semester: "1151", classroomMap: ["2-3": "TR-313", "2-4": "TR-313"]
        )
        store.add(
            Self.code("B11300001", [Self.fall, Self.spring], sharedAt: sharedAt), nickname: "小明",
            courses: ["1151": [course]], importedAt: importedAt
        )
        store.add(Self.code(nil, [Self.spring]), nickname: "Hua", courses: [:], importedAt: importedAt)

        let reloaded = Self.store(folder).people

        #expect(reloaded.map(\.id) == store.people.map(\.id))
        #expect(reloaded.map(\.nickname) == ["小明", "Hua"])
        #expect(reloaded.map(\.studentId) == ["B11300001", nil])
        #expect(reloaded.map(\.importedAt) == [importedAt, importedAt])
        #expect(reloaded.map(\.sharedAt) == [sharedAt, nil])
        let terms = try #require(reloaded.first?.terms)
        #expect(terms.map(\.semester) == ["1151", "1142"])
        #expect(terms.map(\.courseNos) == [["CS1010001", "MA1010001"], ["EE1010002"]])
        let detail = try #require(terms.first?.courses.first)
        #expect(detail.courseName == "資料結構")
        #expect(detail.schedule == [2: ["3", "4"]])
        #expect(detail.classroom(weekday: 2, period: "4") == "TR-313")
        #expect(terms.last?.courses.isEmpty == true)
    }

    @Test("the file is left out of backups, after every write")
    func excludedFromBackup() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let ming = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        #expect(try folder.file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        store.rename(ming.id, to: "Xiao Ming")

        #expect(try folder.file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// `unreadable`: the file cannot be opened; otherwise it opens but does not decode, as a file
    /// from a newer version of the app might not.
    @Test("a file that is there but cannot be read or decoded is not written over", arguments: [true, false])
    func unusableFileKept(unreadable: Bool) throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let kept = Data((unreadable ? "{\"people\":[]}" : "{\"people\":\"written by a newer version\"}").utf8)
        try kept.write(to: folder.file)
        let path = folder.file.path
        if unreadable { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        let store = Self.store(folder)
        let imported = store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:])

        #expect(imported == nil)
        #expect(store.people.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(try Data(contentsOf: folder.file) == kept)
    }

    @Test("a failed first write returns no person and publishes no in-memory import")
    func failedFirstWrite() throws {
        let folder = Folder()
        let store = Self.store(folder)
        try Data("blocked parent".utf8).write(to: folder.url)

        #expect(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]) == nil)
        #expect(store.people.isEmpty)
        #expect(store.shownPersonID == nil)
    }

    @Test("failed changes preserve the previous person, selection and durable file", arguments: ["update", "rename", "delete"])
    func failedChangesKeepPreviousState(action: String) throws {
        let folder = Folder()
        let store = Self.store(folder)
        let person = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        store.show(person.id)
        let kept = try Data(contentsOf: folder.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path) }

        switch action {
        case "update":
            #expect(store.add(Self.code("B11300001", [Self.spring]), nickname: "Hua", courses: [:]) == nil)
        case "rename":
            store.rename(person.id, to: "New name")
        default:
            store.delete(person.id)
        }

        #expect(store.people.map(\.id) == [person.id])
        #expect(store.people.first?.nickname == "Ming")
        #expect(store.people.first?.terms.map(\.semester) == ["1151"])
        #expect(store.shownPersonID == person.id)
        #expect(try Data(contentsOf: folder.file) == kept)
    }

    // MARK: - When the store empties

    @Test("signing out empties the store and its file")
    func signOutEmpties() throws {
        let folder = Folder()
        let store = Self.store(folder)
        let ming = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        store.show(ming.id)

        store.removeAll()

        #expect(store.people.isEmpty)
        #expect(!store.hasImportedClassTables)
        #expect(store.shownPersonID == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.file.path))
        #expect(Self.store(folder).people.isEmpty)
    }

    @Test("another student ID signing in empties the store, and the same one signing in again keeps it")
    func signInRules() {
        let folder = Folder()
        let store = Self.store(folder)
        store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:])

        store.accountDidSignIn(studentId: "B11300000")
        #expect(store.people.count == 1)
        #expect(Self.store(folder).people.count == 1)

        store.accountDidSignIn(studentId: "B11399999")
        #expect(store.people.isEmpty)
        #expect(Self.store(folder).people.isEmpty)
    }

    @Test("a store owned by one account is read as that account's after a relaunch")
    func ownerOutlivesRelaunch() {
        let folder = Folder()
        Self.store(folder).add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:])

        let relaunched = Self.store(folder)
        relaunched.accountDidSignIn(studentId: "B11399999")

        #expect(relaunched.people.isEmpty)
    }

    @Test("people imported while signed out stay with the first account that signs in")
    func importedWhileSignedOut() {
        let folder = Folder()
        let account = Account()
        account.studentId = nil
        let store = Self.store(folder, account)
        store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:])

        store.accountDidSignIn(studentId: "B11300000")
        #expect(store.people.count == 1)

        store.accountDidSignIn(studentId: "B11399999")
        #expect(store.people.isEmpty)
    }

    @Test("once its last person is deleted, the store belongs to whoever imports next")
    func emptiedStoreChangesHands() throws {
        let folder = Folder()
        let account = Account()
        let store = Self.store(folder, account)
        let ming = try #require(store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:]))
        store.delete(ming.id)

        account.studentId = "B11399999"
        store.accountDidSignIn(studentId: "B11399999")
        store.add(Self.code("B11300002", [Self.fall]), nickname: "Hua", courses: [:])
        Self.store(folder, account).accountDidSignIn(studentId: "B11399999")

        #expect(Self.store(folder, account).people.map(\.nickname) == ["Hua"])
    }

    @Test("an import under another account than the store's drops the earlier account's people")
    func importUnderAnotherAccount() {
        let folder = Folder()
        let account = Account()
        let store = Self.store(folder, account)
        store.add(Self.code("B11300001", [Self.fall]), nickname: "Ming", courses: [:])

        account.studentId = "B11399999"
        store.add(Self.code("B11300002", [Self.fall]), nickname: "Hua", courses: [:])

        #expect(store.people.map(\.nickname) == ["Hua"])
    }
}
