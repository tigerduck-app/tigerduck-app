import Foundation
import Testing
@testable import TigerDuck

@Suite("Notification settings document")
struct NotificationSettingsDocumentTests {

    @Test("decodes the shape the backend already stores")
    func decodesBackendShape() throws {
        let json = Data("""
        {"assignments":{"enabled":true,"reminder_offsets_hours":[24,2]},
         "courses":{"enabled":true,"reminder_offsets_minutes":[10]}}
        """.utf8)
        let doc = try JSONDecoder().decode(NotificationSettingsDocument.self, from: json)
        #expect(doc.assignments.enabled == true)
        #expect(doc.assignments.reminderOffsetsHours == [24, 2])
        #expect(doc.courses.reminderOffsetsMinutes == [10])
    }

    @Test("a document written before live_activity existed still decodes")
    func decodesWithoutLiveActivity() throws {
        // The backend has been reading `assignments` and `courses` since
        // phase 4a. Any user who has synced before this ships has a document
        // with no live_activity key, and it must not fail to decode.
        let json = Data("""
        {"assignments":{"enabled":true,"reminder_offsets_hours":[24]},
         "courses":{"enabled":false,"reminder_offsets_minutes":[]}}
        """.utf8)
        let doc = try JSONDecoder().decode(NotificationSettingsDocument.self, from: json)
        #expect(doc.liveActivity == nil)
    }

    @Test("round-trips through encode without losing or inventing keys")
    func roundTrips() throws {
        let doc = NotificationSettingsDocument(
            assignments: .init(enabled: true, reminderOffsetsHours: [48, 24, 2]),
            courses: .init(enabled: true, reminderOffsetsMinutes: [10]),
            liveActivity: .init(
                showClassPreparing: true, showInClass: false, showAssignment: true,
                classPreparingLeadSeconds: 3600, assignmentLeadSeconds: 28800
            )
        )
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(NotificationSettingsDocument.self, from: data)
        #expect(back == doc)

        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(object.keys) == ["assignments", "courses", "live_activity"])
    }

    @Test("unknown keys the server adds later survive a read")
    func unknownKeysDoNotThrow() throws {
        // A newer client may add a section this build does not know about.
        // Decoding must not fail; the write path is separately responsible
        // for not clobbering it (see the conflict test in the client suite).
        let json = Data("""
        {"assignments":{"enabled":true,"reminder_offsets_hours":[24]},
         "courses":{"enabled":true,"reminder_offsets_minutes":[10]},
         "something_new":{"x":1}}
        """.utf8)
        _ = try JSONDecoder().decode(NotificationSettingsDocument.self, from: json)
    }
}
