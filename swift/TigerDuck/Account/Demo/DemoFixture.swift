import Foundation
import TigerDuckCore

/// `demo.json` is the Android app's file too. A change may land here first, with an Android issue to copy it.
nonisolated struct DemoFixture: Decodable, Sendable {
    let studentId: String
    let schoolPassword: String
    let libraryPassword: String
    let libraryQr: LibraryQR?
    let courses: [Course]?
    let classmates: [Classmate]?
    let assignments: [Assignment]?
    let bulletins: [Bulletin]?
    let calendar: [CalendarEntry]?
    let moodle: DemoMoodle?
    let emptyClassroom: DemoClassrooms?

    enum CodingKeys: String, CodingKey {
        case studentId, libraryQr, courses, classmates, assignments, bulletins, calendar, moodle, emptyClassroom
        case schoolPassword = "school-password"
        case libraryPassword = "library-password"
    }

    struct LibraryQR: Decodable, Sendable {
        let content: String
        let fakeLoggedIn: Bool?
    }

    struct Course: Decodable, Sendable {
        let courseNo: String
        let name: DemoText
        let instructor: DemoText?
        let credits: Double?
        let classroom: String?
        let colorHex: String?
        let schedule: [String: [String]]?
        let classroomMap: [String: String]?
    }

    struct Classmate: Decodable, Sendable {
        let studentId: String
        let nickname: DemoText
        let courses: [Course]?
    }

    struct Assignment: Decodable, Sendable {
        let id: String
        let courseNo: String
        let courseName: DemoText?
        let title: DemoText
        let due: String
        let completed: Bool?
    }

    struct Bulletin: Decodable, Sendable {
        let id: Int?
        let title: String
        let org: String?
        let summary: String?
        let tags: [String]?
        let postedAt: String?
        let sourceUrl: String?
    }

    struct CalendarEntry: Decodable, Sendable {
        let id: String?
        let title: String
        let date: String
        let source: String?
    }

    static let bundled: DemoFixture? = load(from: .main)

    static func isDemoLibrary(_ username: String?, _ password: String?) -> Bool {
        guard let username, let password, let bundled else { return false }
        return bundled.matchesLibrary(username: username, password: password)
    }

    static func load(from bundle: Bundle) -> DemoFixture? {
        guard let url = bundle.url(forResource: "demo", withExtension: "json") else { return nil }
        do {
            return try JSONDecoder().decode(DemoFixture.self, from: Data(contentsOf: url))
        } catch {
            AppLogger.captureError(error, context: ["flow": "demoFixture"])
            return nil
        }
    }

    func matches(studentId: String, password: String) -> Bool {
        Self.credentialsMatch(studentId, password, id: self.studentId, password: schoolPassword)
    }

    func matchesLibrary(username: String, password: String) -> Bool {
        Self.credentialsMatch(username, password, id: studentId, password: libraryPassword)
    }

    var normalizedStudentId: String { AuthService.normalizedStudentId(studentId) }

    private static func credentialsMatch(_ studentId: String, _ password: String, id: String, password expected: String) -> Bool {
        let expectedId = AuthService.normalizedStudentId(id)
        return !expectedId.isEmpty && !expected.isEmpty
            && AuthService.normalizedStudentId(studentId) == expectedId && password == expected
    }
}

nonisolated enum DemoLanguage: String, CaseIterable, Sendable {
    case zh, en

    static var shown: DemoLanguage {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh") ? .zh : .en
    }
}

/// A field that is a plain string or a `{"zh", "en"}` pair.
nonisolated struct DemoText: Decodable, Sendable {
    private let zh: String?
    private let en: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            zh = text
            en = text
            return
        }
        let pair = try container.decode([String: String].self)
        zh = pair["zh"].flatMap { $0.isEmpty ? nil : $0 }
        en = pair["en"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func text(in language: DemoLanguage) -> String {
        (language == .zh ? zh ?? en : en ?? zh) ?? ""
    }
}

nonisolated enum DemoTime {
    private static let localFormats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"]

    static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T"),
              !text.isEmpty else { return nil }
        if let dated = try? Date(text, strategy: .iso8601) { return dated }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TaipeiTime.timeZone
        for format in localFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
