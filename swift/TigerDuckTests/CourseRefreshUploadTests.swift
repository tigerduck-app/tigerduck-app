import Foundation
import Testing
@testable import TigerDuck

/// `AppServiceBridge.coursesToUpload`: what a course refresh sends to the server. It sent the
/// courses hidden here too, and the server keeps one out only by its tombstone, so a course hidden
/// while cloud sync was off came back (https://github.com/tigerduck-app/tigerduck-app/issues/650).
@MainActor
struct CourseRefreshUploadTests {
    @Test("A course refresh uploads the term's courses but those hidden here, in that term or in every term")
    func hiddenCoursesStayOutOfTheUpload() {
        let courses = ["CS1", "CS2", "CS3", "CS4"].map { SDCourse(courseNo: $0, courseName: $0) }

        let uploaded = AppServiceBridge.coursesToUpload(
            courses, semester: "1151", hidden: ["1151:CS2", "CS3", "1142:CS4"]
        )

        #expect(uploaded.map(\.courseNo) == ["CS1", "CS4"])
    }
}
