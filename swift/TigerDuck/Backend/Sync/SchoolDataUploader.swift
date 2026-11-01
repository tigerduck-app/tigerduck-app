import Foundation
import os

@MainActor
protocol SchoolDataBackend: AnyObject {
    func uploadCoursesIfChanged(
        _ request: PushAPI.CourseUploadRequest, semester: String, resend: Bool, addedAt stamp: Date?,
        for signIn: SignIn, while wanted: @escaping @MainActor () -> Bool
    ) async throws -> Bool
    func uploadAssignmentsIfChanged(
        _ request: PushAPI.AssignmentUploadRequest, for signIn: SignIn, while wanted: @escaping @MainActor () -> Bool
    ) async throws -> Bool
}

extension PushCoordinator: SchoolDataBackend {}

@MainActor
final class SchoolDataUploader {
    private let target: FirstPullGate
    private let backend: any SchoolDataBackend
    private let policy: () -> SyncPolicy

    init(
        target: FirstPullGate, backend: any SchoolDataBackend,
        policy: @escaping () -> SyncPolicy = { .current }
    ) {
        self.target = target
        self.backend = backend
        self.policy = policy
    }

    func uploadCourses(
        _ courses: [SDCourse], semester: String, asRoster: Bool = false, resend: Bool = false, for signIn: SignIn
    ) {
        guard policy().uploadsCourses else { return }
        let request = Self.courseUploadRequest(courses, semester: semester, rosterTerms: asRoster ? [semester] : nil)
        let backend = backend
        Task { [weak self] in
            await self?.sendUpload("uploadCourses \(semester)", for: signIn) { wanted in
                try await backend.uploadCoursesIfChanged(
                    request, semester: semester, resend: resend, addedAt: nil, for: signIn, while: wanted
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

    func uploadAssignments(_ request: PushAPI.AssignmentUploadRequest, for signIn: SignIn) {
        guard policy().cloudSyncEnabled else { return }
        let backend = backend
        Task { [weak self] in
            await self?.sendUpload("uploadAssignments", for: signIn) { wanted in
                try await backend.uploadAssignmentsIfChanged(request, for: signIn, while: wanted)
            }
        }
    }

    private func sendUpload(
        _ label: String,
        for signIn: SignIn,
        _ send: (_ wanted: @escaping @MainActor () -> Bool) async throws -> Bool
    ) async {
        let wanted: @MainActor () -> Bool = { [weak self] in self?.policy().cloudSyncEnabled == true }
        guard signIn.isCurrent, wanted(), await target.waitForPull(signIn) == .pulled, wanted() else { return }
        do {
            let sent = try await send(wanted)
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
        return PushAPI.CourseUploadRequest(courses: entries, completeRosterTerms: rosterTerms)
    }
}
