import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseUploadRequestTests {
    private static let courses = [
        SDCourse(courseNo: "CS1001301", courseName: "程式設計"),
        SDCourse(courseNo: "MA1001301", courseName: "微積分"),
    ]

    @Test("A course upload names its courses and terms and carries no colour or force key, which /v4 refuses")
    func noColoursOrForceKeys() throws {
        let request = SchoolDataUploader.courseUploadRequest(Self.courses, semester: "1151", rosterTerms: ["1151"])
        let body = try JSONSerialization.jsonObject(with: BackendClient.encoder.encode(request)) as? [String: Any]

        #expect(Set(body?.keys ?? [:].keys) == ["courses", "roster_terms"])
        #expect(request.courses.map(\.courseNo) == ["CS1001301", "MA1001301"])
    }
}
