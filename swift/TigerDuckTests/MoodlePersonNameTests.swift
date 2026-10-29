import Testing
@testable import TigerDuck

struct MoodlePersonNameTests {
    @Test(arguments: [
        ("B11399001 @ Tiger Duck", "Tiger Duck", "B11399001"),
        ("B11399001@塔克", "塔克", "B11399001"),
        ("Tiger Duck B11399001@", "Tiger Duck", "B11399001"),
        (" 塔克  B11399001@ ", "塔克", "B11399001"),
        ("B11399001@", "B11399001@", "B11399001"),
        ("Tiger Duck@", "Tiger Duck@", "Tiger Duck"),
        ("@ Tiger Duck", "Tiger Duck", nil),
        ("Tiger Duck", "Tiger Duck", nil),
    ] as [(String, String, String?)])
    func readsTheNameAndTheStudentId(fullName: String, name: String, studentId: String?) {
        #expect(MoodlePersonName.displayName(fullName) == name)
        #expect(MoodlePersonName.studentId(fullName) == studentId)
    }
}
