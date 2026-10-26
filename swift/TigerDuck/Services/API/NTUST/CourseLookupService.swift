import Foundation
import os

enum CourseLookupService {
    private static let courseSearchAPI = URL.knownGood("https://querycourse.ntust.edu.tw/QueryCourse/api//courses")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
    }()

    static let lookupLifetime: TimeInterval = 30 * 60

    struct LookupKey: Hashable {
        let semester: String
        let courseNo: String
        let language: String
    }

    private static var lookups: [LookupKey: (at: Date, results: [CourseSearchResult])] = [:]

    static func lookupCourse(
        semester: String,
        courseNo: String,
        language: String = "zh",
        fresh: Bool = false
    ) async throws -> [CourseSearchResult] {
        let key = LookupKey(semester: semester, courseNo: courseNo, language: language)
        return try await kept(key, now: Date(), fresh: fresh) {
            try await search(.forCourseNo(courseNo, semester: semester, language: language))
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

    private static let syllabusAPI = URL.knownGood("https://querycourse.ntust.edu.tw/querycourse/api/coursedetials")

    private static var syllabi: [LookupKey: Task<CourseSyllabus?, any Error>] = [:]

    /// The course's syllabus, nil when the school has none. Kept for the app's run, since a
    /// syllabus rarely changes within a term, and shared by callers while it loads; a failure is
    /// not kept.
    static func syllabus(semester: String, courseNo: String, language: String) async throws -> CourseSyllabus? {
        let key = LookupKey(semester: semester, courseNo: courseNo, language: language)
        return try await keptSyllabus(key) {
            let url = syllabusAPI.appending(queryItems: [
                URLQueryItem(name: "semester", value: semester),
                URLQueryItem(name: "course_no", value: courseNo),
                URLQueryItem(name: "language", value: language),
            ])
            let (data, _) = try await session.data(from: url)
            return try decodeSyllabus(data)
        }
    }

    static func keptSyllabus(
        _ key: LookupKey,
        fetch: @escaping () async throws -> CourseSyllabus?
    ) async throws -> CourseSyllabus? {
        if let kept = syllabi[key] { return try await kept.value }
        let task = Task { try await fetch() }
        syllabi[key] = task
        do {
            return try await task.value
        } catch {
            if syllabi[key] == task { syllabi[key] = nil }
            throw error
        }
    }

    /// The first syllabus of the array the service answers. For a course it has no row for, it
    /// answers with the .NET exception for reading row 0 instead, which means no syllabus.
    nonisolated static func decodeSyllabus(_ data: Data) throws -> CourseSyllabus? {
        do {
            return try JSONDecoder().decode([CourseSyllabus].self, from: data).first
        } catch {
            let exception = try? JSONDecoder().decode(ServiceException.self, from: data)
            guard exception?.ClassName == "System.IndexOutOfRangeException" else { throw error }
            return nil
        }
    }

    private nonisolated struct ServiceException: Decodable {
        let ClassName: String
    }

    static func search(_ body: CourseSearchRequest) async throws -> [CourseSearchResult] {
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
