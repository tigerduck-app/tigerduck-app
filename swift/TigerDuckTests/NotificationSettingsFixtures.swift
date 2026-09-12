// Fixtures shared by the suites that drive `NotificationSettingsSync.reconcile`
// against a real `LiveActivityPreferencesStore` and `SettingsAPIStub`:
// `NotificationSettingsReconcileTests`, `NotificationSettingsSeedMigrationTests`
// and the read tests in `NotificationSettingsPushQueueTests`.
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
enum NotificationSettingsFixtures {

    /// Runs `body` with a fresh store, restoring every `Defaults` key the
    /// store touches afterwards — the async twin of
    /// `NotificationSettingsApplyTests.withStore`.
    static func withStore(
        _ body: (LiveActivityPreferencesStore) async throws -> Void
    ) async rethrows {
        let savedOffsets = Defaults[.assignmentReminderOffsetsData]
        let savedEnabled = Defaults[.isAssignmentReminderEnabled]
        let savedLiveActivity = Defaults[.isLiveActivityEnabled]
        let savedAssignmentLead = Defaults[.assignmentLiveActivityLeadTime]
        let savedClassLead = Defaults[.classPreparingLeadTime]
        let savedShowAssignment = Defaults[.showAssignmentScenario]
        let savedShowClassPreparing = Defaults[.showClassPreparingScenario]
        let savedShowInClass = Defaults[.showInClassScenario]
        defer {
            Defaults[.assignmentReminderOffsetsData] = savedOffsets
            Defaults[.isAssignmentReminderEnabled] = savedEnabled
            Defaults[.isLiveActivityEnabled] = savedLiveActivity
            Defaults[.assignmentLiveActivityLeadTime] = savedAssignmentLead
            Defaults[.classPreparingLeadTime] = savedClassLead
            Defaults[.showAssignmentScenario] = savedShowAssignment
            Defaults[.showClassPreparingScenario] = savedShowClassPreparing
            Defaults[.showInClassScenario] = savedShowInClass
        }
        try await body(LiveActivityPreferencesStore())
    }

    static func documentURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("settings/notification")
    }

    /// A `GET` that finds no document: the account has never written one.
    static func notFound() -> SettingsAPIStub.StubResponse {
        .init(statusCode: 404, body: Data())
    }

    /// A successful `GET` — `{"document": ..., "revision": ...}`.
    static func found(_ document: [String: Any], revision: Int) throws -> SettingsAPIStub.StubResponse {
        .init(
            statusCode: 200,
            body: try JSONSerialization.data(withJSONObject: ["document": document, "revision": revision])
        )
    }

    /// A successful `PUT` — just the new revision.
    static func written(revision: Int) throws -> SettingsAPIStub.StubResponse {
        .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: ["revision": revision]))
    }

    /// A `409` — `{"server": {"document": ..., "revision": ...}}`.
    static func conflict(_ document: [String: Any], revision: Int) throws -> SettingsAPIStub.StubResponse {
        let server: [String: Any] = ["document": document, "revision": revision]
        return .init(statusCode: 409, body: try JSONSerialization.data(withJSONObject: ["server": server]))
    }

    /// The envelope a `PUT` actually sent.
    static func sentEnvelope(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(SettingsAPIStub.bodyData(from: request))
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// The `document` a `PUT` actually sent, as a raw dictionary — the only
    /// view that shows keys the typed document has no property for.
    static func sentDocument(_ request: URLRequest) throws -> [String: Any] {
        try #require(try sentEnvelope(request)["document"] as? [String: Any])
    }
}
