import Foundation
import Testing
@testable import TigerDuck

struct MoodleNotificationPreferencesServiceTests {
    private typealias Service = MoodleNotificationPreferencesService
    private static let site = URL(string: "https://moodle-stub.invalid")!

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    static func endpoint(_ function: String, token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=\(function)&wstoken=\(token)")!
    }

    static func answer(_ body: String, function: String, token: String) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(body.utf8)), for: endpoint(function, token: token))
    }

    static func bodies(of function: String, token: String) -> [String] {
        SettingsAPIStub.requests(for: endpoint(function, token: token)).compactMap {
            SettingsAPIStub.bodyData(from: $0).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    private static func save(_ preference: MoodleNotificationMatrix.Preference, chinese: Bool = false) async throws -> [String] {
        let token = UUID().uuidString
        answer("null", function: Service.writeFunction, token: token)
        try await Service.save(
            preference, chinese: chinese, token: token, for: testSignIn, session: session(), siteURL: site
        )
        return bodies(of: Service.writeFunction, token: token).map { String($0.trimmingPrefix("wstoken=\(token)&")) }
    }

    private static func write(_ key: String, _ value: String, language: String = "en") -> String {
        "preferences%5B0%5D%5Btype%5D=message_provider_\(key)_enabled&preferences%5B0%5D%5Bvalue%5D=\(value)"
            + "&moodlewssettinglang=\(language)"
    }

    @Test("the read asks Moodle for its names in the app's language", arguments: [(true, "zh_tw"), (false, "en")])
    func readLanguage(chinese: Bool, language: String) async throws {
        let token = UUID().uuidString
        Self.answer(MoodleNotificationFixtures.answer, function: Service.readFunction, token: token)

        _ = try await Service.preferences(chinese: chinese, token: token, session: Self.session(), siteURL: Self.site)

        #expect(Self.bodies(of: Service.readFunction, token: token) == ["wstoken=\(token)&moodlewssettinglang=\(language)"])
    }

    @Test("the read hides Moodle's own app push, keeps the server's order and leaves out an empty component")
    func readDecodes() async throws {
        let token = UUID().uuidString
        Self.answer(MoodleNotificationFixtures.answer, function: Service.readFunction, token: token)

        let matrix = try await Service.preferences(chinese: false, token: token, session: Self.session(), siteURL: Self.site)

        #expect(matrix.methods == [.init(id: "popup", name: "Web"), .init(id: "email", name: "Email")])
        #expect(matrix.components.map(\.name) == ["Assignment", "System"])
        #expect(!matrix.disablesAll)
        let first = try #require(matrix.components.first?.preferences.first)
        #expect(first == MoodleNotificationMatrix.Preference(
            key: "message_provider_mod_assign_assign_notification", name: "Assignment notifications",
            processors: ["popup", "email", "airnotifier"], enabled: ["popup", "airnotifier"], locked: []
        ))
        #expect(matrix.components.last?.preferences.first?.locked == ["email"])
    }

    @Test("a switch turned on sends every processor then enabled, the hidden one kept, in the app's language")
    func switchOnSendsTheWholeList() async throws {
        let preference = MoodleNotificationFixtures.preference("mod_forum_posts", enabled: ["popup", "airnotifier"])

        let bodies = try await Self.save(preference.setting("email", on: true), chinese: true)

        #expect(bodies == [Self.write("mod_forum_posts", "popup%2Cemail%2Cairnotifier", language: "zh_tw")])
    }

    @Test("the last processor turned off sends none, as Moodle's own page does")
    func lastOffSendsNone() async throws {
        let preference = MoodleNotificationFixtures.preference("mod_forum_posts", enabled: ["email"])

        let bodies = try await Self.save(preference.setting("email", on: false))

        #expect(bodies == [Self.write("mod_forum_posts", "none")])
    }

    @Test("a switch turned off keeps the hidden processor on")
    func offKeepsHiddenProcessor() async throws {
        let preference = MoodleNotificationFixtures.preference("mod_forum_posts", enabled: ["popup", "airnotifier"])

        let bodies = try await Self.save(preference.setting("popup", on: false))

        #expect(bodies == [Self.write("mod_forum_posts", "airnotifier")])
    }

    @Test("a locked processor is left out of the value, as Moodle's own page leaves it out")
    func lockedLeftOut() {
        let preference = MoodleNotificationFixtures.preference(
            "moodle_reportbuilderschedule", enabled: ["email"], locked: ["email"]
        )

        #expect(Service.enabledValue(of: preference.setting("popup", on: true)) == "popup")
        #expect(Service.enabledValue(of: preference) == "none")
    }

    @Test("an answer with a warning is a failed write")
    func warningFails() async throws {
        let token = UUID().uuidString
        Self.answer(#"{"warnings": [{"item": "user", "warningcode": "nopermission", "message": "No"}]}"#,
                    function: Service.writeFunction, token: token)
        let preference = MoodleNotificationFixtures.preference("mod_forum_posts", enabled: [])

        await #expect(throws: MoodleWebserviceError.malformedResponse(detail: "nopermission")) {
            try await Service.save(
                preference, chinese: false, token: token, for: testSignIn, session: Self.session(), siteURL: Self.site
            )
        }
    }

    @Test("a write whose sign-in has ended is not sent")
    func endedSignInSendsNothing() async throws {
        let token = UUID().uuidString
        Self.answer("null", function: Service.writeFunction, token: token)
        let preference = MoodleNotificationFixtures.preference("mod_forum_posts", enabled: [])

        await #expect(throws: CancellationError.self) {
            try await Service.save(
                preference, chinese: false, token: token, for: endedTestSignIn, session: Self.session(), siteURL: Self.site
            )
        }
        #expect(Self.bodies(of: Service.writeFunction, token: token).isEmpty)
    }
}
