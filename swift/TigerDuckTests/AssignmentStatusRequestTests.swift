import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct AssignmentStatusRequestTests {
    private nonisolated static let lastRound = Date(timeIntervalSince1970: 1_790_000_000)

    private static func record(_ id: Int, cutoff: Date?, due: Date? = lastRound) -> MoodleAssignmentRecord {
        MoodleAssignmentRecord(
            assignId: id, cmId: id, courseId: 1, name: "HW\(id)", dueDate: due, cutoffDate: cutoff,
            allowSubmissionsFromDate: nil, intro: "", noSubmissions: false
        )
    }

    private static func cached(_ id: Int, completed: Bool = false) -> SDAssignment {
        SDAssignment(
            assignmentId: String(id), courseNo: "CS1001301", courseName: "Course", title: "HW\(id)",
            dueDate: lastRound, isCompleted: completed
        )
    }

    private static func asked(
        _ records: [MoodleAssignmentRecord],
        cached: [SDAssignment],
        confirmed: [String: Date] = [:],
        lastAnsweredRound: Date? = lastRound
    ) -> [Int] {
        AppServiceBridge.recordsToAskAbout(
            records, cached: cached, confirmed: confirmed, lastAnsweredRound: lastAnsweredRound
        ).map(\.assignId)
    }

    @Test("an assignment Moodle called unsubmitted after its cutoff is not asked about again")
    func closedUnsubmittedIsSkipped() {
        let closed = Self.record(1, cutoff: Self.lastRound - 3600)
        #expect(Self.asked([closed], cached: [Self.cached(1)]).isEmpty)
    }

    @Test("a cutoff after the last answered round, a new assignment or no cutoff is asked about")
    func openOrUnknownIsAsked() {
        let records = [
            Self.record(1, cutoff: Self.lastRound + 60),
            Self.record(2, cutoff: Self.lastRound - 3600),
            Self.record(3, cutoff: nil),
            Self.record(4, cutoff: Self.lastRound - 3600),
        ]
        let cached = [Self.cached(1), Self.cached(3), Self.cached(4, completed: true)]
        #expect(Self.asked(records, cached: cached) == [1, 2, 3, 4])
    }

    @Test("a pull asks about every closed assignment")
    func pullAsksAboutAll() {
        let closed = Self.record(1, cutoff: Self.lastRound - 3600)
        #expect(Self.asked([closed], cached: [Self.cached(1)], lastAnsweredRound: nil) == [1])
    }

    @Test("confirmed, undated and no-submission records are left out")
    func unaskableRecordsAreLeftOut() {
        let noSubmissions = MoodleAssignmentRecord(
            assignId: 3, cmId: 3, courseId: 1, name: "Reading", dueDate: Self.lastRound, cutoffDate: nil,
            allowSubmissionsFromDate: nil, intro: "", noSubmissions: true
        )
        let records = [Self.record(1, cutoff: nil), Self.record(2, cutoff: nil, due: nil), noSubmissions]
        #expect(Self.asked(records, cached: [], confirmed: ["1": Self.lastRound]).isEmpty)
    }

    // MARK: - Concurrency

    @MainActor
    private final class Tracker {
        var running = 0
        var mostAtOnce = 0
    }

    @Test("at most the limit runs at once, and the results keep the input order")
    func concurrentMapIsBoundedAndOrdered() async {
        let tracker = Tracker()
        let items = Array(0..<10)
        let doubled = await AppServiceBridge.concurrentMap(items, limit: 4) { @MainActor item in
            tracker.running += 1
            tracker.mostAtOnce = max(tracker.mostAtOnce, tracker.running)
            try? await Task.sleep(for: .milliseconds(10 * (10 - item)))
            tracker.running -= 1
            return item * 2
        }
        #expect(doubled == items.map { $0 * 2 })
        #expect(tracker.mostAtOnce == 4)
    }

    @Test("fewer items than the limit all run, and none gives none")
    func concurrentMapSmallInputs() async {
        #expect(await AppServiceBridge.concurrentMap([1, 2], limit: 4) { $0 + 1 } == [2, 3])
        #expect(await AppServiceBridge.concurrentMap([Int](), limit: 4) { $0 }.isEmpty)
    }
}
