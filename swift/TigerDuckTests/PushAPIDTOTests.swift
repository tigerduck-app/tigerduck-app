// Wire keys of the device DTOs in `PushAPIDTO.swift`. A property left out of `CodingKeys` is
// silently never encoded or decoded, and a round trip through the same type cannot see that,
// so these tests assert against raw JSON instead.
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

        #expect(object["sync_assignment_reminders"] as? Bool == true)
        #expect(object["sync_live_activity"] as? Bool == false)
    }

    @Test("omitted syncAssignmentReminders/syncLiveActivity do not appear on the wire at all")
    func requestOmitsNilNewFieldsEntirely() throws {
        // A PATCH that only changes `serverPushEnabled` must not send these keys, not even as
        // `null`; `requestOmitsNilBulletinPushEnabledEntirely` below says why.
        let request = PushAPI.DevicePreferencesRequest(serverPushEnabled: true)
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["sync_assignment_reminders"] == nil)
        #expect(object["sync_live_activity"] == nil)
        #expect(object["server_push_enabled"] as? Bool == true)
    }

    @Test("encoding bulletinPushEnabled produces the bulletin_push_enabled wire key")
    func requestEncodesBulletinPushEnabledToItsWireKey() throws {
        let request = PushAPI.DevicePreferencesRequest(bulletinPushEnabled: false)
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["bulletin_push_enabled"] as? Bool == false)
    }

    @Test("omitted bulletinPushEnabled does not appear on the wire at all")
    func requestOmitsNilBulletinPushEnabledEntirely() throws {
        // `server/routes/user_devices.py` treats `null` as unchanged, like an absent key, but a
        // PATCH body names only what the caller changed, and a `null` that today's handler
        // happens to ignore is not that.
        let request = PushAPI.DevicePreferencesRequest(serverPushEnabled: true)
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["bulletin_push_enabled"] == nil)
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
        // A backend without these columns (rolled back, or self-hosted) leaves them out of its
        // PATCH answer. The client never reads them, so their absence must not turn a change the
        // server applied into a reported failure.
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

    @Test("decoding bulletin_push_enabled from the wire populates bulletinPushEnabled")
    func responseDecodesBulletinPushEnabledFromItsWireKey() throws {
        let json = Data("""
        {
          "device_id": "abc-123",
          "server_push_enabled": true,
          "sync_courses": true,
          "sync_course_colors": true,
          "sync_course_names": true,
          "sync_assignments": true,
          "cloud_sync_enabled": true,
          "bulletin_push_enabled": false
        }
        """.utf8)

        let response = try JSONDecoder().decode(PushAPI.DevicePreferencesResponse.self, from: json)

        #expect(response.bulletinPushEnabled == false)
    }

    @Test("a response without bulletin_push_enabled still decodes, leaving the field nil")
    func responseWithoutBulletinPushEnabledStillDecodes() throws {
        // Like the two sync fields above: a backend without the column (rolled back, or
        // self-hosted) omits it, which must not turn an applied change into a decode failure.
        let json = Data("""
        {
          "device_id": "abc-123",
          "server_push_enabled": true,
          "sync_courses": true,
          "sync_course_colors": true,
          "sync_course_names": true,
          "sync_assignments": true,
          "cloud_sync_enabled": true
        }
        """.utf8)

        let response = try JSONDecoder().decode(PushAPI.DevicePreferencesResponse.self, from: json)

        #expect(response.bulletinPushEnabled == nil)
    }

    // MARK: - Register request: fields carried on every signed-in register
    // call so a migrated value or a PATCH the server missed self-heals on
    // the next launch, the way `cloud_sync_enabled` already does.

    @Test("encoding bulletin_push_enabled on the register request produces its wire key")
    func deviceRegisterRequestEncodesBulletinPushEnabledToItsWireKey() throws {
        let request = PushAPI.DeviceRegisterRequest(
            client_device_id: "device-1",
            platform: "ios",
            device_class: nil,
            app_version: nil,
            os_version: nil,
            device_model: nil,
            locale: nil,
            push_token: nil,
            cloud_sync_enabled: nil,
            bulletin_push_enabled: false,
            server_push_enabled: nil
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["bulletin_push_enabled"] as? Bool == false)
    }

    @Test("encoding server_push_enabled on the register request produces its wire key")
    func deviceRegisterRequestEncodesServerPushEnabledToItsWireKey() throws {
        let request = PushAPI.DeviceRegisterRequest(
            client_device_id: "device-1",
            platform: "ios",
            device_class: nil,
            app_version: nil,
            os_version: nil,
            device_model: nil,
            locale: nil,
            push_token: nil,
            cloud_sync_enabled: nil,
            bulletin_push_enabled: nil,
            server_push_enabled: true
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["server_push_enabled"] as? Bool == true)
    }

    @Test("encoding device_model on the register request produces its wire key")
    func deviceRegisterRequestEncodesDeviceModelToItsWireKey() throws {
        let request = PushAPI.DeviceRegisterRequest(
            client_device_id: "device-1",
            platform: "ios",
            device_class: nil,
            app_version: nil,
            os_version: nil,
            device_model: "iPhone17,3",
            locale: nil,
            push_token: nil,
            cloud_sync_enabled: nil,
            bulletin_push_enabled: nil,
            server_push_enabled: nil
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["device_model"] as? String == "iPhone17,3")
    }
}
