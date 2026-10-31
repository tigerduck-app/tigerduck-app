import Foundation
import os

/// Hands a term's courses to the backend upload the app installs, and answers its roster requests.
enum CourseUpload {
    typealias CourseUploader = (_ courses: [SDCourse], _ semester: String, _ asRoster: Bool, _ resend: Bool) -> Void

    static var courseUploader: CourseUploader?
    static var rosterRequests = RosterRequestLog()

    /// A requested term goes up even when unchanged: the backend asks because no roster of it
    /// arrived for a week.
    static func answerRosterRequests(in snapshot: [String: Any], authService: AuthService) {
        guard SyncPolicy.current.uploadsCourses else { return }
        for term in rosterRequests.termsToAsk(in: snapshot, signIn: authService.session.ticket, now: Date()) {
            AppLogger.sync.info("[sync] roster requested for \(term, privacy: .public)")
            Task {
                _ = await CourseFetch.fetchCourses(authService: authService, semester: term, forceRefresh: true, resendingRoster: true)
            }
        }
    }

    /// Uploads the term's courses but those hidden here. They go as the term's roster when
    /// `roster`, course selection's answer or a past term's final transcript, names no course they
    /// leave out but a hidden one: the backend drops each school course a roster leaves out, so a
    /// failed lookup must not drop its course. A hidden course has no server row once its delete
    /// lands; listing it would file one for a course hidden before the server held it, and the
    /// next sync would show it again.
    static func uploadVisibleCourses(
        _ courses: [SDCourse],
        semester: String,
        hidden: Set<String>,
        roster: [String]? = nil,
        resendingRoster: Bool = false,
        to upload: CourseUploader?
    ) {
        let isHidden = { (courseNo: String) in CourseTombstone.isHidden(courseNo, semester: semester, in: hidden) }
        let visible = courses.filter { !isHidden($0.courseNo) }
        guard !visible.isEmpty else { return }
        let listed = Set(visible.map(\.courseNo))
        let asRoster = roster?.allSatisfy { listed.contains($0) || isHidden($0) } ?? false
        upload?(visible, semester, asRoster, resendingRoster && asRoster)
    }
}
