import Testing
@testable import TigerDuck

@Suite("Course-sync → course-colours cascade")
struct CourseColorCascadeTests {
    @Test("turning courses off turns colours off")
    func coursesOffTurnsColoursOff() {
        #expect(EditSender.courseColorsAfterCoursesChange(coursesNowOn: false) == false)
    }

    @Test("turning courses on turns colours on with them")
    func coursesOnTurnsColoursOn() {
        #expect(EditSender.courseColorsAfterCoursesChange(coursesNowOn: true) == true)
    }
}
