import Defaults
import Foundation

enum AssignmentAnswers {
    static var assignmentUploader: ((PushAPI.AssignmentUploadRequest) -> Void)?

    static func persistRound(
        _ assignments: [SDAssignment],
        records: [MoodleAssignmentRecord],
        closed: [String: Date],
        answered: [Int: ContinuousClock.Instant],
        account: String,
        fetchedAt: Date,
        assignments store: AssignmentStore,
        moodle: MoodleFiles,
        rounds: AssignmentRounds = .shared,
        isCurrent: () -> Bool
    ) -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        store.saveAssignments(assignments)
        moodle.saveMoodleData(records, fetchedAt: fetchedAt, name: MoodleAssignmentRecord.cacheName, account: account)
        store.replaceClosedUnsubmittedAssignments(closed)
        saveMoodleCalendarEvents(of: assignments, in: store)
        for (id, askedAt) in answered { rounds.statusAskedAt[String(id)] = askedAt }
        return true
    }

    static func saveMoodleCalendarEvents(of assignments: [SDAssignment], in cache: AssignmentStore) {
        var calendarEvents = cache.loadCalendarEvents()
        calendarEvents.removeAll { $0.source == .moodle }
        calendarEvents.append(contentsOf: assignments.map(AssignmentRecords.moodleCalendarEvent))
        cache.saveCalendarEvents(calendarEvents)
    }

    static func askStatuses(
        of records: [MoodleAssignmentRecord],
        limit: Int = maxConcurrentRequests,
        fetch: @escaping @Sendable (_ assignId: Int) async throws -> MoodleSubmissionStatus
    ) async -> [Int: (status: MoodleSubmissionStatus, askedAt: ContinuousClock.Instant)] {
        typealias Answer = (Int, MoodleSubmissionStatus, ContinuousClock.Instant)
        let answers = await concurrentMap(records, limit: limit) { record -> Answer? in
            let askedAt = ContinuousClock.now
            guard let status = try? await fetch(record.assignId) else { return nil }
            return (record.assignId, status, askedAt)
        }
        return Dictionary(
            answers.compactMap { $0.map { ($0.0, (status: $0.1, askedAt: $0.2)) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func uploadForReminders(_ assignments: [SDAssignment]) {
        #if os(iOS)
        guard let upload = assignmentUploader, Defaults[.cloudSyncEnabled] else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let entries = assignments.compactMap { a -> PushAPI.AssignmentUploadEntry? in
            guard let id = Int(a.assignmentId) else { return nil }
            return PushAPI.AssignmentUploadEntry(
                moodleAssignmentId: id,
                courseNo: a.courseNo,
                courseName: a.courseName,
                title: a.title,
                dueAt: iso.string(from: a.dueDate),
                moodleUrl: a.moodleUrl,
                isSubmitted: a.isCompleted,
                grade: nil
            )
        }
        upload(PushAPI.AssignmentUploadRequest(assignments: entries))
        #endif
    }
}
