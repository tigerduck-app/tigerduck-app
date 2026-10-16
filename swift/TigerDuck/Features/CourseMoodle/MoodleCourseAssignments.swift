import Foundation
import Observation

/// A course's assignments for its Moodle section: those the last assignment round recorded, which
/// its row counts and its list shows, and each one's submission, fetched when its page opens.
@Observable
@MainActor
final class MoodleCourseAssignments {
    /// An assignment the round recorded, with Home's row for it, which keeps what Moodle said of the
    /// submission. Home lists none without a due date or an online submission.
    struct Entry: Hashable, Identifiable {
        let record: MoodleAssignmentRecord
        let listed: SDAssignment?

        var id: Int { record.assignId }
    }

    /// In the order Moodle lists them.
    private(set) var list: [Entry] = []

    @ObservationIgnored private let courseId: Int
    @ObservationIgnored private let context: MoodleCacheContext
    @ObservationIgnored private let api: MoodleCourseAPI
    @ObservationIgnored private var records: [String: MoodleAssignmentRecord] = [:]
    @ObservationIgnored private var submissions: [Int: MoodleFeed<MoodleAssignmentSubmission>] = [:]

    init(courseId: Int, context: MoodleCacheContext, api: MoodleCourseAPI) {
        self.courseId = courseId
        self.context = context
        self.api = api
        reload()
    }

    /// The records of the account's last assignment round, in Moodle's order.
    static func records(in context: MoodleCacheContext) -> [MoodleAssignmentRecord] {
        context.cache.loadMoodleData(
            [MoodleAssignmentRecord].self, name: MoodleAssignmentRecord.cacheName, account: context.account
        )?.value ?? []
    }

    /// Reads them again, as a round that ends while the course detail shows asks.
    func reload() {
        let saved = Self.records(in: context)
        records = Dictionary(saved.map { (String($0.assignId), $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Dictionary(
            context.cache.loadAssignments().map { ($0.assignmentId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        list = saved.filter { $0.courseId == courseId }.map { Entry(record: $0, listed: listed[String($0.assignId)]) }
    }

    /// Home's row with its record; nil while no round has recorded the assignment, which then
    /// opens on Moodle.
    func entry(for assignment: SDAssignment) -> Entry? {
        records[assignment.assignmentId].map { Entry(record: $0, listed: assignment) }
    }

    func submission(of record: MoodleAssignmentRecord) -> MoodleFeed<MoodleAssignmentSubmission> {
        if let feed = submissions[record.assignId] { return feed }
        // No copy counts as fresh: the page fetches the submission on every opening and return.
        let feed = MoodleFeed<MoodleAssignmentSubmission>(
            cacheName: "courses/\(courseId)/assignments/\(record.assignId)", ttl: 0, context: context
        )
        submissions[record.assignId] = feed
        return feed
    }

    /// The submission as Moodle has it now, with its comments and its group's name where the site
    /// lets the app read them. A call Moodle refuses leaves its part out; one that cannot reach
    /// Moodle keeps what the page showed. An assignment that takes no online submission has none.
    /// The status the page then shows goes to `api.submissionFetched` too.
    func refreshSubmission(of record: MoodleAssignmentRecord) async {
        guard !record.noSubmissions else { return }
        let context = context
        let isCurrent: @MainActor @Sendable () -> Bool = { context.isCurrent() }
        let fetched: @MainActor @Sendable (MoodleSubmissionStatus, ContinuousClock.Instant) -> Void = { [api] in
            api.submissionFetched($0, $1, context)
        }
        await submission(of: record).refresh { [api] in
            let functions = try await api.functions()
            let askedAt = ContinuousClock.now
            var submission = try await api.submission(record.assignId)
            if let id = submission.id, submission.takesComments,
               functions.contains(MoodleAssignmentService.commentsFunction) {
                // The next account's token would ask Moodle as them.
                guard await isCurrent() else { throw CancellationError() }
                submission.comments = try await Self.unlessRefused { try await api.comments(record.cmId, id) }
            }
            if record.teamSubmission, let group = submission.groupId,
               functions.contains(MoodleAssignmentService.groupsFunction) {
                guard await isCurrent() else { throw CancellationError() }
                submission.groupName = try await Self.unlessRefused { try await api.groups(record.courseId) }?[group]
            }
            await fetched(MoodleSubmissionStatus(
                assignId: record.assignId, submissionStatus: submission.status, gradingStatus: nil,
                submittedAt: submission.modified
            ), askedAt)
            return submission
        }
    }

    /// Nil for an answer that is a Moodle error, or one the app cannot read.
    private nonisolated static func unlessRefused<Value: Sendable>(
        _ call: () async throws -> Value
    ) async throws -> Value? {
        do {
            return try await call()
        } catch MoodleWebserviceError.accessDenied {
            return nil
        } catch MoodleWebserviceError.malformedResponse {
            return nil
        }
    }
}

extension MoodleCourseStore {
    /// The store of the course an assignment is in, for its page opened outside a course detail;
    /// nil until an assignment round names that course.
    static func forAssignment(_ id: String, context: MoodleCacheContext, api: MoodleCourseAPI = .live) -> MoodleCourseStore? {
        guard let courseId = MoodleCourseAssignments.records(in: context).first(where: { String($0.assignId) == id })?.courseId
        else { return nil }
        return MoodleCourseStore(courseId: courseId, termCourseIds: [courseId], context: context, api: api)
    }
}
