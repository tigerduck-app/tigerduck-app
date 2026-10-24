import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation

@Observable
final class ClassTableShareModel: Identifiable {
    struct Term {
        let semester: String
        let courses: [SDCourse]
    }

    enum Selection: Hashable {
        case allSemesters
        case semester(String)
    }

    let studentId: String
    let terms: [Term]

    var selection: Selection {
        didSet {
            if isTATCompatible, tatCode() == nil {
                isTATCompatible = false
            } else {
                rebuild()
            }
        }
    }

    var isTATCompatible = false {
        didSet {
            if isTATCompatible, tatCode() == nil { isTATCompatible = false }
            rebuild()
        }
    }

    private(set) var offersTAT = false
    private(set) var code: String?
    private(set) var qrCode: CGImage?

    private let semesterLabel: (String) -> String
    private let now: () -> Date

    init(
        studentId: String,
        terms: [Term],
        semesterLabel: @escaping (String) -> String,
        now: @escaping () -> Date = Date.init
    ) {
        self.studentId = studentId.uppercased()
        self.terms = terms
        self.semesterLabel = semesterLabel
        self.now = now
        selection = terms.first.map { .semester($0.semester) } ?? .allSemesters
        rebuild()
    }

    var options: [Selection] {
        [.allSemesters] + terms.map { .semester($0.semester) }
    }

    func label(for selection: Selection) -> String {
        switch selection {
        case .allSemesters: String(localized: "class_table_share_all_semesters")
        case .semester(let semester): semesterLabel(semester)
        }
    }

    var caption: String {
        "\(studentId) · \(label(for: selection))"
    }

    /// `code` to paste as a link. The upper case that keeps the QR code small reads oddly in a
    /// scheme and host, and a pasted link would end at the spaces TAT pads a student ID with.
    var link: String? {
        guard let code else { return nil }
        let address = code.dropFirst("HTTPS://".count)
        let host = address.prefix { $0 != "/" }
        let path = address.dropFirst(host.count)
        return "https://" + host.lowercased() + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(path))
    }

    private func rebuild() {
        let tat = tatCode()
        offersTAT = tat != nil
        code = isTATCompatible ? tat : ourCode()
        qrCode = code.flatMap { ClassTableShareQRCode.image(for: $0) }
        if qrCode == nil {
            AppLogger.captureError(
                code == nil ? ClassTableShareError.noCode : .noQRCode,
                context: ["phase": "classTableShare.rebuild", "terms": String(terms.count), "tat": String(isTATCompatible)]
            )
        }
    }

    private func ourCode() -> String? {
        let shared = switch selection {
        case .allSemesters: terms
        case .semester(let semester): terms.filter { $0.semester == semester }
        }
        return ClassTableShareCode.encode(
            studentId: studentId,
            sharedAt: now(),
            terms: shared.map { ClassTableShareCode.Term(semester: $0.semester, courseNos: $0.courses.map(\.courseNo)) }
        )
    }

    private func tatCode() -> String? {
        guard case .semester(let semester) = selection,
              let term = terms.first(where: { $0.semester == semester }) else { return nil }
        return ClassTableShareCode.encodeTAT(studentId: studentId, semester: semester, courses: term.courses)
    }
}

extension ClassTableShareModel {
    static func terms(in semesters: [String], cache: DataCache = .shared, shownTerm: Term? = nil) -> [Term] {
        let hidden = Set(cache.loadDeletedCourseNos())
        return semesters.compactMap { semester in
            let courses = courses(
                in: semester, hidden: hidden, cache: cache,
                shownTerm: shownTerm?.semester == semester ? shownTerm : nil
            )
            return courses.isEmpty ? nil : Term(semester: semester, courses: courses)
        }
    }

    static func canShare(
        studentId: String?,
        shownTerm: Term,
        semesters: [String],
        cache: DataCache = .shared
    ) -> Bool {
        guard let studentId, ClassTableShareCode.isUpperAlphanumerics(studentId.uppercased()[...]) else { return false }
        let hidden = Set(cache.loadDeletedCourseNos())
        return semesters.contains { semester in
            !courses(
                in: semester, hidden: hidden, cache: cache,
                shownTerm: shownTerm.semester == semester ? shownTerm : nil
            ).isEmpty
        }
    }

    struct Availability: Equatable {
        let studentId: String?
        let semester: String
        let courseNos: [String]
        let semesters: [String]
        let cacheRevision: Int
    }

    typealias AvailabilityMemo = ViewMemo<Availability, Bool>

    static func canShare(
        studentId: String?,
        shownTerm: Term,
        semesters: [String],
        cache: DataCache = .shared,
        memo: AvailabilityMemo
    ) -> Bool {
        let key = Availability(
            studentId: studentId, semester: shownTerm.semester, courseNos: shownTerm.courses.map(\.courseNo),
            semesters: semesters, cacheRevision: cache.revision
        )
        return memo.value(for: key) {
            canShare(studentId: studentId, shownTerm: shownTerm, semesters: semesters, cache: cache)
        }
    }

    private static func courses(
        in semester: String, hidden: Set<String>, cache: DataCache, shownTerm: Term?
    ) -> [SDCourse] {
        guard ClassTableShareCode.isSemester(semester.uppercased()[...]) else { return [] }
        if let shownTerm {
            return shownTerm.courses.filter {
                carriesCode($0) && !CourseTombstone.isHidden($0.courseNo, semester: semester, in: hidden)
            }
        }
        return CanonicalCourseProvider.merge(
            primary: cache.loadCourses(semester: semester),
            userAdded: cache.loadUserAddedCourses(semester: semester),
            semester: semester,
            deletedCourseNos: hidden,
            customNames: [:]
        ).filter(carriesCode)
    }

    private static func carriesCode(_ course: SDCourse) -> Bool {
        CourseSelectionService.isCourseNo(course.courseNo.uppercased()[...])
    }
}

nonisolated enum ClassTableShareError: Error {
    case noCode
    case noQRCode
}

/// QR codes of share codes, at error correction level M. Both formats are in upper case, which
/// Core Image writes in alphanumeric mode, the smallest symbol for them.
enum ClassTableShareQRCode {
    /// Core Image leaves one module of light margin, and the QR code standard asks for four.
    private static let extraMargin: CGFloat = 3
    private static let context = CIContext()

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let symbol = filter.outputImage else { return nil }
        let bounds = symbol.extent.insetBy(dx: -extraMargin, dy: -extraMargin)
        return context.createCGImage(symbol.composited(over: CIImage(color: .white).cropped(to: bounds)), from: bounds)
    }
}
