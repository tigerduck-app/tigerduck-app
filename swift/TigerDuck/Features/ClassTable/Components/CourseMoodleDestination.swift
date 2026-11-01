import SwiftUI
import TigerDuckCore

struct CourseMoodleDestination: View {
    let route: MoodleCourseRoute
    let store: MoodleCourseStore
    let courseName: String
    @Binding var path: [MoodleCourseRoute]
    let refresh: () async -> Void
    let openAssignment: (MoodleCourseAssignments.Entry) -> Void

    @Environment(AppEnvironment.self) private var app

    var body: some View {
        switch route {
        case .announcements:
            MoodleAnnouncementsView(store: store) { path.append($0) }
        case .announcement(let discussion):
            MoodleAnnouncementView(store: store, discussion: discussion) { path.append($0) }
        case .materials:
            MoodleMaterialsView(store: store, policy: app.preferences.visualStylePolicy)
        case .grades:
            MoodleGradesView(store: store)
        case .members:
            MoodleMembersView(store: store, policy: app.preferences.visualStylePolicy) { path.append($0) }
        case .member(let member):
            MoodleMemberView(store: store, member: member)
        case .forums:
            MoodleForumsView(store: store) { path.append($0) }
        case .forum(let forum):
            MoodleForumView(store: store, forum: forum) { path.append($0) }
        case .discussion(let discussion, let forum):
            MoodleDiscussionView(store: store, discussion: discussion, forum: forum)
        case .assignments:
            MoodleAssignmentsView(
                store: store, policy: app.preferences.visualStylePolicy, refresh: refresh, open: openAssignment
            )
        case .assignment(let entry):
            #if os(iOS)
            MoodleAssignmentView(
                store: store, entry: entry, courseName: courseName,
                policy: app.preferences.visualStylePolicy, accent: app.preferences.accentColor
            )
            #else
            EmptyView()
            #endif
        case .syllabus:
            EmptyView()
        }
    }

    static func store(for course: CourseStore.Course, authService: AuthService) -> MoodleCourseStore? {
        guard let idnumber = course.moodleIdNumber, !idnumber.isEmpty,
              let courseId = CourseLookup.moodleCourseId(idnumber: idnumber),
              let context = MoodleCacheContext.signedIn(authService) else { return nil }
        let term = AcademicTerm.codePrefix(ofMoodleId: idnumber)
        let idMap = CourseLookup.moodleCourseIds()
        let termCourseIds = idMap
            .filter { term != nil && AcademicTerm.codePrefix(ofMoodleId: $0.key) == term }
            .map(\.value)
        return MoodleCourseStore(
            courseId: courseId,
            termCourseIds: termCourseIds,
            courseCodes: courseCodes(
                idnumber: idnumber, courseNo: course.courseNo, courseId: courseId, idMap: idMap
            ),
            context: context
        )
    }

    static func courseCodes(idnumber: String, courseNo: String, courseId: Int, idMap: [String: Int]) -> [String] {
        let idnumbers = [idnumber] + idMap.filter { $0.value == courseId }.map(\.key)
        return idnumbers + idnumbers.map(CourseStore.Course.courseNoFromMoodleId) + [courseNo]
    }
}
