import XCTest
@testable import TigerDuckWatch_Watch_App

final class WatchPayloadCodecTests: XCTestCase {

    private func sampleCourse() -> WatchCourse {
        WatchCourse(
            id: "1142EC1013701-1-3",
            courseNo: "1142EC1013701",
            name: "資料結構",
            teacher: "張教授",
            classroom: "TR-313",
            colorHex: "#FF8800",
            weekday: 1,
            startHHmm: "10:20",
            endHHmm: "11:10",
            periodLabel: "3-4"
        )
    }

    private func sampleSnapshot() -> WatchSnapshot {
        WatchSnapshot(
            courses: [sampleCourse()],
            accentHex: "#FF8800",
            syncedAtMs: 1_747_000_000_000,
            loggedIn: true,
            languageTag: "zh-Hant-TW"
        )
    }

    func test_roundTrip_preservesAllFields() throws {
        let snapshot = sampleSnapshot()
        let dict = try WatchPayloadCodec.encode(snapshot)
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertEqual(snapshot, decoded)
    }

    func test_decode_missingOptionalLanguageTag_succeeds() throws {
        var dict = try WatchPayloadCodec.encode(sampleSnapshot())
        dict.removeValue(forKey: WatchWireFormat.Key.languageTag)
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertNil(decoded.languageTag)
    }

    func test_decode_missingRequiredCourses_throws() {
        var dict = try! WatchPayloadCodec.encode(sampleSnapshot())
        dict.removeValue(forKey: WatchWireFormat.Key.courses)
        XCTAssertThrowsError(try WatchPayloadCodec.decode(dict))
    }

    func test_decode_unknownFutureVersion_stillDecodes() throws {
        var dict = try WatchPayloadCodec.encode(sampleSnapshot())
        dict[WatchWireFormat.Key.version] = 99
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertEqual(decoded.courses.count, 1)
        XCTAssertEqual(decoded.version, 99)
    }

    func test_visualPreset_roundTrips() throws {
        let snapshot = WatchSnapshot(
            courses: [sampleCourse()],
            accentHex: "#FF8800",
            syncedAtMs: 1,
            loggedIn: true,
            languageTag: nil,
            visualPreset: .iosInspired
        )
        let dict = try WatchPayloadCodec.encode(snapshot)
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertEqual(decoded.visualPreset, .iosInspired)
    }

    func test_decode_missingVisualPreset_defaultsToTigerDuck() throws {
        var dict = try WatchPayloadCodec.encode(sampleSnapshot())
        dict.removeValue(forKey: WatchWireFormat.Key.visualPreset)
        let decoded = try WatchPayloadCodec.decode(dict)
        // Older phones don't send the field; the watch must keep the
        // default TigerDuck look rather than drifting to an Apple-style
        // surface unintentionally.
        XCTAssertEqual(decoded.visualPreset, .default)
    }
}
