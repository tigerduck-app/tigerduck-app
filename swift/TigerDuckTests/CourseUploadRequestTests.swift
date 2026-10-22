import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseUploadRequestTests {
    private static let courses = [
        SDCourse(courseNo: "CS1001301", courseName: "程式設計"),
        SDCourse(courseNo: "MA1001301", courseName: "微積分"),
    ]

    @Test("Each course with a colour carries it, generated or picked, keyed as the server keys its row")
    func coloursGoUpWithTheirCourses() {
        let request = AppState.courseUploadRequest(
            Self.courses, semester: "1151", forceKeys: [],
            colors: ["CS1001301": 0xFF6B6B, "EE0000000": 0x4ECDC4]
        )

        #expect(request.courseOverrides.map(\.courseKey) == ["client:1151:CS1001301"])
        #expect(request.courseOverrides.map(\.colorHex) == ["#FF6B6B"])
        #expect(request.courses.map(\.courseNo) == ["CS1001301", "MA1001301"])
    }

    @Test("Without colours, as when course colours do not sync, the request carries none")
    func noColoursNoOverrides() {
        let request = AppState.courseUploadRequest(Self.courses, semester: "1151", forceKeys: ["k"], colors: [:])

        #expect(request.courseOverrides.isEmpty)
        #expect(request.forceKeys == ["k"])
    }
}
