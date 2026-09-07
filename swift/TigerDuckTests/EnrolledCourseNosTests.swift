import Foundation
import Testing
@testable import TigerDuck

struct EnrolledCourseNosTests {
    @Test("選課 answered: Moodle extras are dropped, transcript still tops up")
    func selectionIsAuthoritative() {
        let nos = AppServiceBridge.enrolledCourseNos(
            selection: ["CS1", "CS2"],
            moodle: ["CS2", "DROPPED"],
            transcript: ["CS1", "PE9"]
        )
        #expect(nos == ["CS1", "CS2", "PE9"])
    }

    @Test("選課 not consulted or unreachable: Moodle is the source")
    func moodleWhenNoSelection() {
        let nos = AppServiceBridge.enrolledCourseNos(
            selection: nil,
            moodle: ["CS2", "", "CS2", "CS3"],
            transcript: ["CS3", "PE9"]
        )
        #expect(nos == ["CS2", "CS3", "PE9"])
    }

    @Test("An empty 選課 answer falls back to Moodle: parser drift is indistinguishable from no enrolments")
    func emptySelectionFallsBackToMoodle() {
        #expect(AppServiceBridge.enrolledCourseNos(selection: [], moodle: ["CS2"], transcript: ["PE9"]) == ["CS2", "PE9"])
    }
}
