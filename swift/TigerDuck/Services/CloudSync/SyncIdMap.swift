import Foundation
import os

/// Maps local identifiers (courseNo, moodleAssignmentId) to server-side
/// numeric IDs. Rebuilt on each full sync; used by the outbox to resolve
/// IDs before sending targeted PUT requests.
nonisolated struct SyncIdMap: Codable, Sendable {
    private var courses: [String: Int] = [:]     // "semester|courseKey" → serverId
    private var assignments: [String: Int] = [:] // "moodleCourseId:moodleAssignmentId" → serverId

    init() {}

    mutating func recordCourse(semester: String, courseKey: String, serverId: Int) {
        courses["\(semester)|\(courseKey)"] = serverId
    }

    mutating func recordAssignment(moodleCourseId: Int, moodleAssignmentId: Int, serverId: Int) {
        assignments["\(moodleCourseId):\(moodleAssignmentId)"] = serverId
    }

    func courseId(semester: String, courseKey: String) -> Int? {
        courses["\(semester)|\(courseKey)"]
    }

    func assignmentId(moodleCourseId: Int, moodleAssignmentId: Int) -> Int? {
        assignments["\(moodleCourseId):\(moodleAssignmentId)"]
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckCloudSync", isDirectory: true)
    }

    func save(to directory: URL = defaultDirectory()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(
            to: directory.appendingPathComponent("id_map.json"),
            options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func load(from directory: URL = defaultDirectory()) -> SyncIdMap {
        let url = directory.appendingPathComponent("id_map.json")
        guard let data = try? Data(contentsOf: url) else { return SyncIdMap() }
        guard let map = try? JSONDecoder().decode(SyncIdMap.self, from: data) else {
            Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.IdMap")
                .warning("id_map.json decode failed — rebuilding on next full sync")
            return SyncIdMap()
        }
        return map
    }

    static func clear(in directory: URL = defaultDirectory()) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("id_map.json"))
    }
}
