// `AppState.courseColorsAfterCoursesChange` (AppState+CourseColors.swift) —
// the spec §6 course-sync → course-colours cascade: dropping it left a
// greyed-out, un-reachable colours toggle stuck reading ON while
// `AppState+BackendSync.swift`'s `applyCourseOverrides` kept applying
// server colours underneath it.
//
// Exercises the decision function directly rather than through either
// settings view's `onChange`/Binding — this codebase has no SwiftUI
// view-inspection facility, and the function takes plain `Bool`s precisely so
// a test can reach it without touching `Defaults` or rendering a view.
import Testing
@testable import TigerDuck

@Suite("Course-sync → course-colours cascade")
struct AppStateCourseColorsTests {
    @Test("turning courses off forces colours off, even though colours started on")
    func coursesOffForcesColoursOff() {
        // The starting value is `true` on purpose: if colours already
        // started `false`, the assertion would pass on a no-op cascade
        // (or no cascade at all).
        #expect(AppState.courseColorsAfterCoursesChange(coursesNowOn: false, coloursCurrentlyOn: true) == false)
    }

    @Test("turning courses on, or leaving them on, never touches colours")
    func coursesOnLeavesColoursUntouched() {
        #expect(AppState.courseColorsAfterCoursesChange(coursesNowOn: true, coloursCurrentlyOn: true) == true)
        #expect(AppState.courseColorsAfterCoursesChange(coursesNowOn: true, coloursCurrentlyOn: false) == false)
    }
}
