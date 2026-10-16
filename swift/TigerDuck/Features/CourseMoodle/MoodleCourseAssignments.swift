import Foundation
import Observation

/// A course's assignments for its Moodle section: those the last assignment round left, which its
/// row counts and its list shows, and each one's submission, fetched when its page opens.
@Observable
@MainActor
final class MoodleCourseAssignments {
    /// With a due date and a submission, as Home lists them.
    private(set) var list: [SDAssignment] = []

    @ObservationIgnored private let courseId: Int
    @ObservationIgnored private let context: MoodleCacheContext
    @ObservationIgnored private let api: MoodleCourseAPI
    @ObservationIgnored private var records: [String: MoodleAssignmentRecord] = [:]
    @ObservationIgnored private var submissions: [String: MoodleFeed<MoodleAssignmentSubmission>] = [:]

    init(courseId: Int, context: MoodleCacheContext, api: MoodleCourseAPI) {
        self.courseId = courseId
        self.context = context
        self.api = api
        reload()
    }

    /// The records of the account's last assignment round, by assignment id.
    static func records(in context: MoodleCacheContext) -> [String: MoodleAssignmentRecord] {
        let saved = context.cache.loadMoodleData(
            [MoodleAssignmentRecord].self, name: MoodleAssignmentRecord.cacheName, account: context.account
        )?.value ?? []
        return Dictionary(saved.map { (String($0.assignId), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads them again, as a round that ends while the course detail shows asks.
    func reload() {
        records = Self.records(in: context)
        list = context.cache.loadAssignments().filter { records[$0.assignmentId]?.courseId == courseId }
    }

    func record(of assignment: SDAssignment) -> MoodleAssignmentRecord? {
        records[assignment.assignmentId]
    }

    func submission(of assignment: SDAssignment) -> MoodleFeed<MoodleAssignmentSubmission> {
        if let feed = submissions[assignment.assignmentId] { return feed }
        let feed = MoodleFeed<MoodleAssignmentSubmission>(
            cacheName: "courses/\(courseId)/assignments/\(assignment.assignmentId)",
            ttl: MoodleRefreshInterval.submission,
            context: context
        )
        submissions[assignment.assignmentId] = feed
        return feed
    }

    /// The submission as Moodle has it now, with its comments and its group's name where the site
    /// lets the app read them. A call Moodle refuses leaves its part out; one that cannot reach
    /// Moodle keeps what the page showed.
    func refreshSubmission(of assignment: SDAssignment) async {
        guard let assignId = Int(assignment.assignmentId) else { return }
        let record = self.record(of: assignment)
        await submission(of: assignment).refresh { [api] in
            let functions = try await api.functions()
            var submission = try await api.submission(assignId)
            if let record, let id = submission.id, submission.takesComments,
               functions.contains(MoodleAssignmentService.commentsFunction) {
                submission.comments = try await Self.unlessRefused { try await api.comments(record.cmId, id) }
            }
            if let record, record.teamSubmission, let group = submission.groupId,
               functions.contains(MoodleAssignmentService.groupsFunction) {
                submission.groupName = try await Self.unlessRefused { try await api.groups(record.courseId) }?[group]
            }
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
        guard let courseId = MoodleCourseAssignments.records(in: context)[id]?.courseId else { return nil }
        return MoodleCourseStore(courseId: courseId, termCourseIds: [courseId], context: context, api: api)
    }
}
