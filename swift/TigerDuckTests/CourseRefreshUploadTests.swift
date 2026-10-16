import Foundation
import Testing
@testable import TigerDuck

/// `AppServiceBridge.uploadVisibleCourses`: what a course refresh sends to the server
/// (https://github.com/tigerduck-app/tigerduck-app/issues/650).
@MainActor
struct CourseRefreshUploadTests {
    private static let courses = ["CS1", "CS2", "CS3"].map { SDCourse(courseNo: $0, courseName: $0) }

    @Test("A course refresh uploads its term but the courses hidden here, in that term or in every term")
    func hiddenCoursesStayOutOfTheUpload() {
        var uploads: [(courses: [String], semester: String)] = []

        AppServiceBridge.uploadVisibleCourses(
            Self.courses, semester: "1151", hidden: ["1151:CS2", "CS3", "1142:CS1"]
        ) { uploads.append(($0.map(\.courseNo), $1)) }

        #expect(uploads.map(\.courses) == [["CS1"]])
        #expect(uploads.map(\.semester) == ["1151"])
    }

    @Test("A course refresh whose courses are all hidden here uploads nothing")
    func aTermHiddenWholeUploadsNothing() {
        var uploads = 0

        AppServiceBridge.uploadVisibleCourses(
            Self.courses, semester: "1151", hidden: ["1151:CS1", "1151:CS2", "1151:CS3"]
        ) { _, _ in uploads += 1 }

        #expect(uploads == 0)
    }
}
