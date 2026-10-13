import Foundation
import Observation
import Vision

/// One import of a class table from a share code: the code the camera or an image gave, the
/// prompts it raises, the nickname, the course lookup and the person it saves. The scanner, the
/// Mac file importer and the confirm screen show it, and a test passes its own lookup.
/// See docs/decisions/0023-class-table-share-code.md.
@Observable
final class ClassTableImportModel: Identifiable {
    /// What a lookup imports: the code, and the nickname a new person is saved under.
    struct Job: Equatable {
        let code: ClassTableShareCode
        let nickname: String
    }

    /// The alert on screen. The two that start a lookup carry its job, so their buttons work
    /// whether SwiftUI clears the alert before or after it runs them.
    enum Prompt: Equatable {
        /// A wrong checksum, layout or course code, or a format version this app does not know.
        case invalid
        case noCode
        case ownCode
        /// The code's student ID is imported already; updating keeps that person's nickname.
        case replace(Job)
        case lookupFailed(Job)
    }

    /// The code the confirm screen shows.
    struct Pending: Identifiable {
        let id = UUID()
        let code: ClassTableShareCode
    }

    struct Row: Equatable {
        let title: String
        let value: String
    }

    /// One term's courses from NTUST's course query, without the codes it does not know; it
    /// throws when the query fails.
    typealias CourseLookup = (_ semester: String, _ courseNos: [String]) async throws -> [SDCourse]

    var prompt: Prompt?
    private(set) var pending: Pending?
    var nickname = ""
    private(set) var isLookingUp = false
    /// Set once the person is saved, or once the account signed out during the lookup; the
    /// screens close then.
    private(set) var isFinished = false
    @ObservationIgnored private(set) var lookupTask: Task<Void, Never>?

    private let store: ImportedClassTableStore
    private let signedInStudentId: () -> String?
    private let isCurrent: () -> Bool
    private let lookup: CourseLookup

    init(
        store: ImportedClassTableStore,
        signedInStudentId: @escaping () -> String?,
        isCurrent: @escaping () -> Bool,
        lookup: @escaping CourseLookup
    ) {
        self.store = store
        self.signedInStudentId = signedInStudentId
        self.isCurrent = isCurrent
        self.lookup = lookup
    }

    /// An import for the account signed in now, which saves nothing once it signs out, as it does
    /// before another student ID signs in.
    static func live(authService: AuthService) -> ClassTableImportModel {
        let generation = authService.loginGeneration
        return ClassTableImportModel(
            store: .shared,
            signedInStudentId: { authService.storedStudentId },
            isCurrent: { authService.loginGeneration == generation },
            lookup: { try await AppServiceBridge.importedCourses(semester: $0, courseNos: $1) }
        )
    }

    /// No alert, confirm screen or lookup is in the way of the next code.
    var isIdle: Bool { prompt == nil && pending == nil && !isLookingUp && !isFinished }

    var canImport: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLookingUp && !isFinished
    }

    // MARK: - Reading a code

    /// A QR code the camera read. Another app's code is passed over so scanning goes on, and so
    /// is any code while something else is on screen. Returns whether the code was taken.
    @discardableResult
    func scanned(_ text: String) -> Bool {
        guard isIdle else { return false }
        switch Self.reading(text) {
        case .notShareCode: return false
        case .invalid: prompt = .invalid
        case .code(let code): open(code)
        }
        return true
    }

    /// The QR codes found in a chosen image: its first share code, or a prompt when there is none.
    func imageRead(_ payloads: [String]) {
        guard isIdle else { return }
        let readings = payloads.map { Self.reading($0) }
        if let code = readings.lazy.compactMap(\.code).first {
            open(code)
        } else {
            prompt = readings.contains { $0.isInvalid } ? .invalid : .noCode
        }
    }

    /// An image's data from the photo picker; nil when it could not be loaded.
    func readImage(_ data: Data?) async {
        guard let data else {
            imageRead([])
            return
        }
        imageRead(await Task.detached { Self.qrPayloads(in: data) }.value)
    }

    /// An image file from the Mac's file importer.
    func readImage(fileAt url: URL) async {
        let data = await Task.detached { () -> Data? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                return try Data(contentsOf: url)
            } catch {
                AppLogger.captureError(error, context: ["phase": "classTableImport.readFile"])
                return nil
            }
        }.value
        await readImage(data)
    }

    /// The payloads of the QR codes Vision finds in image data.
    nonisolated static func qrPayloads(in data: Data) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        #if targetEnvironment(simulator)
        // The simulator cannot create the inference context the later revisions run in.
        request.revision = 1
        #endif
        do {
            try VNImageRequestHandler(data: data).perform([request])
        } catch {
            AppLogger.captureError(error, context: ["phase": "classTableImport.detectBarcodes"])
            return []
        }
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }

    private func open(_ code: ClassTableShareCode) {
        if let studentId = code.studentId {
            if studentId == signedInStudentId()?.uppercased() {
                prompt = .ownCode
                return
            }
            if let person = store.person(withStudentId: studentId) {
                prompt = .replace(Job(code: code, nickname: person.nickname))
                return
            }
        }
        nickname = code.studentId ?? ""
        pending = Pending(code: code)
    }

    // MARK: - Importing

    /// The confirm screen's Import.
    func importPending() {
        guard let pending, canImport else { return }
        lookUp(Job(code: pending.code, nickname: nickname))
    }

    /// Import on the confirm screen, Update on the replace prompt and Retry after a failure. Nothing
    /// is saved until every term's lookup has answered.
    func lookUp(_ job: Job) {
        guard !isLookingUp, !isFinished else { return }
        prompt = nil
        isLookingUp = true
        lookupTask = Task {
            let courses = await courses(for: job.code)
            guard !Task.isCancelled else { return }
            isLookingUp = false
            guard isCurrent() else {
                isFinished = true
                return
            }
            guard let courses else {
                prompt = .lookupFailed(job)
                return
            }
            guard let person = store.add(job.code, nickname: job.nickname, courses: courses) else { return }
            store.show(person.id)
            isFinished = true
        }
    }

    private func courses(for code: ClassTableShareCode) async -> [String: [SDCourse]]? {
        do {
            var courses: [String: [SDCourse]] = [:]
            for term in code.terms {
                courses[term.semester] = try await lookup(term.semester, term.courseNos)
            }
            return courses
        } catch {
            if !Task.isCancelled {
                AppLogger.captureError(error, context: ["phase": "classTableImport.lookup"])
            }
            return nil
        }
    }

    /// The alert one screen shows. While the confirm screen is up, its failed lookup alerts there:
    /// the scanner under it, or the Mac class table, cannot present over the sheet.
    func promptShown(onConfirmScreen: Bool) -> Prompt? {
        (pending != nil) == onConfirmScreen ? prompt : nil
    }

    /// An alert closed with Cancel or OK. A failed lookup's leaves the confirm screen as it was.
    func dismissPrompt() {
        prompt = nil
    }

    /// Closes the confirm screen and any alert and stops a running lookup, saving nothing.
    func cancel() {
        lookupTask?.cancel()
        lookupTask = nil
        isLookingUp = false
        pending = nil
        prompt = nil
    }

    // MARK: - Confirm screen

    /// In order: the student ID, the terms, the number of courses and the share time, which
    /// only our own format carries.
    static func rows(for code: ClassTableShareCode) -> [Row] {
        var rows: [Row] = []
        if let studentId = code.studentId {
            rows.append(Row(title: String(localized: "sign_in_student_id"), value: studentId))
        }
        rows.append(Row(
            title: String(localized: "class_table_semester_picker_label"),
            value: ListFormatter.localizedString(byJoining: code.terms.map { semesterLabel($0.semester) })
        ))
        rows.append(Row(
            title: String(localized: "class_table_import_course_count"),
            value: code.terms.reduce(0) { $0 + $1.courseNos.count }.formatted()
        ))
        if let sharedAt = code.sharedAt {
            rows.append(Row(
                title: String(localized: "class_table_import_shared_at"),
                value: sharedAt.formatted(date: .numeric, time: .shortened)
            ))
        }
        return rows
    }

    /// `1151` as `115-1`, as the semester picker shows it.
    private static func semesterLabel(_ semester: String) -> String {
        String(semester.dropLast()) + "-" + String(semester.suffix(1))
    }

    // MARK: - Decoding

    private enum Reading {
        case notShareCode
        case invalid
        case code(ClassTableShareCode)

        var code: ClassTableShareCode? {
            if case .code(let code) = self { code } else { nil }
        }

        var isInvalid: Bool {
            if case .invalid = self { true } else { false }
        }
    }

    private static func reading(_ text: String) -> Reading {
        do {
            return .code(try ClassTableShareCode.decode(text))
        } catch ClassTableShareCodeError.unknownPrefix {
            return .notShareCode
        } catch {
            AppLogger.breadcrumb("share code refused: \(error)", category: "classTableImport")
            return .invalid
        }
    }
}

extension ClassTableImportModel.Prompt {
    var title: String {
        switch self {
        case .invalid, .noCode, .ownCode:
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
        case .ownCode: String(localized: "class_table_import_own_code_message")
        case .replace: String(localized: "class_table_import_replace_message")
        case .lookupFailed: nil
        }
    }
}
