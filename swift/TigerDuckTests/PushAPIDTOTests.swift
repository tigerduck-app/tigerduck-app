// `PushAPI.DevicePreferencesRequest` / `DevicePreferencesResponse`
// (PushAPIDTO.swift) — specifically the two device-preference fields Task 4
// adds, `syncAssignmentReminders` / `syncLiveActivity`, wired to the wire
// keys `sync_assignment_reminders` / `sync_live_activity`.
//
// Swift's synthesized `Decodable` only decodes keys an explicit
// `CodingKeys` enum names, and a plain `Encodable` only *emits* keys
// `CodingKeys` names — omitting a case produces no error and no warning,
// the field simply never appears on the wire. A test that round-trips
// through this struct's own `Codable` conformance (encode, then decode
// back into the same type) would pass whether or not a case is declared,
// since the same key name is missing on both sides. These tests therefore
// assert against the raw encoded JSON object / raw JSON input, which is
// the only way to observe whether a wire key is actually there — the same
// technique `NotificationSettingsDocumentTests.roundTrips()` uses.
import Foundation
import Testing
@testable import TigerDuck

@Suite("Push API device preferences DTOs")
struct PushAPIDTOTests {

    // MARK: - Request: encodes to the wire keys the backend expects

    @Test("encoding syncAssignmentReminders and syncLiveActivity produces their snake_case wire keys")
    func requestEncodesNewFieldsToTheirWireKeys() throws {
        let request = PushAPI.DevicePreferencesRequest(
            syncAssignmentReminders: true,
            syncLiveActivity: false
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // Asserting against the raw JSON object, not a re-decoded
        // `DevicePreferencesRequest` — a missing `CodingKeys` case drops
        // the field from `object` with no error, which a round trip
        // through the struct itself could never observe (both sides would
        // agree on the same wrong, or missing, key).
        #expect(object["sync_assignment_reminders"] as? Bool == true)
        #expect(object["sync_live_activity"] as? Bool == false)
    }

    @Test("omitted syncAssignmentReminders/syncLiveActivity do not appear on the wire at all")
    func requestOmitsNilNewFieldsEntirely() throws {
        // A PATCH that only changes, say, `serverPushEnabled` must not send
        // `sync_assignment_reminders`/`sync_live_activity` as an explicit
        // `null` — that would tell the backend to clear a preference the
        // caller never touched.
        let request = PushAPI.DevicePreferencesRequest(serverPushEnabled: true)
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["sync_assignment_reminders"] == nil)
        #expect(object["sync_live_activity"] == nil)
        #expect(object["server_push_enabled"] as? Bool == true)
    }

    // MARK: - Response: decodes the wire keys the backend actually sends

    @Test("decoding sync_assignment_reminders and sync_live_activity from the wire populates both properties")
    func responseDecodesNewFieldsFromTheirWireKeys() throws {
        // Shape the backend actually returns (both fields non-null, per
        // the `server_default` of migration `07b22743e0f1`).
        let json = Data("""
        {
          "device_id": "abc-123",
          "server_push_enabled": true,
          "sync_courses": true,
          "sync_course_colors": true,
          "sync_course_names": true,
          "sync_assignments": true,
          "sync_assignment_reminders": false,
          "sync_live_activity": true,
          "cloud_sync_enabled": true
        }
        """.utf8)

        let response = try JSONDecoder().decode(PushAPI.DevicePreferencesResponse.self, from: json)

        #expect(response.syncAssignmentReminders == false)
        #expect(response.syncLiveActivity == true)
    }

    @Test("a response from a backend without the two fields still decodes")
    func responseWithoutNewFieldsStillDecodes() throws {
        // A backend without the columns — rolled back, or self-hosted —
        // answers the preferences PATCH without them. The client never
        // reads them, so their absence must not turn a change the server
        // applied into a reported failure.
        let json = Data("""
        {
          "device_id": "abc-123",
          "server_push_enabled": true,
          "sync_courses": true,
          "sync_course_colors": true,
          "sync_course_names": true,
          "sync_assignments": true,
          "cloud_sync_enabled": false
        }
        """.utf8)

        let response = try JSONDecoder().decode(PushAPI.DevicePreferencesResponse.self, from: json)

        #expect(response.syncAssignmentReminders == nil)
        #expect(response.syncLiveActivity == nil)
        #expect(response.cloudSyncEnabled == false)
    }
}
