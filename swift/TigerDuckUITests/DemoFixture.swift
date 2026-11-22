import Foundation

/// What the tests need from `demo.json`, read from the checkout this test was built from.
struct DemoFixture: Decodable {
    let studentId: String
    let password: String
    let courses: [Course]
    let assignments: [Assignment]
    let moodle: Moodle

    struct Course: Decodable {
        let courseNo: String
        let name: Text
    }

    struct Assignment: Decodable {
        let courseNo: String
        let title: Text
    }

    struct Moodle: Decodable {
        let courses: [MoodleCourse]
    }

    struct MoodleCourse: Decodable {
        let courseNo: String
    }

    /// A plain string, or a `{"zh", "en"}` pair.
    struct Text: Decodable {
        let byLanguage: [String: String]

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                byLanguage = ["zh": text, "en": text]
            } else {
                byLanguage = try container.decode([String: String].self)
            }
        }

        var shown: String {
            let language = Locale.preferredLanguages.first ?? "en"
            return byLanguage[language.hasPrefix("zh") ? "zh" : "en"] ?? ""
        }
    }

    enum CodingKeys: String, CodingKey {
        case studentId, courses, assignments, moodle
        case password = "school-password"
    }

    static let shared = load()

    private var moodleCourseNo: String? { moodle.courses.first?.courseNo }

    /// The first course with Moodle data, whose page has every section.
    var moodleCourseName: String {
        courses.first { $0.courseNo == moodleCourseNo }?.name.shown ?? ""
    }

    var moodleAssignmentTitle: String {
        assignments.first { $0.courseNo == moodleCourseNo }?.title.shown ?? ""
    }

    var courseNames: [String] { courses.map(\.name.shown) }

    private static func load() -> DemoFixture {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "TigerDuck/Account/Demo/demo.json")
        do {
            return try JSONDecoder().decode(DemoFixture.self, from: Data(contentsOf: url))
        } catch {
            fatalError("\(url.path(percentEncoded: false)): \(error)")
        }
    }
}
