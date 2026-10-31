import Foundation
import TigerDuckCore

/// Server-driven semester list from the public `querycourse` catalogue. The month heuristic
/// in `CourseSelectionService` lags when NTUST opens a term early. A walk-back from it then
/// leaves the new term out of the picker, and course selection, which has already moved to
/// that term and marks no term in its list HTML, gets its enrolments filed under the old one,
/// rendering both terms into one grid.
///
/// `api/semestersinfo` also feeds the official course-query site's semester menu. Its
/// `LoginEnable` marks the one term course selection serves, which the list scrape lacks.
enum SemesterCatalog {
    private static let semestersAPI = URL.knownGood(
        "https://querycourse.ntust.edu.tw/QueryCourse/api/semestersinfo"
    )

    static let session = URLSession(
        configuration: .ephemeral,
        delegate: TLSPinningDelegate.shared,
        delegateQueue: nil
    )

    private nonisolated static let listKey = "semesterCatalog.semesters"
    private nonisolated static let selectionKey = "semesterCatalog.selectionSemester"
    private static let refreshedAtKey = "semesterCatalog.refreshedAt"

    private static let freshness = FreshnessPolicy(lifetime: 3600)

    private nonisolated static let pickerDepth = 6

    // Capitalised to match the wire format, same as `CourseSearchResult`.
    // swiftlint:disable identifier_name
    struct SemesterInfo: Decodable {
        let Semester: String
        let LoginEnable: Bool
    }
    // swiftlint:enable identifier_name

    static func decodeSemesters(_ data: Data) throws -> [SemesterInfo] {
        try JSONDecoder().decode([SemesterInfo].self, from: data)
    }

    static func openTerm(in list: [SemesterInfo]) -> String? {
        list.first(where: \.LoginEnable)?.Semester
    }

    nonisolated static func availableSemesters() -> [String] {
        let cached = UserDefaults.standard.stringArray(forKey: listKey) ?? []
        guard !cached.isEmpty else { return heuristicSemesters() }
        let studentId = KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
        return terms(from: cached, admissionYear: admissionYear(studentId: studentId))
    }

    /// Catalogue terms from the admission year onwards; the fixed depth when the id is
    /// unknown. Compared numerically: the catalogue pads pre-100 years as `99 1`, which
    /// sorts after `1131` as a string and would let every term back to 95-1 into the picker.
    ///
    /// Empty for a student admitted after the newest published term: every catalogue term
    /// predates them, so offering (and warming) any of it is wrong.
    /// `ClassTableViewModel.semesterOptions` keeps the heuristic term selectable until
    /// NTUST publishes theirs.
    nonisolated static func terms(from catalogue: [String], admissionYear: Int?) -> [String] {
        guard let admissionYear else { return Array(catalogue.prefix(pickerDepth)) }
        return catalogue.filter { (AcademicTerm.year(of: $0) ?? -1) >= admissionYear }
    }

    nonisolated static func admissionYear(studentId: String?) -> Int? {
        guard let studentId, studentId.count >= 4 else { return nil }
        return Int(studentId.dropFirst().prefix(3))
    }

    nonisolated static func selectedSemester(storedPick: String?) -> String {
        storedPick
            ?? availableSemesters().first
            ?? CourseSelectionService.currentSemesterCode()
    }

    nonisolated static func selectionSemesterCode() -> String {
        UserDefaults.standard.string(forKey: selectionKey)
            ?? CourseSelectionService.currentSemesterCode()
    }

    static func refreshIfStale() async {
        let last = UserDefaults.standard.double(forKey: refreshedAtKey)
        guard !freshness.isFresh(storedAt: Date(timeIntervalSince1970: last)) else { return }
        await refresh()
    }

    static func refresh() async {
        guard let list = try? await fetch(), !list.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(list.map(\.Semester), forKey: listKey)
        defaults.set(Date().timeIntervalSince1970, forKey: refreshedAtKey)
        // Exactly one entry carries LoginEnable. If NTUST ever ships zero,
        // keep the previous value rather than falling back to the heuristic
        // that caused this bug in the first place.
        if let selection = openTerm(in: list) {
            defaults.set(selection, forKey: selectionKey)
        }
    }

    private static func fetch() async throws -> [SemesterInfo] {
        var request = URLRequest(url: semestersAPI, timeoutInterval: 15)
        request.httpMethod = "GET"
        let (data, _) = try await session.data(for: request)
        return try decodeSemesters(data)
    }

    nonisolated private static func heuristicSemesters() -> [String] {
        var semesters: [String] = []
        var code = CourseSelectionService.currentSemesterCode()
        for _ in 0..<4 {
            semesters.append(code)
            code = AcademicTerm.previousRegularCode(code)
        }
        return semesters
    }
}
