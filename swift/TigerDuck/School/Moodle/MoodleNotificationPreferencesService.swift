import Foundation

nonisolated enum MoodleNotificationPreferencesService {
    static let readFunction = "core_message_get_user_notification_preferences"
    static let writeFunction = "core_user_update_user_preferences"
    /// The push channel of Moodle's own app, which this app does not receive.
    static let hiddenMethods: Set<String> = ["airnotifier"]
    /// The value Moodle's own preferences page sends once every processor is off:
    /// https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/message/amd/src/notification_preference.js
    static let noProcessor = "none"

    static func preferences(
        chinese: Bool,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> MoodleNotificationMatrix {
        try await MoodleWebserviceClient.call(
            readFunction,
            params: [language(chinese)],
            token: token,
            as: RawAnswer.self,
            session: session,
            siteURL: siteURL
        ).preferences.matrix
    }

    /// Moodle 4.5 answers with `null`; an answer with a warning did not store the preference.
    static func save(
        _ preference: MoodleNotificationMatrix.Preference,
        chinese: Bool,
        token: String,
        for signIn: SignIn,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws {
        guard signIn.isCurrent, !Task.isCancelled else { throw CancellationError() }
        let answer = try await MoodleWebserviceClient.call(
            writeFunction,
            params: [
                ("preferences[0][type]", preference.key + "_enabled"),
                ("preferences[0][value]", enabledValue(of: preference)),
                language(chinese),
            ],
            token: token,
            as: RawWriteAnswer?.self,
            session: session,
            siteURL: siteURL
        )
        if let warning = answer?.warnings?.first {
            throw MoodleWebserviceError.malformedResponse(detail: warning.warningcode ?? writeFunction)
        }
    }

    /// Moodle's own page leaves a locked processor out, as it draws no switch to read for one:
    /// https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/message/templates/notification_preferences_component_notification.mustache
    static func enabledValue(of preference: MoodleNotificationMatrix.Preference) -> String {
        let names = preference.processors.filter { preference.enabled.contains($0) && !preference.locked.contains($0) }
        return names.isEmpty ? noProcessor : names.joined(separator: ",")
    }

    private static func language(_ chinese: Bool) -> (String, String) {
        ("moodlewssettinglang", chinese ? "zh_tw" : "en")
    }
}

private nonisolated struct RawAnswer: Decodable, Sendable {
    struct Processor: Decodable, Sendable {
        let name: String
        let displayname: String
    }

    struct State: Decodable, Sendable {
        let name: String
        let enabled: Bool
        let locked: Bool
    }

    struct Notification: Decodable, Sendable {
        let displayname: String
        let preferencekey: String
        let processors: [State]
    }

    struct Component: Decodable, Sendable {
        let displayname: String
        let notifications: [Notification]
    }

    struct Preferences: Decodable, Sendable {
        let disableall: Int
        let processors: [Processor]
        let components: [Component]

        var matrix: MoodleNotificationMatrix {
            MoodleNotificationMatrix(
                methods: processors
                    .filter { !MoodleNotificationPreferencesService.hiddenMethods.contains($0.name) }
                    .map { MoodleNotificationMatrix.Method(id: $0.name, name: $0.displayname) },
                components: components.filter { !$0.notifications.isEmpty }.map { component in
                    MoodleNotificationMatrix.Component(name: component.displayname, preferences: component.notifications.map {
                        MoodleNotificationMatrix.Preference(
                            key: $0.preferencekey,
                            name: $0.displayname,
                            processors: $0.processors.map(\.name),
                            enabled: Set($0.processors.filter(\.enabled).map(\.name)),
                            locked: Set($0.processors.filter(\.locked).map(\.name))
                        )
                    })
                },
                disablesAll: disableall != 0
            )
        }
    }

    let preferences: Preferences
}

private nonisolated struct RawWriteAnswer: Decodable, Sendable {
    struct Warning: Decodable, Sendable {
        let warningcode: String?
    }

    let warnings: [Warning]?
}
