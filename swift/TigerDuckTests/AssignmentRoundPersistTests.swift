import Foundation
import Testing
@testable import TigerDuck

/// What an assignment round writes, into a cache in a folder of its own: all it fetched while the
/// account stays signed in and the round runs on, and nothing once either ends. Every id here is
/// made up.
@MainActor
struct AssignmentRoundPersistTests {
    private static let account = "B11399001"
    private static let due = Date(timeIntervalSince1970: 1_790_600_000)
    private static let record = MoodleAssignmentRecord(
        assignId: 701, cmId: 9701, courseId: 20119, name: "HW 2", dueDate: due, cutoffDate: nil,
        allowSubmissionsFromDate: nil, intro: "<p>Implement a list.</p>", noSubmissions: false, teamSubmission: true
    )

    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssignmentRoundPersistTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func persist(in cache: DataCache, isCurrent: () -> Bool) -> Bool {
        AppServiceBridge.persistRound(
            [SDAssignment(assignmentId: "701", courseNo: "CS3105301", courseName: "Data Structures", title: "HW 2", dueDate: due)],
            records: [record],
            closed: ["702": due],
            account: account,
            fetchedAt: due,
            cache: cache,
            isCurrent: isCurrent
        )
    }

    private static func records(in cache: DataCache) -> [MoodleAssignmentRecord]? {
        cache.loadMoodleData([MoodleAssignmentRecord].self, name: MoodleAssignmentRecord.cacheName, account: account)?.value
    }

    @Test("a round writes its assignments, their records for the account, the closed ones and the calendar's rows")
    func writes() {
        let folder = Folder()

        #expect(Self.persist(in: folder.cache, isCurrent: { true }))

        #expect(folder.cache.loadAssignments().map(\.assignmentId) == ["701"])
        #expect(Self.records(in: folder.cache) == [Self.record])
        #expect(folder.cache.loadClosedUnsubmittedAssignments() == ["702": Self.due])
        #expect(folder.cache.loadCalendarEvents().map(\.eventId) == ["moodle-701"])
    }

    @Test("a round the account signed out of while Moodle answered writes nothing")
    func signedOut() {
        let folder = Folder()

        #expect(!Self.persist(in: folder.cache, isCurrent: { false }))

        #expect(folder.cache.loadAssignments().isEmpty)
        #expect(Self.records(in: folder.cache) == nil)
        #expect(folder.cache.loadClosedUnsubmittedAssignments().isEmpty)
        #expect(folder.cache.loadCalendarEvents().isEmpty)
    }

    @Test("a cancelled round writes nothing")
    func cancelled() async {
        let folder = Folder()
        let cache = folder.cache
        let round = Task { @MainActor () -> Bool in
            try? await Task.sleep(for: .seconds(60))
            return Self.persist(in: cache, isCurrent: { true })
        }

        round.cancel()

        #expect(await round.value == false)
        #expect(cache.loadAssignments().isEmpty)
        #expect(Self.records(in: cache) == nil)
    }
}
