// Wire keys of the device DTOs in `PushAPIDTO.swift`. A property left out of `CodingKeys` is
// silently never encoded or decoded, and a round trip through the same type cannot see that,
// so these tests assert against raw JSON instead.
import Foundation
import Testing
@testable import TigerDuck

@Suite("Push API device preferences DTOs")
struct PushAPIDTOTests {

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
        let request = PushAPI.DevicePreferencesRequest(serverPushEnabled: true)
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["bulletin_push_enabled"] == nil)
    }

    @Test("decoding sync_assignment_reminders and sync_live_activity from the wire populates both properties")
    func responseDecodesNewFieldsFromTheirWireKeys() throws {
        let response = try JSONDecoder().decode(
            PushAPI.DevicePreferencesResponse.self, from: Self.preferencesReply(#""sync_assignment_reminders": false"#)
        )

        #expect(response.syncAssignmentReminders == false)
        #expect(response.syncLiveActivity == true)
    }

    @Test("a preferences reply without one of the device's switches does not decode, as /v4 sends them all")
    func aReplyWithoutASwitchDoesNotDecode() {
        for key in ["sync_assignment_reminders", "sync_live_activity", "bulletin_push_enabled"] {
            let json = Data(String(decoding: Self.preferencesReply(), as: UTF8.self)
                .replacingOccurrences(of: #""\#(key)": true,"#, with: "").utf8)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(PushAPI.DevicePreferencesResponse.self, from: json)
            }
        }
    }

    @Test("a course override reply without ignore_assignments does not decode, so the outbox keeps the edit")
    func aCourseOverrideReplyWithoutTheIgnoreFlagDoesNotDecode() throws {
        let full = Data(#"{"color_hex":null,"custom_names":{},"ignore_assignments":true,"applied":[]}"#.utf8)
        #expect(try JSONDecoder().decode(PushAPI.CourseOverrideResponse.self, from: full).ignoreAssignments)
        let missing = Data(#"{"color_hex":null,"custom_names":{},"applied":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PushAPI.CourseOverrideResponse.self, from: missing)
        }
    }

    private static func preferencesReply(_ override: String? = nil) -> Data {
        var fields = [
            #""device_id": "abc-123""#, #""server_push_enabled": true"#, #""sync_courses": true"#,
            #""sync_course_colors": true"#, #""sync_course_names": true"#, #""sync_assignments": true"#,
            #""sync_assignment_reminders": true"#, #""sync_live_activity": true"#, #""bulletin_push_enabled": true"#,
            #""cloud_sync_enabled": true"#,
        ]
        if let override, let key = override.split(separator: ":").first {
            fields = fields.map { $0.hasPrefix(key + ":") ? override : $0 }
        }
        return Data("{\(fields.joined(separator: ", "))}".utf8)
    }

    @Test("decoding bulletin_push_enabled from the wire populates bulletinPushEnabled")
    func responseDecodesBulletinPushEnabledFromItsWireKey() throws {
        let response = try JSONDecoder().decode(
            PushAPI.DevicePreferencesResponse.self, from: Self.preferencesReply(#""bulletin_push_enabled": false"#)
        )

        #expect(response.bulletinPushEnabled == false)
    }

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
            server_push_enabled: nil,
            device_secret: nil
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
            server_push_enabled: true,
            device_secret: nil
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
            server_push_enabled: nil,
            device_secret: nil
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["device_model"] as? String == "iPhone17,3")
    }

    @Test("encoding the device secret on both device requests produces device_secret, and none leaves it out")
    func deviceRequestsEncodeTheSecretToItsWireKey() throws {
        func encoded(_ secret: String?) throws -> (anonymous: [String: Any], register: [String: Any]) {
            let anonymous = PushAPI.AnonymousDeviceRequest(
                device_id: "device-1", platform: "apple", device_class: "iphone", push_token: nil,
                bundle_id: "org.ntust.app.TigerDuck", server_push_enabled: nil, device_secret: secret
            )
            let register = PushAPI.DeviceRegisterRequest(
                client_device_id: "device-1", platform: "ios", device_class: nil, app_version: nil,
                os_version: nil, device_model: nil, locale: nil, push_token: nil, cloud_sync_enabled: nil,
                bulletin_push_enabled: nil, server_push_enabled: nil, device_secret: secret
            )
            return try (
                #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(anonymous)) as? [String: Any]),
                #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(register)) as? [String: Any])
            )
        }

        let withSecret = try encoded("secret-1")
        let without = try encoded(nil)

        #expect(withSecret.anonymous["device_secret"] as? String == "secret-1")
        #expect(withSecret.register["device_secret"] as? String == "secret-1")
        #expect(without.anonymous["device_secret"] == nil)
        #expect(without.register["device_secret"] == nil)
    }
}
