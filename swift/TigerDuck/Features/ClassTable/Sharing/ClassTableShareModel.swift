import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation

/// The share sheet's state: the code for the term the user picks, or for every term, in our format
/// or TAT's, its QR code, and the caption that says whose code it is and what it holds.
/// See docs/decisions/0023-class-table-share-code.md.
@Observable
final class ClassTableShareModel: Identifiable {
    /// One of the user's terms and the courses its code is made from.
    struct Term {
        let semester: String
        let courses: [SDCourse]
    }

    enum Selection: Hashable {
        case allSemesters
        case semester(String)
    }

    let studentId: String
    /// Newest first, each with a course to share.
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
        didSet { rebuild() }
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
    /// The user's own courses of each of `semesters` that has any, in that order: what the class
    /// table shows, without the courses hidden there. Names and colours never reach a code.
    static func terms(in semesters: [String], cache: DataCache = .shared) -> [Term] {
        let hidden = Set(cache.loadDeletedCourseNos())
        return semesters.compactMap { semester in
            let courses = CanonicalCourseProvider.merge(
                primary: cache.loadCourses(semester: semester),
                // Added by hand from the course search, so they carry a real NTUST course code.
                userAdded: cache.loadUserAddedCourses(semester: semester),
                semester: semester,
                deletedCourseNos: hidden,
                customNames: [:]
            ).filter { ClassTableShareCode.isCourseNo($0.courseNo.uppercased()[...]) }
            return courses.isEmpty ? nil : Term(semester: semester, courses: courses)
        }
    }

    /// Whether the class table offers the sheet: someone is signed in and a term has a course to
    /// share. `shownCourses`, the term on screen, answers without reading the caches.
    static func canShare(
        studentId: String?,
        shownCourses: [SDCourse],
        semesters: [String],
        cache: DataCache = .shared
    ) -> Bool {
        guard studentId != nil else { return false }
        return !shownCourses.isEmpty || semesters.contains { !terms(in: [$0], cache: cache).isEmpty }
    }
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
