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
        #expect(doc.assignments?.enabled == true)
        #expect(doc.assignments?.reminderOffsetsHours == [24, 2])
        #expect(doc.courses?.reminderOffsetsMinutes == [10])
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

    @Test("every section and every field is optional, so no partial document fails to decode")
    func decodesEveryPartialShape() throws {
        // Three clients write this namespace and the route validates
        // nothing (`SettingsPut.document: dict`). A non-Optional property
        // anywhere in this type turns one of these into a
        // `DecodingError.keyNotFound`, and on the push path that is an
        // abort with only a log line, repeated on every attempt forever.
        let shapes = [
            // Android's first write (spec W6): `live_activity` only.
            #"{"live_activity":{"show_in_class":true,"show_assignment":false,"show_class_preparing":true,"class_preparing_lead_seconds":3600,"assignment_lead_seconds":28800}}"#,
            // A section present but half-populated.
            #"{"assignments":{"enabled":true}}"#,
            #"{"assignments":{"reminder_offsets_hours":[24]}}"#,
            #"{"courses":{"enabled":true}}"#,
            #"{"live_activity":{"show_in_class":true}}"#,
            // Nothing at all.
            "{}",
        ]
        for shape in shapes {
            #expect(throws: Never.self) {
                _ = try JSONDecoder().decode(NotificationSettingsDocument.self, from: Data(shape.utf8))
            }
        }

        // And an absent field reads as absent, not as a default that would
        // overwrite the local value on a pull.
        let partial = try JSONDecoder().decode(
            NotificationSettingsDocument.self,
            from: Data(#"{"assignments":{"enabled":true}}"#.utf8)
        )
        #expect(partial.assignments?.enabled == true)
        #expect(partial.assignments?.reminderOffsetsHours == nil)
        #expect(partial.assignments?.reminderOffsetsMinutes == nil)
        #expect(partial.courses == nil)
    }

    @Test("round-trips through encode without losing or inventing keys")
    func roundTrips() throws {
        let doc = NotificationSettingsDocument(
            assignments: .init(enabled: true, reminderOffsetsHours: [48, 24, 2], reminderOffsetsMinutes: [2880, 1440, 120]),
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

        let assignments = try #require(object["assignments"] as? [String: Any])
        #expect(Set(assignments.keys) == ["enabled", "reminder_offsets_hours", "reminder_offsets_minutes"])
    }

    @Test("unknown keys the server adds later survive a read")
    func unknownKeysDoNotThrow() throws {
        // A newer client — or Android, which shares this namespace — may
        // add a section this build does not know about. Decoding must not
        // fail. Preserving it across a *write* is a separate guarantee,
        // provided by the JSON-level merge in
        // `NotificationSettingsSync.push` and pinned by
        // `NotificationSettingsSyncTests.pushPreservesUnknownKeys`.
        let json = Data("""
        {"assignments":{"enabled":true,"reminder_offsets_hours":[24]},
         "courses":{"enabled":true,"reminder_offsets_minutes":[10]},
         "something_new":{"x":1}}
        """.utf8)
        _ = try JSONDecoder().decode(NotificationSettingsDocument.self, from: json)
    }
}
