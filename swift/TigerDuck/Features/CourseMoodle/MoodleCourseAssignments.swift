import Foundation
import Observation

@Observable
@MainActor
final class MoodleCourseAssignments {
    struct Entry: Hashable, Identifiable {
        let record: MoodleAssignmentRecord
        let listed: SDAssignment?

        var id: Int { record.assignId }
    }

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

    static func records(in context: MoodleCacheContext) -> [MoodleAssignmentRecord] {
        context.cache.loadMoodleData(
            [MoodleAssignmentRecord].self, name: MoodleAssignmentRecord.cacheName, account: context.account
        )?.value ?? []
    }

    func reload() {
        let saved = Self.records(in: context)
        records = Dictionary(saved.map { (String($0.assignId), $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Dictionary(
            context.cache.loadAssignments().map { ($0.assignmentId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        list = saved.filter { $0.courseId == courseId }.map { Entry(record: $0, listed: listed[String($0.assignId)]) }
    }

    func entry(for assignment: SDAssignment) -> Entry? {
        records[assignment.assignmentId].map { Entry(record: $0, listed: assignment) }
    }

    func submission(of record: MoodleAssignmentRecord) -> MoodleFeed<MoodleAssignmentSubmission> {
        if let feed = submissions[record.assignId] { return feed }
        let feed = MoodleFeed<MoodleAssignmentSubmission>(
            cacheName: "courses/\(courseId)/assignments/\(record.assignId)", ttl: 0, context: context
        )
        submissions[record.assignId] = feed
        return feed
    }

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
    static func forAssignment(_ id: String, context: MoodleCacheContext, api: MoodleCourseAPI = .live) -> MoodleCourseStore? {
        guard let courseId = MoodleCourseAssignments.records(in: context).first(where: { String($0.assignId) == id })?.courseId
        else { return nil }
        return MoodleCourseStore(courseId: courseId, termCourseIds: [courseId], context: context, api: api)
    }
}
