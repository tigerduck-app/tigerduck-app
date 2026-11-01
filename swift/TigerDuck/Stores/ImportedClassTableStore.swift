import Foundation
import Observation

struct ImportedPerson: Identifiable {
    struct Term {
        let semester: String
        let courseNos: [String]
        let courses: [SDCourse]
    }

    let id: UUID
    let studentId: String?
    let nickname: String
    let importedAt: Date
    let sharedAt: Date?
    let terms: [Term]

    var semesters: [String] { terms.map(\.semester).sorted(by: >) }

    func semester(keeping current: String) -> String {
        semesters.contains(current) ? current : semesters.first ?? current
    }

    func courses(in semester: String) -> [SDCourse] {
        terms.first { $0.semester == semester }?.courses ?? []
    }
}

@Observable
final class ImportedClassTableStore: AccountScoped {
    static let shared = ImportedClassTableStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckData", isDirectory: true)
            .appendingPathComponent(fileName)
    )
    private static let fileName = "imported_class_tables.json"

    private(set) var people: [ImportedPerson] = []

    private(set) var shownPersonID: UUID? {
        didSet {
            if shownPersonID != oldValue { previousShownID = .some(oldValue) }
        }
    }

    @ObservationIgnored private var previousShownID: UUID?? = nil

    var shownPerson: ImportedPerson? { people.first { $0.id == shownPersonID } }

    var shownTable: ShownTable {
        ShownTable(personID: shownPersonID, importedAt: shownPerson?.importedAt, lookups: lookups)
    }

    struct ShownTable: Equatable {
        let personID: UUID?
        let importedAt: Date?
        let lookups: Int
    }

    private var lookups = 0

    var hasImportedClassTables: Bool { !people.isEmpty }

    @ObservationIgnored private var owner: String?
    private let file: ImportedClassTableFile
    private let signedInStudentId: () -> String?
    @ObservationIgnored private var mayWrite = true

    init(
        fileURL: URL,
        signedInStudentId: @escaping () -> String? = {
            KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
        }
    ) {
        file = ImportedClassTableFile(url: fileURL)
        self.signedInStudentId = signedInStudentId
        load()
    }

    func person(withStudentId studentId: String) -> ImportedPerson? {
        people.first { $0.studentId == studentId }
    }

    @discardableResult
    func add(
        _ code: ClassTableShareCode,
        nickname: String,
        courses: [String: [SDCourse]],
        importedAt: Date = Date()
    ) -> ImportedPerson? {
        let account = signedInStudentId()
        if let account { accountDidSignIn(studentId: account) }
        let terms = code.terms.map {
            ImportedPerson.Term(semester: $0.semester, courseNos: $0.courseNos, courses: courses[$0.semester] ?? [])
        }

        var updated = people
        let person: ImportedPerson
        if let studentId = code.studentId, let index = people.firstIndex(where: { $0.studentId == studentId }) {
            let old = people[index]
            person = ImportedPerson(
                id: old.id, studentId: old.studentId, nickname: old.nickname,
                importedAt: importedAt, sharedAt: code.sharedAt, terms: terms
            )
            updated[index] = person
        } else {
            let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            person = ImportedPerson(
                id: UUID(), studentId: code.studentId, nickname: name,
                importedAt: importedAt, sharedAt: code.sharedAt, terms: terms
            )
            updated.append(person)
        }
        let newOwner = account ?? owner
        guard save(people: updated, owner: newOwner) else { return nil }
        people = updated
        owner = newOwner
        return person
    }

    enum Change: Equatable { case saved, skipped, failed }

    @discardableResult
    func rename(_ id: UUID, to nickname: String) -> Change {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = people.firstIndex(where: { $0.id == id }) else { return .skipped }
        let old = people[index]
        var updated = people
        updated[index] = ImportedPerson(
            id: old.id, studentId: old.studentId, nickname: name,
            importedAt: old.importedAt, sharedAt: old.sharedAt, terms: old.terms
        )
        guard save(people: updated, owner: owner) else { return .failed }
        people = updated
        return .saved
    }

    @discardableResult
    func updateCourses(
        _ id: UUID, semester: String, courseNos: [String], courses: [SDCourse], importedAt: Date
    ) -> Change {
        guard let index = people.firstIndex(where: { $0.id == id }), people[index].importedAt == importedAt,
              people[index].terms.contains(where: { $0.semester == semester && $0.courseNos == courseNos })
        else { return .skipped }
        let old = people[index]
        let terms = old.terms.map { term in
            term.semester == semester
                ? ImportedPerson.Term(semester: semester, courseNos: courseNos, courses: courses)
                : term
        }
        var updated = people
        updated[index] = ImportedPerson(
            id: old.id, studentId: old.studentId, nickname: old.nickname,
            importedAt: old.importedAt, sharedAt: old.sharedAt, terms: terms
        )
        guard save(people: updated, owner: owner) else { return .failed }
        people = updated
        lookups += 1
        return .saved
    }

    func showPrevious() {
        if case .some(let previous) = previousShownID,
           previous == nil || people.contains(where: { $0.id == previous }) {
            shownPersonID = previous
        } else {
            showNext()
        }
    }

    func showNext() {
        let order: [UUID?] = [nil] + people.map { $0.id }
        let index = order.firstIndex(of: shownPersonID) ?? 0
        shownPersonID = order[(index + 1) % order.count]
    }

    @discardableResult
    func delete(_ id: UUID) -> Change {
        guard people.contains(where: { $0.id == id }) else { return .skipped }
        let updated = people.filter { $0.id != id }
        let newOwner = updated.isEmpty ? nil : owner
        guard save(people: updated, owner: newOwner) else { return .failed }
        people = updated
        owner = newOwner
        if shownPersonID == id { shownPersonID = nil }
        return .saved
    }

    func show(_ id: UUID?) {
        guard id == nil || people.contains(where: { $0.id == id }) else { return }
        shownPersonID = id
    }

    func requestSignOut(unsyncedData: Bool, confirm: ([String]) -> Void, signOut: () -> Void) {
        let lines = [
            unsyncedData ? String(localized: "settings_sign_out_unsynced_data") : nil,
            hasImportedClassTables ? String(localized: "settings_sign_out_imported_tables") : nil,
        ].compactMap { $0 }
        if lines.isEmpty { signOut() } else { confirm(lines) }
    }

    static func forgetAccount(in storage: AccountStorage) {
        ImportedClassTableFile.remove(at: storage.folders.persistent.appendingPathComponent(fileName))
    }

    func removeAll() {
        people = []
        shownPersonID = nil
        previousShownID = nil
        owner = nil
        mayWrite = true
        ImportedClassTableFile.remove(at: file.url)
    }

    func accountDidSignIn(studentId: String) {
        guard !people.isEmpty else { return }
        if let owner, owner != studentId {
            removeAll()
        } else if owner == nil {
            owner = studentId
            save(people: people, owner: owner)
        }
    }

    private func load() {
        switch file.load() {
        case .missing:
            break
        case .unreadable:
            mayWrite = false
        case .contents(let contents):
            owner = contents.owner
            people = contents.people.map(ImportedPerson.init)
        }
    }

    @discardableResult
    private func save(people: [ImportedPerson], owner: String?) -> Bool {
        guard mayWrite else { return false }
        return file.save(.init(owner: owner, people: people.map(\.stored)))
    }
}

private extension ImportedPerson {
    init(_ stored: ImportedClassTableFile.Person) {
        self.init(
            id: stored.id, studentId: stored.studentId, nickname: stored.nickname, importedAt: stored.importedAt,
            sharedAt: stored.sharedAt,
            terms: stored.terms.map { term in
                Term(semester: term.semester, courseNos: term.courseNos, courses: term.courses.map { $0.toSDCourse() })
            }
        )
    }

    var stored: ImportedClassTableFile.Person {
        ImportedClassTableFile.Person(
            id: id, studentId: studentId, nickname: nickname, importedAt: importedAt, sharedAt: sharedAt,
            terms: terms.map { term in
                ImportedClassTableFile.Term(
                    semester: term.semester, courseNos: term.courseNos, courses: term.courses.map { CachedCourse(from: $0) }
                )
            }
        )
    }
}
