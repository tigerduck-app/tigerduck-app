import Foundation
import Testing
@testable import TigerDuck

struct MoodleHomeworkRegressionTests {
    @Test func moodleDeepLink_usesFetchedMoodleUrl() {
        let assignment = SDAssignment(
            assignmentId: "event-42",
            courseNo: "EC1013701",
            courseName: "資料結構",
            title: "HW1",
            dueDate: Date(),
            moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=12345"
        )

        #expect(
            assignment.moodleDeepLink?.absoluteString
                == "moodlemobile://https://moodle2.ntust.edu.tw?redirect=/mod/assign/view.php?id%3D12345"
        )
    }

    @Test func courseNoFromMoodleId_onlyStripsNumericSemesterPrefix() {
        #expect(SDCourse.courseNoFromMoodleId("1142EC1013701") == "EC1013701")
        #expect(SDCourse.courseNoFromMoodleId("EC1013701") == "EC1013701")
    }

    @Test func moodleDeepLink_returnsNilWithoutFetchedMoodleUrl() {
        let assignment = SDAssignment(
            assignmentId: "123",
            courseNo: "EC1013701",
            courseName: "資料結構",
            title: "HW1",
            dueDate: Date(),
            moodleUrl: nil
        )

        #expect(assignment.moodleDeepLink == nil)
    }
}
