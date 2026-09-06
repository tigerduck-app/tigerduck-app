import Foundation

/// Server-driven semester list, sourced from the public `querycourse`
/// catalogue.
///
/// `CourseSelectionService.currentSemesterCode()` is a gregorian-month
/// heuristic, so it lags whenever NTUST publishes a term early. On
/// 2026-08-20 the heuristic still said 114-2 while the school had already
/// opened 115-1, which broke the class table two ways:
///
/// 1. `availableSemesters` walked back four terms from the heuristic, so
///    115-1 never appeared in the picker.
/// 2. The 選課 system had *already* flipped to 115-1, and its 選課清單 page
///    carries no term marker anywhere in the HTML — so those enrolments were
///    filed under the heuristic's 114-2 and both terms rendered into one grid.
///
/// `api/semestersinfo` is the same endpoint the official course-query site
/// uses to populate its own semester menu. `LoginEnable` marks the single
/// term the 選課 system is operating on, which is exactly the attribution the
/// 選課清單 scrape is missing.
enum SemesterCatalog {
    private static let semestersAPI = URL.knownGood(
        "https://querycourse.ntust.edu.tw/QueryCourse/api/semestersinfo"
    )

    private nonisolated static let listKey = "semesterCatalog.semesters"
    private nonisolated static let selectionKey = "semesterCatalog.selectionSemester"
    private static let refreshedAtKey = "semesterCatalog.refreshedAt"

    /// Term boundaries move on the scale of weeks, so this only has to beat
    /// the month heuristic — hourly is plenty, and it keeps the fetch off the
    /// hot path when several semesters warm at once.
    private static let refreshTTL: TimeInterval = 3600

    /// Picker depth when the student id is unknown. Six rather than the
    /// previous four because the catalogue interleaves 暑期 terms (`114H`)
    /// between the regular ones. With a known id the picker instead reaches
    /// back to the admission term — see `terms(from:admissionYear:)`.
    private nonisolated static let pickerDepth = 6

    // Capitalised to match the wire format, same as `CourseSearchResult`.
    // swiftlint:disable identifier_name
    struct SemesterInfo: Decodable {
        let Semester: String
        let LoginEnable: Bool
    }
    // swiftlint:enable identifier_name

    /// Split out from `fetch()` so the two things that actually matter about
    /// the payload — its shape, and that the open term is picked by
    /// `LoginEnable` rather than by position — are testable offline.
    static func decodeSemesters(_ data: Data) throws -> [SemesterInfo] {
        try JSONDecoder().decode([SemesterInfo].self, from: data)
    }

    static func openTerm(in list: [SemesterInfo]) -> String? {
        list.first(where: \.LoginEnable)?.Semester
    }

    /// Terms the picker offers, newest first: every catalogue term back to
    /// the student's first one. A fixed depth of six stopped at 113-2 for a
    /// student admitted in 113 once 114H and 113H took two of the slots.
    /// Falls back to walking back from the month heuristic until the first
    /// successful `refresh()`.
    nonisolated static func availableSemesters() -> [String] {
        let cached = UserDefaults.standard.stringArray(forKey: listKey) ?? []
        guard !cached.isEmpty else { return heuristicSemesters() }
        let studentId = KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
        return terms(from: cached, admissionYear: admissionYear(studentId: studentId))
    }

    /// Catalogue terms from the fall of the admission year onwards; the
    /// fixed depth when the id is unknown. Codes are `YYYS` with S in
    /// 1 / 2 / H, so plain string order is chronological within a year
    /// (`113H` sorts after `1131`).
    nonisolated static func terms(from catalogue: [String], admissionYear: Int?) -> [String] {
        guard let admissionYear else { return Array(catalogue.prefix(pickerDepth)) }
        let firstTerm = "\(admissionYear)1"
        return catalogue.filter { $0 >= firstTerm }
    }

    /// NTUST ids are one degree letter plus the three-digit admission year
    /// (`B113…` → 113).
    nonisolated static func admissionYear(studentId: String?) -> Int? {
        guard let studentId, studentId.count >= 4 else { return nil }
        return Int(studentId.dropFirst().prefix(3))
    }

    /// The term the picker should open on: the user's last pick, or the newest
    /// published term when they have never picked one.
    ///
    /// The stored pick is passed in rather than read here so the rule stays
    /// testable, and callers deliberately do *not* persist the fallback — an
    /// untouched picker should keep tracking the newest term rather than
    /// freezing on whichever one happened to be newest at first launch.
    nonisolated static func selectedSemester(storedPick: String?) -> String {
        storedPick
            ?? availableSemesters().first
            ?? CourseSelectionService.currentSemesterCode()
    }

    /// The term the 選課 system is currently serving — the one whose
    /// enrolments `CourseSelectionService.fetchEnrolledCourseNos` returns.
    ///
    /// This runs *ahead* of the term actually in session (選課 for the next
    /// term opens weeks before it starts), so it is deliberately not a
    /// replacement for `currentSemesterCode()`; it answers "which bucket do
    /// the 選課清單 course numbers belong in", nothing else.
    nonisolated static func selectionSemesterCode() -> String {
        UserDefaults.standard.string(forKey: selectionKey)
            ?? CourseSelectionService.currentSemesterCode()
    }

    /// Refreshes both cached values when the last successful fetch has aged
    /// out. Safe to call from every course-fetch entry point.
    static func refreshIfStale() async {
        let last = UserDefaults.standard.double(forKey: refreshedAtKey)
        guard Date().timeIntervalSince1970 - last > refreshTTL else { return }
        await refresh()
    }

    /// Refreshes both cached values. Failures are swallowed — every caller
    /// degrades to the month heuristic, which is the pre-existing behaviour.
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
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decodeSemesters(data)
    }

    /// Pre-refresh fallback: the walk-back that `ClassTableViewModel`,
    /// `MacClassTableView` and `AppServiceBridge` each used to reimplement.
    nonisolated private static func heuristicSemesters() -> [String] {
        var semesters: [String] = []
        var code = CourseSelectionService.currentSemesterCode()
        for _ in 0..<4 {
            semesters.append(code)
            code = CourseSelectionService.previousSemesterCode(code)
        }
        return semesters
    }
}
