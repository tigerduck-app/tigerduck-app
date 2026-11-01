import Defaults
import Foundation

enum AssignmentAnswers {
    static var assignmentUploader: ((PushAPI.AssignmentUploadRequest, SignIn) -> Void)?

    static func saveMoodleCalendarEvents(of assignments: [SDAssignment], in cache: AssignmentStore, for signIn: SignIn) {
        var calendarEvents = cache.loadCalendarEvents()
        calendarEvents.removeAll { $0.source == .moodle }
        calendarEvents.append(contentsOf: assignments.map(AssignmentRecords.moodleCalendarEvent))
        cache.saveCalendarEvents(calendarEvents, for: signIn)
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

    static func uploadForReminders(_ assignments: [SDAssignment], for signIn: SignIn) {
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
        upload(PushAPI.AssignmentUploadRequest(assignments: entries), signIn)
        #endif
    }
}
