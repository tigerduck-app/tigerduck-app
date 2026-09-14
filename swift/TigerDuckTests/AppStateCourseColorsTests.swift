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
    @Test("turning courses off turns colours off")
    func coursesOffTurnsColoursOff() {
        #expect(AppState.courseColorsAfterCoursesChange(coursesNowOn: false) == false)
    }

    @Test("turning courses on turns colours on with them")
    func coursesOnTurnsColoursOn() {
        #expect(AppState.courseColorsAfterCoursesChange(coursesNowOn: true) == true)
    }
}
