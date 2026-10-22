import Foundation

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

    private static let refreshTTL: TimeInterval = 3600

    private nonisolated static let pickerDepth = 6

    struct SemesterInfo: Decodable {
        let Semester: String
        let LoginEnable: Bool
    }

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

    nonisolated static func terms(from catalogue: [String], admissionYear: Int?) -> [String] {
        guard let admissionYear else { return Array(catalogue.prefix(pickerDepth)) }
        return catalogue.filter { (academicYear(of: $0) ?? -1) >= admissionYear }
    }

    nonisolated static func academicYear(of code: String) -> Int? {
        Int(code.dropLast().trimmingCharacters(in: .whitespaces))
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
        guard Date().timeIntervalSince1970 - last > refreshTTL else { return }
        await refresh()
    }

    static func refresh() async {
        guard let list = try? await fetch(), !list.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(list.map(\.Semester), forKey: listKey)
        defaults.set(Date().timeIntervalSince1970, forKey: refreshedAtKey)
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
            code = CourseSelectionService.previousSemesterCode(code)
        }
        return semesters
    }
}
