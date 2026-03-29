import Foundation

/// Persists network-fetched data to disk so it survives app restarts.
/// Uses JSON files in the app's caches directory.
final class DataCache {
    static let shared = DataCache()

    private let cacheDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDir = dir
    }

    // MARK: - Courses

    func saveCourses(_ courses: [SDCourse]) {
        let dtos = courses.map { CachedCourse(from: $0) }
        save(dtos, to: "courses.json")
    }

    func loadCourses() -> [SDCourse] {
        let dtos: [CachedCourse] = load(from: "courses.json") ?? []
        return dtos.map { $0.toSDCourse() }
    }

    // MARK: - Assignments

    func saveAssignments(_ assignments: [SDAssignment]) {
        let dtos = assignments.map { CachedAssignment(from: $0) }
        save(dtos, to: "assignments.json")
    }

    func loadAssignments() -> [SDAssignment] {
        let dtos: [CachedAssignment] = load(from: "assignments.json") ?? []
        return dtos.map { $0.toSDAssignment() }
    }

    // MARK: - Calendar Events

    func saveCalendarEvents(_ events: [SDCalendarEvent]) {
        let dtos = events.map { CachedCalendarEvent(from: $0) }
        save(dtos, to: "calendar_events.json")
    }

    func loadCalendarEvents() -> [SDCalendarEvent] {
        let dtos: [CachedCalendarEvent] = load(from: "calendar_events.json") ?? []
        return dtos.map { $0.toSDCalendarEvent() }
    }

    // MARK: - Private helpers

    private func save<T: Encodable>(_ value: T, to filename: String) {
        let url = cacheDir.appendingPathComponent(filename)
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load<T: Decodable>(from filename: String) -> T? {
        let url = cacheDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}

// MARK: - Codable DTOs

private struct CachedCourse: Codable {
    let courseNo: String
    let courseName: String
    let instructor: String
    let credits: Int
    let classroom: String
    let enrolledCount: Int
    let maxCount: Int
    let scheduleJSON: String
    let moodleIdNumber: String?
    let classroomMapJSON: String?

    init(from course: SDCourse) {
        courseNo = course.courseNo
        courseName = course.courseName
        instructor = course.instructor
        credits = course.credits
        classroom = course.classroom
        enrolledCount = course.enrolledCount
        maxCount = course.maxCount
        scheduleJSON = course.scheduleJSON
        moodleIdNumber = course.moodleIdNumber
        classroomMapJSON = course.classroomMapJSON
    }

    func toSDCourse() -> SDCourse {
        // Decode schedule from JSON to pass into init
        let schedule: [Int: [String]]
        if let data = scheduleJSON.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            schedule = Dictionary(uniqueKeysWithValues: dict.compactMap { key, value in
                guard let intKey = Int(key) else { return nil }
                return (intKey, value)
            })
        } else {
            schedule = [:]
        }

        let classroomMap: [String: String]
        if let json = classroomMapJSON,
           let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            classroomMap = dict
        } else {
            classroomMap = [:]
        }

        return SDCourse(
            courseNo: courseNo,
            courseName: courseName,
            instructor: instructor,
            credits: credits,
            classroom: classroom,
            enrolledCount: enrolledCount,
            maxCount: maxCount,
            schedule: schedule,
            moodleIdNumber: moodleIdNumber,
            classroomMap: classroomMap
        )
    }
}

private struct CachedAssignment: Codable {
    let assignmentId: String
    let courseNo: String
    let courseName: String
    let title: String
    let dueDate: Date
    let isCompleted: Bool
    let moodleUrl: String?

    init(from assignment: SDAssignment) {
        assignmentId = assignment.assignmentId
        courseNo = assignment.courseNo
        courseName = assignment.courseName
        title = assignment.title
        dueDate = assignment.dueDate
        isCompleted = assignment.isCompleted
        moodleUrl = assignment.moodleUrl
    }

    func toSDAssignment() -> SDAssignment {
        SDAssignment(
            assignmentId: assignmentId,
            courseNo: courseNo,
            courseName: courseName,
            title: title,
            dueDate: dueDate,
            isCompleted: isCompleted,
            moodleUrl: moodleUrl
        )
    }
}

private struct CachedCalendarEvent: Codable {
    let eventId: String
    let title: String
    let date: Date
    let sourceRaw: String

    init(from event: SDCalendarEvent) {
        eventId = event.eventId
        title = event.title
        date = event.date
        sourceRaw = event.sourceRaw
    }

    func toSDCalendarEvent() -> SDCalendarEvent {
        SDCalendarEvent(
            eventId: eventId,
            title: title,
            date: date,
            source: EventSource(rawValue: sourceRaw) ?? .school
        )
    }
}
