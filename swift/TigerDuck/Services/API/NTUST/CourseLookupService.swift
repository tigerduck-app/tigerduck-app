import Foundation
import os

enum CourseLookupService {
    private static let courseSearchAPI = URL.knownGood("https://querycourse.ntust.edu.tw/QueryCourse/api//courses")
    private static let optionsAPI = URL.knownGood("https://querycourse.ntust.edu.tw/QueryCourse/api/")

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

    static func searchCourses(semester: String, courseName: String, language: String = "zh") async throws -> [CourseSearchResult] {
        try await search(.forCourseName(courseName, semester: semester, language: language))
    }

    static func searchByTeacher(semester: String, teacher: String, language: String = "zh") async throws -> [CourseSearchResult] {
        try await search(.forCourseTeacher(teacher, semester: semester, language: language))
    }

    static func search(_ body: CourseSearchRequest) async throws -> [CourseSearchResult] {
        var request = URLRequest(url: courseSearchAPI)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode([CourseSearchResult].self, from: data)
    }

    // Capitalised to match the wire format, same as `CourseSearchResult`.
    // swiftlint:disable identifier_name
    private nonisolated struct CollegeRow: Decodable {
        let CollegeNo: String
        let CollegeName: String
        let CollegeEngName: String
    }

    private nonisolated struct DepartmentRow: Decodable {
        let DeptNo: String
        let Department: String
        let EngDepartment: String
    }

    private nonisolated struct DimensionRow: Decodable {
        let DimNo: String
        let DimContent: String
        let EngContent: String
    }
    // swiftlint:enable identifier_name

    /// The colleges with their departments, and the GE types. One failed list fails the whole fetch,
    /// so the device never stores half of them.
    static func fetchSearchOptions() async throws -> CourseSearchOptions {
        async let dimensionRows: [DimensionRow] = get("dimensions")
        let collegeRows: [CollegeRow] = try await get("Colleges/")
        let departmentRows = try await withThrowingTaskGroup(of: (Int, [DepartmentRow]).self) { group in
            for (index, college) in collegeRows.enumerated() {
                group.addTask { (index, try await get("departments", collegeNo: college.CollegeNo)) }
            }
            return try await group.reduce(into: [Int: [DepartmentRow]]()) { $0[$1.0] = $1.1 }
        }
        let colleges = collegeRows.enumerated().map { index, college in
            var seen = Set<String>()
            return CourseSearchOptions.College(
                name: college.CollegeName,
                englishName: college.CollegeEngName,
                departments: (departmentRows[index] ?? [])
                    .filter { seen.insert($0.DeptNo).inserted }
                    .map { .init(code: $0.DeptNo, name: $0.Department, englishName: $0.EngDepartment) }
            )
        }
        // The list opens with a "(0)" row that the school's own page swaps for "all".
        let dimensions = try await dimensionRows
            .filter { $0.DimNo != "0" }
            .map { CourseSearchOptions.Option(code: $0.DimNo, name: $0.DimContent, englishName: $0.EngContent) }
        return CourseSearchOptions(colleges: colleges, dimensions: dimensions)
    }

    private static func get<Row: Decodable>(_ path: String, collegeNo: String? = nil) async throws -> [Row] {
        var url = optionsAPI.appending(path: path)
        if let collegeNo {
            url.append(queryItems: [URLQueryItem(name: "collegeNo", value: collegeNo)])
        }
        let (data, _) = try await session.data(for: URLRequest(url: url))
        return try JSONDecoder().decode([Row].self, from: data)
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
