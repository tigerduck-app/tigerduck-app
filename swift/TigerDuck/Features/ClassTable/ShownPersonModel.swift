import Foundation

@MainActor
@Observable
final class ShownPersonModel {
    typealias TermLookup = @MainActor (
        _ semester: String, _ courseNos: [String], _ current: [CourseStore.Course]
    ) async -> [CourseStore.Course]?

    @ObservationIgnored let store: ImportedClassTableStore
    @ObservationIgnored private let lookUpTerm: TermLookup
    private var displayedPerson: ImportedPerson?

    var isRenamingPerson = false
    var nicknameDraft = ""
    var isDeletingPerson = false
    private(set) var personInAlert: ImportedPerson?
    var showsLookupFailed = false
    var showsSaveFailed = false
    private(set) var isRefreshing = false

    init(store: ImportedClassTableStore, lookUpTerm: @escaping TermLookup) {
        self.store = store
        self.lookUpTerm = lookUpTerm
        displayedPerson = store.shownPerson
    }

    var shownPerson: ImportedPerson? {
        guard let displayedPerson else { return nil }
        return store.people.first { $0.id == displayedPerson.id } ?? displayedPerson
    }

    func showStoredPerson() {
        displayedPerson = store.shownPerson
    }

    var canSaveNickname: Bool {
        !nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func startRenamingPerson() {
        guard let shownPerson else { return }
        personInAlert = shownPerson
        nicknameDraft = shownPerson.nickname
        isRenamingPerson = true
    }

    func saveNickname() {
        guard let personInAlert else { return }
        if store.rename(personInAlert.id, to: nicknameDraft, for: AccountSession.school.currentSignIn) == .failed { showsSaveFailed = true }
    }

    func startDeletingPerson() {
        guard let shownPerson else { return }
        personInAlert = shownPerson
        isDeletingPerson = true
    }

    func deletePersonInAlert() {
        guard let personInAlert else { return }
        if store.delete(personInAlert.id, for: AccountSession.school.currentSignIn) == .failed { showsSaveFailed = true }
    }

    func refresh(semester: String) async -> Bool {
        await AccountSession.school.withSignIn { await refresh(semester: semester, for: $0) }
    }

    private func refresh(semester: String, for signIn: SignIn) async -> Bool {
        guard !isRefreshing, let person = shownPerson,
              let term = person.terms.first(where: { $0.semester == semester }) else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let refreshed = await lookUpTerm(term.semester, term.courseNos, term.courses) else {
            showsLookupFailed = true
            return false
        }
        let change = store.updateCourses(
            person.id, semester: term.semester, courseNos: term.courseNos, courses: refreshed,
            importedAt: person.importedAt, for: signIn
        )
        if change == .failed { showsSaveFailed = true }
        return shownPerson?.id == person.id
    }
}
