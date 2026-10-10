import Foundation
import os

enum CourseLookupService {
    private static let courseSearchAPI = URL.knownGood("https://querycourse.ntust.edu.tw/QueryCourse/api//courses")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        // querycourse.ntust.edu.tw is in the *.ntust.edu.tw pin scope —
        // course search bodies and responses ride the SSO trust chain,
        // so MITM defence here matches the rest of the NTUST surface.
        return URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
    }()

    /// A course's rows change only when the school edits the course, and every course fetch
    /// and class-table appearance looks each course up, so an answer is kept this long.
    static let lookupLifetime: TimeInterval = 30 * 60

    struct LookupKey: Hashable {
        let semester: String
        let courseNo: String
        let language: String
    }

    private static var lookups: [LookupKey: (at: Date, results: [CourseSearchResult])] = [:]

    /// `fresh` skips the kept answer; a class-table pull passes it.
    static func lookupCourse(
        semester: String,
        courseNo: String,
        language: String = "zh",
        fresh: Bool = false
    ) async throws -> [CourseSearchResult] {
        let key = LookupKey(semester: semester, courseNo: courseNo, language: language)
        return try await kept(key, now: Date(), fresh: fresh) {
            try await searchAPI(body: .forCourseNo(courseNo, semester: semester, language: language))
        }
    }

    static func kept(
        _ key: LookupKey,
        now: Date,
        fresh: Bool,
        search: () async throws -> [CourseSearchResult]
    ) async throws -> [CourseSearchResult] {
        if !fresh, let kept = lookups[key], now.timeIntervalSince(kept.at) < lookupLifetime {
            return kept.results
        }
        let results = try await search()
        lookups[key] = (now, results)
        return results
    }

    static func searchCourses(semester: String, courseName: String, language: String = "zh") async throws -> [CourseSearchResult] {
        try await searchAPI(body: .forCourseName(courseName, semester: semester, language: language))
    }

    static func searchByTeacher(semester: String, teacher: String, language: String = "zh") async throws -> [CourseSearchResult] {
        try await searchAPI(body: .forCourseTeacher(teacher, semester: semester, language: language))
    }

    private static func searchAPI(body: CourseSearchRequest) async throws -> [CourseSearchResult] {
        var request = URLRequest(url: courseSearchAPI)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode([CourseSearchResult].self, from: data)
    }

    nonisolated static func parseNodeToSchedule(_ node: String?) -> [Int: [String]] {
        guard let node, !node.isEmpty else { return [:] }

        // M-F = weekday 1..5; S/U = Sat/Sun; X is the legacy NTUST code for
        // Saturday makeup classes (predates the S/U pair). Other letters get
        // logged so unknown future codes don't silently disappear.
        let dayMap: [Character: Int] = [
            "M": 1, "T": 2, "W": 3, "R": 4, "F": 5,
            "S": 6, "U": 7, "X": 6
        ]
        var schedule: [Int: [String]] = [:]

        for item in node.split(separator: ",") {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { continue }
            guard let day = dayMap[first] else {
                AppLogger.network.warning("parseNodeToSchedule: unknown day code \(String(first), privacy: .public)")
                continue
            }
            let periodId = String(trimmed.dropFirst())
            guard !periodId.isEmpty else { continue }
            schedule[day, default: []].append(periodId)
        }

        return schedule
    }
}
