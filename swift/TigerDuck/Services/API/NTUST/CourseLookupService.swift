import Foundation

enum CourseLookupService {
    private static let courseSearchAPI = URL(string: "https://querycourse.ntust.edu.tw/QueryCourse/api//courses")!

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

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([CourseSearchResult].self, from: data)
    }

    nonisolated static func parseNodeToSchedule(_ node: String?) -> [Int: [String]] {
        guard let node, !node.isEmpty else { return [:] }

        let dayMap: [Character: Int] = ["M": 1, "T": 2, "W": 3, "R": 4, "F": 5, "S": 6, "U": 7]
        var schedule: [Int: [String]] = [:]

        for item in node.split(separator: ",") {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, let day = dayMap[first] else { continue }
            let periodId = String(trimmed.dropFirst())
            guard !periodId.isEmpty else { continue }
            schedule[day, default: []].append(periodId)
        }

        return schedule
    }
}
