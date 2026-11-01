import Foundation
import os

@MainActor
protocol SchoolDataBackend: AnyObject {
    func uploadCoursesIfChanged(
        _ request: PushAPI.CourseUploadRequest, semester: String, resend: Bool, addedAt stamp: Date?,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool
    func uploadAssignmentsIfChanged(
        _ request: PushAPI.AssignmentUploadRequest, isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool
}

extension PushCoordinator: SchoolDataBackend {}

@MainActor
final class SchoolDataUploader {
    private let account: AccountSession
    private let target: SyncTarget
    private let backend: any SchoolDataBackend
    private let policy: () -> SyncPolicy

    init(
        account: AccountSession, target: SyncTarget, backend: any SchoolDataBackend,
        policy: @escaping () -> SyncPolicy = { .current }
    ) {
        self.account = account
        self.target = target
        self.backend = backend
        self.policy = policy
    }

    func uploadCourses(_ courses: [SDCourse], semester: String, asRoster: Bool = false, resend: Bool = false) {
        guard policy().uploadsCourses else { return }
        let request = Self.courseUploadRequest(courses, semester: semester, rosterTerms: asRoster ? [semester] : nil)
        let ticket = account.ticket
        let backend = backend
        Task { [weak self] in
            await self?.sendUpload("uploadCourses \(semester)", ticket: ticket) { isCurrent in
                try await backend.uploadCoursesIfChanged(
                    request, semester: semester, resend: resend, addedAt: nil, isCurrent: isCurrent
                )
            }
        }
    }

    static func addedCourseUpload(
        semester: String, courseNo: String, courses: CourseStore = .shared
    ) -> PushAPI.CourseUploadRequest? {
        let shown = CanonicalCourseProvider(courses: courses).currentCourses(semester: semester)
        guard let course = shown.first(where: { $0.courseNo == courseNo }) else { return nil }
        return courseUploadRequest([course], semester: semester)
    }

    func uploadAssignments(_ request: PushAPI.AssignmentUploadRequest) {
        guard policy().cloudSyncEnabled else { return }
        let ticket = account.ticket
        let backend = backend
        Task { [weak self] in
            await self?.sendUpload("uploadAssignments", ticket: ticket) { isCurrent in
                try await backend.uploadAssignmentsIfChanged(request, isCurrent: isCurrent)
            }
        }
    }

    private func sendUpload(
        _ label: String,
        ticket: AccountSession.Ticket,
        _ send: (_ isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
    ) async {
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return account.isCurrent(ticket) && policy().cloudSyncEnabled
        }
        guard isCurrent(), await target.waitForPull(ticket), isCurrent() else { return }
        do {
            let sent = try await send(isCurrent)
            AppLogger.sync.info("\(label, privacy: .public): \(sent ? "sent" : "skipped", privacy: .public)")
        } catch {
            AppLogger.sync.error("\(label, privacy: .public) failed: \(error, privacy: .private)")
        }
    }

    static func courseUploadRequest(
        _ courses: [SDCourse],
        semester: String,
        rosterTerms: [String]? = nil
    ) -> PushAPI.CourseUploadRequest {
        let entries = courses.map { c in
            PushAPI.CourseUploadEntry(
                semester: semester,
                courseNo: c.courseNo,
                courseName: c.courseName,
                courseNameEn: nil,
                moodleId: c.moodleIdNumber,
                credits: c.credits > 0 ? c.credits : nil,
                classroom: c.classroom.isEmpty ? nil : c.classroom,
                instructors: c.instructor.isEmpty ? [] : [c.instructor],
                scheduleJson: c.schedule.isEmpty ? nil : Dictionary(uniqueKeysWithValues: c.schedule.map { ("\($0.key)", $0.value) }),
                classroomMap: c.classroomMap.isEmpty ? nil : c.classroomMap
            )
        }
        return PushAPI.CourseUploadRequest(courses: entries, rosterTerms: rosterTerms)
    }
}
