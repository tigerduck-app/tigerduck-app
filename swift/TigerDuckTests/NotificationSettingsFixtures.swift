import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
enum NotificationSettingsFixtures {

    static func withStore(
        _ body: (LiveActivityPreferencesStore) async throws -> Void
    ) async rethrows {
        try await withExclusiveRealDefaults {
            let savedOffsets = Defaults[.assignmentReminderOffsetsData]
            let savedEnabled = Defaults[.isAssignmentReminderEnabled]
            let savedLiveActivity = Defaults[.isLiveActivityEnabled]
            let savedAssignmentLead = Defaults[.assignmentLiveActivityLeadTime]
            let savedClassLead = Defaults[.classPreparingLeadTime]
            let savedShowAssignment = Defaults[.showAssignmentScenario]
            let savedShowClassPreparing = Defaults[.showClassPreparingScenario]
            let savedShowInClass = Defaults[.showInClassScenario]
            let savedClassReminder = Defaults[.isClassReminderEnabled]
            let savedClassReminderLead = Defaults[.classReminderLeadMinutes]
            let savedPicked = Defaults[.hasPickedClassReminderLead]
            defer {
                Defaults[.assignmentReminderOffsetsData] = savedOffsets
                Defaults[.isAssignmentReminderEnabled] = savedEnabled
                Defaults[.isLiveActivityEnabled] = savedLiveActivity
                Defaults[.assignmentLiveActivityLeadTime] = savedAssignmentLead
                Defaults[.classPreparingLeadTime] = savedClassLead
                Defaults[.showAssignmentScenario] = savedShowAssignment
                Defaults[.showClassPreparingScenario] = savedShowClassPreparing
                Defaults[.showInClassScenario] = savedShowInClass
                Defaults[.isClassReminderEnabled] = savedClassReminder
                Defaults[.classReminderLeadMinutes] = savedClassReminderLead
                Defaults[.hasPickedClassReminderLead] = savedPicked
            }
            Defaults[.hasPickedClassReminderLead] = false
            try await body(LiveActivityPreferencesStore())
        }
    }

    static func documentURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("settings/notification")
    }

    static func notFound() -> SettingsAPIStub.StubResponse {
        .init(statusCode: 404, body: Data())
    }

    static func found(_ document: [String: Any], revision: Int) throws -> SettingsAPIStub.StubResponse {
        .init(
            statusCode: 200,
            body: try JSONSerialization.data(withJSONObject: ["document": document, "revision": revision])
        )
    }

    static func written(revision: Int) throws -> SettingsAPIStub.StubResponse {
        .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: ["revision": revision]))
    }

    static func conflict(_ document: [String: Any], revision: Int) throws -> SettingsAPIStub.StubResponse {
        let server: [String: Any] = ["document": document, "revision": revision]
        return .init(statusCode: 409, body: try JSONSerialization.data(withJSONObject: ["server": server]))
    }

    static func sentEnvelope(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(SettingsAPIStub.bodyData(from: request))
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    static func sentDocument(_ request: URLRequest) throws -> [String: Any] {
        try #require(try sentEnvelope(request)["document"] as? [String: Any])
    }
}
