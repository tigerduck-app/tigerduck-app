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

    var hasImportedClassTables: Bool { !people.isEmpty }

    /// The student ID signed in when the people were imported.
    @ObservationIgnored private var owner: String?
    private let fileURL: URL
    private let signedInStudentId: () -> String?
    /// Off after the file was there but could not be read, so no write replaces what it holds.
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
    /// by semester. A student ID already here keeps its entry, place and nickname and takes the
    /// code's terms in place of its own. Nil when a new person's nickname is blank.
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

        let person: ImportedPerson
        if let studentId = code.studentId, let index = people.firstIndex(where: { $0.studentId == studentId }) {
            let old = people[index]
            person = ImportedPerson(
                id: old.id, studentId: old.studentId, nickname: old.nickname,
                importedAt: importedAt, sharedAt: code.sharedAt, terms: terms
            )
            people[index] = person
        } else {
            let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            person = ImportedPerson(
                id: UUID(), studentId: code.studentId, nickname: name,
                importedAt: importedAt, sharedAt: code.sharedAt, terms: terms
            )
            people.append(person)
        }
        owner = account ?? owner
        save()
        return person
    }

    /// Ignores a blank nickname, which the store never keeps.
    func rename(_ id: UUID, to nickname: String) {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = people.firstIndex(where: { $0.id == id }) else { return }
        let old = people[index]
        people[index] = ImportedPerson(
            id: old.id, studentId: old.studentId, nickname: name,
            importedAt: old.importedAt, sharedAt: old.sharedAt, terms: old.terms
        )
        save()
    }

    func delete(_ id: UUID) {
        guard people.contains(where: { $0.id == id }) else { return }
        people.removeAll { $0.id == id }
        if shownPersonID == id { shownPersonID = nil }
        if people.isEmpty { owner = nil }
        save()
    }

    /// Shows `id`'s class table, or the user's own for nil; an id not in the store is ignored.
    func show(_ id: UUID?) {
        guard id == nil || people.contains(where: { $0.id == id }) else { return }
        shownPersonID = id
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
            save()
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
            people = file.people.map(\.person)
        } catch {
            AppLogger.captureError(error, context: ["phase": "importedClassTables.decode"])
        }
    }

    private func save() {
        guard mayWrite else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(StoredFile(owner: owner, people: people.map(StoredPerson.init)))
            // Readable from the first unlock after a restart, unlike `DataCache`'s files: the store
            // reads the file once, and a read refused while the phone is locked would leave it
            // empty for the rest of the run.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // An atomic write replaces the file, and the exclusion with it, so it is set each time.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try url.setResourceValues(values)
        } catch {
            AppLogger.captureError(error, context: ["phase": "importedClassTables.save"])
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
