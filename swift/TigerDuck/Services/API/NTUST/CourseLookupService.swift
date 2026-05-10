import Foundation
import os

enum CourseLookupService {
    private static let courseSearchAPI = URL.knownGood("https://querycourse.ntust.edu.tw/QueryCourse/api//courses")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func lookupCourse(semester: String, courseNo: String, language: String = "zh") async throws -> [CourseSearchResult] {
        try await searchAPI(body: .forCourseNo(courseNo, semester: semester, language: language))
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
