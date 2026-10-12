import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct AssignmentStatusRequestTests {
    private nonisolated static let askTime = Date(timeIntervalSince1970: 1_790_000_000)

    private static func record(_ id: Int, cutoff: Date?, due: Date? = askTime) -> MoodleAssignmentRecord {
        MoodleAssignmentRecord(
            assignId: id, cmId: id, courseId: 1, name: "HW\(id)", dueDate: due, cutoffDate: cutoff,
            allowSubmissionsFromDate: nil, intro: "", noSubmissions: false
        )
    }

    private static func status(_ id: Int, submitted: Bool) -> MoodleSubmissionStatus {
        MoodleSubmissionStatus(
            assignId: id, submissionStatus: submitted ? "submitted" : "new", gradingStatus: nil, submittedAt: nil
        )
    }

    @Test("a closed assignment is not asked about again until its cutoff moves past the answer")
    func closedAssignmentsAreSkipped() {
        let records = [
            Self.record(1, cutoff: nil),
            Self.record(2, cutoff: Self.askTime - 60),
            Self.record(3, cutoff: Self.askTime + 60),
            Self.record(4, cutoff: nil),
        ]
        let closed = ["2": Self.askTime, "3": Self.askTime, "4": Self.askTime]
        let asked = AppServiceBridge.recordsToAskAbout(records, confirmed: [:], closed: closed)
        #expect(asked.map(\.assignId) == [1, 3, 4])
    }

    @Test("confirmed, undated and no-submission records are left out")
    func unaskableRecordsAreLeftOut() {
        let noSubmissions = MoodleAssignmentRecord(
            assignId: 3, cmId: 3, courseId: 1, name: "Reading", dueDate: Self.askTime, cutoffDate: nil,
            allowSubmissionsFromDate: nil, intro: "", noSubmissions: true
        )
        let records = [Self.record(1, cutoff: nil), Self.record(2, cutoff: nil, due: nil), noSubmissions]
        #expect(AppServiceBridge.recordsToAskAbout(records, confirmed: ["1": Self.askTime], closed: [:]).isEmpty)
    }

    @Test("only an unsubmitted answer asked for after the cutoff closes an assignment")
    func closingNeedsAnAnswerAfterTheCutoff() {
        let askedAt = Self.askTime
        let records = [
            Self.record(1, cutoff: askedAt - 60),
            Self.record(2, cutoff: askedAt + 60),
            Self.record(3, cutoff: nil),
            Self.record(4, cutoff: askedAt - 60),
            Self.record(5, cutoff: askedAt - 60),
        ]
        let statuses = [
            1: Self.status(1, submitted: false),
            2: Self.status(2, submitted: false),
            3: Self.status(3, submitted: false),
            4: Self.status(4, submitted: true),
        ]
        let closed = AppServiceBridge.closedUnsubmitted(
            records: records, statuses: statuses, askedAt: askedAt, kept: [:]
        )
        #expect(closed == ["1": askedAt])
    }

    @Test("an unanswered assignment stays closed while its cutoff does, and one no longer listed drops out")
    func unansweredAssignmentsKeepTheirTime() {
        let earlier = Self.askTime - 3600
        let records = [
            Self.record(1, cutoff: earlier - 60),
            Self.record(2, cutoff: earlier - 60),
            Self.record(3, cutoff: earlier + 60),
        ]
        let closed = AppServiceBridge.closedUnsubmitted(
            records: records, statuses: [2: Self.status(2, submitted: true)], askedAt: Self.askTime,
            kept: ["1": earlier, "2": earlier, "3": earlier, "9": earlier]
        )
        #expect(closed == ["1": earlier])
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
