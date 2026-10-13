import Foundation
import Observation

/// Someone whose class table the user imported from a share code.
struct ImportedPerson: Identifiable {
    struct Term {
        /// The app's semester code, such as `1151`.
        let semester: String
        let courseNos: [String]
        /// The courses' names, times and rooms from NTUST's course query.
        let courses: [SDCourse]
    }

    let id: UUID
    /// Nil when the share code carried none.
    let studentId: String?
    let nickname: String
    let importedAt: Date
    let sharedAt: Date?
    let terms: [Term]

    /// Newest first, as the term picker lists them.
    var semesters: [String] { terms.map(\.semester).sorted(by: >) }

    /// The term to open this class table on: `current` when the person has it, else their latest.
    func semester(keeping current: String) -> String {
        semesters.contains(current) ? current : semesters.first ?? current
    }

    func courses(in semester: String) -> [SDCourse] {
        terms.first { $0.semester == semester }?.courses ?? []
    }
}

/// The class tables imported from share codes, kept on this device only: never in TigerSync, the
/// backend, the App Group or the Watch's data. A sign-out empties it, and so does another student
/// ID signing in; a renewed session and TigerSync turned off leave it alone.
/// See docs/decisions/0023-class-table-share-code.md.
@Observable
final class ImportedClassTableStore {
    static let shared = ImportedClassTableStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckData", isDirectory: true)
            .appendingPathComponent("imported_class_tables.json")
    )

    /// In import order.
    private(set) var people: [ImportedPerson] = []

    /// Whose class table the class table shows, nil for the user's own. Kept in memory only, so
    /// each launch opens on the user's own.
    private(set) var shownPersonID: UUID?

    var shownPerson: ImportedPerson? { people.first { $0.id == shownPersonID } }

    /// Changes when another class table is shown, or the shown one is imported or looked up again,
    /// for every class table page to follow.
    var shownTable: ShownTable {
        ShownTable(personID: shownPersonID, importedAt: shownPerson?.importedAt, lookups: lookups)
    }

    struct ShownTable: Equatable {
        let personID: UUID?
        let importedAt: Date?
        let lookups: Int
    }

    /// Counts `updateCourses` writes, which leave the person's id and import time as they were.
    private var lookups = 0

    var hasImportedClassTables: Bool { !people.isEmpty }

    /// The student ID signed in when the people were imported.
    @ObservationIgnored private var owner: String?
    private let fileURL: URL
    private let signedInStudentId: () -> String?
    /// Off after the file was there but could not be read or decoded, so no write replaces what
    /// it holds, such as people a newer version of the app wrote.
    @ObservationIgnored private var mayWrite = true

    init(
        fileURL: URL,
        signedInStudentId: @escaping () -> String? = {
            KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
        }
    ) {
        self.fileURL = fileURL
        self.signedInStudentId = signedInStudentId
        load()
    }

    func person(withStudentId studentId: String) -> ImportedPerson? {
        people.first { $0.studentId == studentId }
    }

    /// Adds the person `code` is from, each term with its course details from `courses`, keyed
    /// by semester. A student ID already here keeps its entry, place and nickname, and takes the
    /// code's terms, its share time and `importedAt`. Nil for a blank nickname or a failed save.
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

    @discardableResult
    func rename(_ id: UUID, to nickname: String) -> Bool {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = people.firstIndex(where: { $0.id == id }) else { return false }
        let old = people[index]
        var updated = people
        updated[index] = ImportedPerson(
            id: old.id, studentId: old.studentId, nickname: name,
            importedAt: old.importedAt, sharedAt: old.sharedAt, terms: old.terms
        )
        guard save(people: updated, owner: owner) else { return false }
        people = updated
        return true
    }

    /// Swaps in a new lookup of `courseNos`, one term's course codes, for that term of `id`. A term
    /// imported again with other codes while the lookup ran keeps the new import's courses.
    func updateCourses(_ id: UUID, semester: String, courseNos: [String], courses: [SDCourse]) {
        guard let index = people.firstIndex(where: { $0.id == id }),
              people[index].terms.contains(where: { $0.semester == semester && $0.courseNos == courseNos })
        else { return }
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
        guard save(people: updated, owner: owner) else { return }
        people = updated
        lookups += 1
    }

    /// Shows the class table after the shown one: the user's own, then each person in import
    /// order, then the user's own again.
    func showNext() {
        let order: [UUID?] = [nil] + people.map { $0.id }
        let index = order.firstIndex(of: shownPersonID) ?? 0
        shownPersonID = order[(index + 1) % order.count]
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard people.contains(where: { $0.id == id }) else { return false }
        let updated = people.filter { $0.id != id }
        let newOwner = updated.isEmpty ? nil : owner
        guard save(people: updated, owner: newOwner) else { return false }
        people = updated
        owner = newOwner
        if shownPersonID == id { shownPersonID = nil }
        return true
    }

    /// Shows `id`'s class table, or the user's own for nil; an id not in the store is ignored.
    func show(_ id: UUID?) {
        guard id == nil || people.contains(where: { $0.id == id }) else { return }
        shownPersonID = id
    }

    /// The account rows' sign-out deletes the imported class tables, so with any here it calls
    /// `confirm` to ask first; otherwise it signs out at once.
    func requestSignOut(confirm: () -> Void, signOut: () -> Void) {
        if hasImportedClassTables { confirm() } else { signOut() }
    }

    /// For a sign-out by the user: an expired session and TigerSync turned off must not call it.
    func removeAll() {
        people = []
        shownPersonID = nil
        owner = nil
        mayWrite = true
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            if !Self.isMissingFile(error) {
                AppLogger.captureError(error, context: ["phase": "importedClassTables.remove"])
            }
        }
    }

    /// Another student ID than the one the people were imported under empties the store; a store
    /// filled while no one was signed in becomes this account's.
    func accountDidSignIn(studentId: String) {
        guard !people.isEmpty else { return }
        if let owner, owner != studentId {
            removeAll()
        } else if owner == nil {
            owner = studentId
            save(people: people, owner: owner)
        }
    }

    // MARK: - File

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if !Self.isMissingFile(error) {
                mayWrite = false
                AppLogger.captureError(error, context: ["phase": "importedClassTables.read"])
            }
            return
        }
        do {
            let file = try JSONDecoder().decode(StoredFile.self, from: data)
            owner = file.owner
            people = file.people.map { $0.person }
        } catch {
            mayWrite = false
            AppLogger.captureError(error, context: ["phase": "importedClassTables.decode"])
        }
    }

    @discardableResult
    private func save(people: [ImportedPerson], owner: String?) -> Bool {
        guard mayWrite else { return false }
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let staging = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: fileURL, create: true
            )
            defer { try? manager.removeItem(at: staging) }
            var replacement = staging.appendingPathComponent(fileURL.lastPathComponent)
            let data = try JSONEncoder().encode(StoredFile(owner: owner, people: people.map { StoredPerson($0) }))
            // Readable from the first unlock after a restart, unlike `DataCache`'s files: the store
            // reads the file once, and a read refused while the phone is locked would leave it
            // empty for the rest of the run.
            try data.write(to: replacement, options: [.completeFileProtectionUntilFirstUserAuthentication])
            // The replacement must be protected and excluded before it becomes the durable copy.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try replacement.setResourceValues(values)
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: replacement, options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: replacement, to: fileURL)
            }
            return true
        } catch {
            AppLogger.captureError(error, context: ["phase": "importedClassTables.save"])
            return false
        }
    }

    private static func isMissingFile(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)
    }
}

private struct StoredFile: Codable {
    let owner: String?
    let people: [StoredPerson]
}

private struct StoredPerson: Codable {
    let id: UUID
    let studentId: String?
    let nickname: String
    let importedAt: Date
    let sharedAt: Date?
    let terms: [StoredTerm]

    init(_ person: ImportedPerson) {
        id = person.id
        studentId = person.studentId
        nickname = person.nickname
        importedAt = person.importedAt
        sharedAt = person.sharedAt
        terms = person.terms.map { term in
            StoredTerm(
                semester: term.semester,
                courseNos: term.courseNos,
                courses: term.courses.map { CachedCourse(from: $0) }
            )
        }
    }

    var person: ImportedPerson {
        ImportedPerson(
            id: id, studentId: studentId, nickname: nickname, importedAt: importedAt, sharedAt: sharedAt,
            terms: terms.map { term in
                ImportedPerson.Term(
                    semester: term.semester,
                    courseNos: term.courseNos,
                    courses: term.courses.map { $0.toSDCourse() }
                )
            }
        )
    }
}

private struct StoredTerm: Codable {
    let semester: String
    let courseNos: [String]
    let courses: [CachedCourse]
}
