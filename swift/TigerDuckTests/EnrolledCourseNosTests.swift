import Foundation
import Testing
@testable import TigerDuck

struct EnrolledCourseNosTests {
    @Test("選課 answered: it owns the term, so neither Moodle nor a stale transcript adds courses")
    func selectionIsAuthoritative() {
        let nos = AppServiceBridge.enrolledCourseNos(
            selection: ["CS1", "CS2", "CS1"],
            moodle: ["CS2", "DROPPED"],
            transcript: ["CS1", "DROPPED"]
        )
        #expect(nos == ["CS1", "CS2"])
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

/// The 加退選 half of the same rule: 選課 owning its term is only half the
/// fix, because the backend keeps serving a course nobody deleted explicitly.
struct SelectionDropsTests {
    @Test("A course the answer no longer names is recorded as dropped")
    func dropIsWitnessed() {
        #expect(AppServiceBridge.selectionDrops(
            previous: [], localPortalNos: ["A", "B", "C"], roster: ["A", "B"]
        ) == ["C"])
    }

    @Test("A course this device never held is not a drop — that is how a manual course from another device survives")
    func unknownCourseIsNotADrop() {
        #expect(AppServiceBridge.selectionDrops(
            previous: [], localPortalNos: ["A"], roster: ["A"]
        ).isEmpty)
    }

    @Test("A course the answer names again is cleared, so a re-add comes straight back")
    func readdClears() {
        #expect(AppServiceBridge.selectionDrops(
            previous: ["C", "D"], localPortalNos: ["A"], roster: ["A", "C"]
        ) == ["D"])
    }

    @Test("An empty answer records nothing and clears nothing: parser drift is not a mass drop")
    func emptyAnswerIsInert() {
        #expect(AppServiceBridge.selectionDrops(
            previous: ["C"], localPortalNos: ["A", "B"], roster: []
        ) == ["C"])
    }
}
