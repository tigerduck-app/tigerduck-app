import Foundation
import Observation
import TigerDuckCore

@Observable
final class ClassTableImportModel: Identifiable {
    struct Job: Equatable {
        let code: ClassTableShareCode
        let nickname: String
        /// When the person an update is for was imported; deleted or imported anew meanwhile,
        /// the update is dropped.
        var updatesImport: Date? = nil
    }

    /// The alerts that start a lookup carry its job, so their buttons work
    /// whether SwiftUI clears the alert before or after it runs them.
    enum Prompt: Equatable {
        case invalid
        case noCode
        /// A code a newer app wrote: a format version or a share type this one does not know.
        case needsUpdate
        case ownCode
        case replace(Job)
        case lookupFailed(Job)
        case saveFailed(Job)
    }

    struct Pending: Identifiable {
        let id = UUID()
        let code: ClassTableShareCode
    }

    typealias CourseLookup = (_ semester: String, _ courseNos: [String]) async throws -> [CourseStore.Course]

    var prompt: Prompt?
    private(set) var pending: Pending?
    var nickname = ""
    private(set) var isLookingUp = false
    private(set) var isReadingImage = false
    private(set) var isFinished = false
    @ObservationIgnored private(set) var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    private(set) var linkTask: Task<Void, Never>?

    private let account: Account

    private struct Account {
        let store: ImportedClassTableStore
        let signedInStudentId: () -> String?
        let signIn: SignIn
        let lookup: CourseLookup
    }

    init(
        store: ImportedClassTableStore,
        signedInStudentId: @escaping () -> String?,
        signIn: SignIn,
        lookup: @escaping CourseLookup
    ) {
        account = Account(store: store, signedInStudentId: signedInStudentId, signIn: signIn, lookup: lookup)
    }

    static func live(authService: AuthService) -> ClassTableImportModel {
        ClassTableImportModel(
            store: .shared,
            signedInStudentId: { authService.storedStudentId },
            signIn: authService.session.currentSignIn,
            lookup: { try await SchoolRefresh.importedCourses(semester: $0, courseNos: $1) }
        )
    }

    var isIdle: Bool {
        prompt == nil && pending == nil && linkTask == nil && !isLookingUp && !isReadingImage && !isFinished
    }

    /// An update of a person imported already, whose lookup has no confirm screen to show on.
    var isUpdating: Bool { isLookingUp && pending == nil }

    var canImport: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLookingUp && !isFinished
    }

    @discardableResult
    func scanned(_ text: String) -> Bool {
        guard isIdle else { return false }
        switch ShareCodeReading(text) {
        case .notShareCode: return false
        case .invalid: prompt = .invalid
        case .needsUpdate: prompt = .needsUpdate
        case .code(let code): open(code)
        }
        return true
    }

    /// The code a link opened, in place of anything this import shows, so a newer link replaces
    /// an older one. A link the decoder does not take says the code is damaged: no camera is
    /// there to try another code with.
    func linkOpened(_ text: String) {
        guard !isFinished else { return }
        let closesAlert = prompt != nil || linkTask != nil
        cancel()
        guard closesAlert else {
            read(link: text)
            return
        }
        // An alert replaced in one update stays up with the old job's buttons, so it closes first.
        linkTask = Task {
            try? await AppClock.sleep(until: ContinuousClock.now + .milliseconds(50))
            guard !Task.isCancelled else { return }
            linkTask = nil
            read(link: text)
        }
    }

    private func read(link text: String) {
        if !scanned(text) { prompt = .invalid }
    }

    func imageRead(_ payloads: [String]) {
        guard isIdle else { return }
        let readings = payloads.map { ShareCodeReading($0) }
        if let code = readings.lazy.compactMap(\.code).first {
            open(code)
        } else if readings.contains(.needsUpdate) {
            // The app can read a newer code once updated, so that comes before a damaged one.
            prompt = .needsUpdate
        } else {
            prompt = readings.contains(.invalid) ? .invalid : .noCode
        }
    }

    @discardableResult
    func readImage(load: @escaping () async -> Data?) -> Task<Void, Never>? {
        guard isIdle else { return nil }
        isReadingImage = true
        let task = Task {
            let data = await load()
            guard !Task.isCancelled else { return }
            let payloads: [String]
            if let data {
                payloads = await Task.detached { ShareCodeReading.qrPayloads(in: data) }.value
            } else {
                payloads = []
            }
            guard !Task.isCancelled else { return }
            isReadingImage = false
            imageTask = nil
            guard account.signIn.isCurrent else {
                isFinished = true
                return
            }
            imageRead(payloads)
        }
        imageTask = task
        return task
    }

    func readImage(_ data: Data?) async {
        await readImage(load: { data })?.value
    }

    func readImage(fileAt url: URL) async {
        await readImage(load: {
            await ShareCodeReading.data(fileAt: url)
        })?.value
    }

    private func open(_ code: ClassTableShareCode) {
        if let studentId = code.studentId {
            if studentId == account.signedInStudentId()?.uppercased() {
                prompt = .ownCode
                return
            }
            if let person = account.store.person(withStudentId: studentId) {
                prompt = .replace(Job(code: code, nickname: person.nickname, updatesImport: person.importedAt))
                return
            }
        }
        nickname = code.studentId ?? ""
        pending = Pending(code: code)
    }

    func importPending() {
        guard let pending, canImport else { return }
        lookUp(Job(code: pending.code, nickname: nickname))
    }

    func lookUp(_ job: Job) {
        guard !isLookingUp, !isFinished else { return }
        prompt = nil
        isLookingUp = true
        lookupTask = Task {
            let courses = await courses(for: job.code)
            guard !Task.isCancelled else { return }
            isLookingUp = false
            guard account.signIn.isCurrent else {
                isFinished = true
                return
            }
            guard let courses else {
                prompt = .lookupFailed(job)
                return
            }
            var nickname = job.nickname
            if let importedAt = job.updatesImport {
                guard let current = account.store.person(withStudentId: job.code.studentId ?? ""),
                      current.importedAt == importedAt else {
                    isFinished = true
                    return
                }
                nickname = current.nickname
            }
            guard let person = account.store.add(job.code, nickname: nickname, courses: courses, for: account.signIn) else {
                prompt = .saveFailed(job)
                return
            }
            account.store.show(person.id)
            isFinished = true
        }
    }

    private func courses(for code: ClassTableShareCode) async -> [String: [CourseStore.Course]]? {
        do {
            var courses: [String: [CourseStore.Course]] = [:]
            for term in code.terms {
                courses[term.semester] = try await account.lookup(term.semester, term.courseNos)
            }
            return courses
        } catch {
            if !Task.isCancelled {
                AppLogger.captureError(error, context: ["phase": "classTableImport.lookup"])
            }
            return nil
        }
    }

    func promptShown(onConfirmScreen: Bool) -> Prompt? {
        (pending != nil) == onConfirmScreen ? prompt : nil
    }

    func dismissPrompt() {
        prompt = nil
    }

    func cancel() {
        linkTask?.cancel()
        linkTask = nil
        imageTask?.cancel()
        imageTask = nil
        isReadingImage = false
        lookupTask?.cancel()
        lookupTask = nil
        isLookingUp = false
        pending = nil
        prompt = nil
    }


}

extension ClassTableImportModel.Prompt {
    var title: String {
        switch self {
        case .invalid, .noCode, .needsUpdate, .ownCode, .saveFailed:
            String(localized: "class_table_import_failed")
        case .replace(let job):
            String(format: String(localized: "class_table_import_replace_title"), job.nickname)
        case .lookupFailed:
            String(localized: "class_table_import_lookup_failed")
        }
    }

    var message: String? {
        switch self {
        case .invalid: String(localized: "class_table_import_invalid_message")
        case .noCode: String(localized: "class_table_import_no_code_message")
        case .needsUpdate: String(localized: "share_code_needs_update_message")
        case .ownCode: String(localized: "class_table_import_own_code_message")
        case .replace: String(localized: "class_table_import_replace_message")
        case .lookupFailed, .saveFailed: nil
        }
    }
}
