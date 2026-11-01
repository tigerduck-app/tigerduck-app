import Foundation
import os

enum CourseUpload {
    enum UploadKind {
        case courses
        case roster
        case requestedRoster

        var asRoster: Bool { self != .courses }
        var resend: Bool { self == .requestedRoster }
    }

    typealias CourseUploader = (_ courses: [SDCourse], _ semester: String, _ kind: UploadKind, _ signIn: SignIn) -> Void

    static var courseUploader: CourseUploader?
    static var rosterRequests = RosterRequestLog()

    static func answerRosterRequests(in snapshot: [String: Any], authService: AuthService, for signIn: SignIn) {
        guard SyncPolicy.current.uploadsCourses else { return }
        for term in rosterRequests.termsToAsk(in: snapshot, signIn: signIn, now: Date()) {
            AppLogger.sync.info("[sync] roster requested for \(term, privacy: .public)")
            Task {
                _ = await CourseFetch.fetchCourses(
                    authService: authService, semester: term, forceRefresh: true, resendingRoster: true, for: signIn
                )
            }
        }
    }

    static func uploadVisibleCourses(
        _ courses: [SDCourse],
        semester: String,
        hidden: Set<String>,
        roster: [String]? = nil,
        resendingRoster: Bool = false,
        for signIn: SignIn,
        to upload: CourseUploader?
    ) {
        let isHidden = { (courseNo: String) in CourseTombstone.isHidden(courseNo, semester: semester, in: hidden) }
        let visible = courses.filter { !isHidden($0.courseNo) }
        guard !visible.isEmpty else { return }
        let uploaded = Set(visible.map(\.courseNo))
        let everyRosterCourseIsUploadedOrHidden = roster?.allSatisfy { uploaded.contains($0) || isHidden($0) } ?? false
        let kind: UploadKind = !everyRosterCourseIsUploadedOrHidden ? .courses : resendingRoster ? .requestedRoster : .roster
        upload?(visible, semester, kind, signIn)
    }
}
