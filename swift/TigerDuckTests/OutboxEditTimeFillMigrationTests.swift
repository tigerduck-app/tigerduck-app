import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "OutboxEditTimeFillMigration.v1.done"

struct OutboxEditTimeFillMigrationTests {
    private static let queued = #"""
    [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964F5","attempts":1,"op":{"assignmentOverride":{"moodleCourseId":4242,"moodleAssignmentId":42,"localStatus":"ignored","stamp":811692800.5}}}]
    """#
    private static let parked = #"""
    [{"id":"7A9619FF-8B86-D011-B42D-00C04FC964F5","attempts":5,"op":{"courseAdd":{"semester":"1151","courseNo":"GE1010001","stamp":811692900.25}}}]
    """#

    @Test("Queued and parked entries an earlier build wrote get the time they were queued, by the wall clock, in the files")
    func entriesWrittenWithoutAnEditTimeGetOne() async throws {
        try await withExclusiveRealDefaults {
            let savedDone = UserDefaults.standard.object(forKey: doneKey)
            defer {
                if let savedDone {
                    UserDefaults.standard.set(savedDone, forKey: doneKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: doneKey)
                }
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OutboxEditTimeFillMigrationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(Self.queued.utf8).write(to: directory.appendingPathComponent(OutboxFiles.fileName))
            try Data(Self.parked.utf8).write(to: directory.appendingPathComponent(OutboxFiles.parkedFileName))

            OutboxEditTimeFillMigration.runIfNeeded(directory: directory)

            for (name, stamp) in [(OutboxFiles.fileName, 811692800.5), (OutboxFiles.parkedFileName, 811692900.25)] {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                #expect(entries.map { ($0["madeAt"] as? [String: Any])?["wall"] as? Double } == [stamp])
            }
            let outbox = SyncOutbox(directory: directory)
            #expect(await outbox.snapshot().map(\.madeAt) == [EditTime(wall: Date(timeIntervalSinceReferenceDate: 811692800.5))])
            #expect(await outbox.parkedSnapshot().map(\.attempts) == [5])
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }
}
