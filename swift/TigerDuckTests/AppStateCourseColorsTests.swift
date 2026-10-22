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
