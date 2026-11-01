import Foundation

struct ClassTableSync {
    var courseIgnore: ((_ course: CourseStore.Course, _ semester: String, _ ignore: Bool) -> Void)?
    var courseOverride: ((_ moodleCourseId: String, _ colorHex: String?, _ customName: String?, _ locale: String?) -> Void)?
    var colorPick: ((_ hex: UInt32, _ course: CourseStore.Course, _ changed: [String: UInt32]) -> Void)?
    var coursesChanged: ((_ courses: [CourseStore.Course], _ semester: String) -> Void)?
    var courseAdded: ((_ courses: [CourseStore.Course], _ semester: String, _ addedCourseNo: String) -> Void)?
    var courseDeleted: ((_ courseNo: String, _ semester: String) -> Void)?
    var resetBackendCourses: ((_ semester: String, _ resetLocally: @MainActor () -> Void) async -> Bool)?

    /// Each closure runs inside the user's edit, so it reads the sign-in of that moment.
    static func live(_ app: AppEnvironment) -> ClassTableSync {
        let session = app.authService.session
        return ClassTableSync(
            courseIgnore: {
                app.edits.syncCourseIgnore(
                    semester: $1, courseNo: $0.courseNo, moodleIdNumber: $0.moodleIdNumber, ignore: $2,
                    for: session.currentSignIn
                )
            },
            courseOverride: {
                app.edits.syncCourseOverride(
                    moodleCourseId: $0, colorHex: $1, customName: $2, locale: $3, for: session.currentSignIn
                )
            },
            colorPick: { app.edits.syncColorPick($0, for: $1, changed: $2, signIn: session.currentSignIn) },
            coursesChanged: { app.uploads.uploadCourses($0, semester: $1, for: session.currentSignIn) },
            courseAdded: {
                app.edits.addCourses(
                    [CourseStore.Tombstone.serverKey(semester: $1, courseNo: $2)], semester: $1, for: session.currentSignIn
                )
            },
            courseDeleted: { app.edits.deleteBackendCourse(courseNo: $0, semester: $1, for: session.currentSignIn) },
            resetBackendCourses: { await app.edits.deleteBackendCourses(semester: $0, thenLocally: $1) }
        )
    }
}
