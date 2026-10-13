import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation

/// Share codes exclude names and display preferences; see docs/decisions/0023-class-table-share-code.md.
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
            // TAT's code holds one term, so all semesters turns the switch off, as does a term
            // whose course codes TAT cannot carry.
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
    /// One pixel per module, for the sheet to scale up without smoothing.
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
    /// A refreshed displayed term can be newer than disk, including an empty roster.
    /// Other terms still use cached data so sharing does not require another network request.
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

    private static func courses(
        in semester: String, hidden: Set<String>, cache: DataCache, shownTerm: Term?
    ) -> [SDCourse] {
        guard ClassTableShareCode.isSemester(semester.uppercased()[...]) else { return [] }
        if let shownTerm {
            // The grid shares these reference objects; a canonical merge would rewrite their aliases.
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

    /// A share code carries only course codes of NTUST's shape, the ones the importer can look up.
    private static func carriesCode(_ course: SDCourse) -> Bool {
        ClassTableShareCode.isCourseNo(course.courseNo.uppercased()[...])
    }
}

/// A valid share code can exceed a QR symbol's capacity.
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
