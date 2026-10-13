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
        for preset in VisualPreset.allCases {
            let snapshot = WatchSnapshot(
                courses: [sampleCourse()],
                accentHex: "#FF8800",
                syncedAtMs: 1,
                loggedIn: true,
                languageTag: nil,
                visualPreset: preset
            )
            let dict = try WatchPayloadCodec.encode(snapshot)
            let decoded = try WatchPayloadCodec.decode(dict)
            XCTAssertEqual(decoded.visualPreset, preset)
        }
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

    /// A newer phone can send a preset this Watch build does not know.
    func test_decode_unknownVisualPreset_defaultsToTigerDuck() throws {
        var dict = try WatchPayloadCodec.encode(sampleSnapshot())
        dict[WatchWireFormat.Key.visualPreset] = "someFuturePreset"
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertEqual(decoded.visualPreset, .default)
        XCTAssertEqual(decoded.courses, sampleSnapshot().courses)
    }

    func test_jsonDecode_legacyDiskCacheWithoutVisualPreset_succeeds() throws {
        // `ScheduleStore.loadFromDisk()` decodes with `JSONDecoder`, not `WatchPayloadCodec`,
        // and synthesised `Codable` ignores the init's defaults. A cache from before `visualPreset`
        // must still decode, or the upgraded watch shows its empty state until a fresh WC push.
        let legacyJSON = """
        {
            "version": 1,
            "courses": [],
            "accentHex": "#FF8800",
            "syncedAtMs": 1747000000000,
            "loggedIn": true,
            "languageTag": "zh-Hant-TW"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: legacyJSON)
        XCTAssertEqual(decoded.visualPreset, .default)
        XCTAssertNil(decoded.clockOverrideJSON)
        XCTAssertEqual(decoded.quietDays, [])
    }

    func test_quietDaysAndSkippedDates_roundTrip() throws {
        let course = WatchCourse(
            id: "X1-1-3", courseNo: "X1", name: "Algorithms", teacher: "",
            classroom: "TR-313", colorHex: "#FF8800", weekday: 1,
            startHHmm: "10:20", endHHmm: "12:10", periodLabel: "3-4",
            skippedDates: ["2026-05-11"]
        )
        let snapshot = WatchSnapshot(
            courses: [course], accentHex: "#FF8800", syncedAtMs: 1,
            loggedIn: true, languageTag: nil, quietDays: ["2026-10-09", "2026-10-10"]
        )
        let decoded = try WatchPayloadCodec.decode(WatchPayloadCodec.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    /// A phone that sends neither key, or a payload with none to send, decodes to no holidays
    /// and no skipped days.
    func test_decode_withoutQuietDaysOrSkippedDates_hasNone() throws {
        let dict = try WatchPayloadCodec.encode(sampleSnapshot())
        XCTAssertNil(dict[WatchWireFormat.Key.quietDays])
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertEqual(decoded.quietDays, [])
        XCTAssertNil(decoded.courses.first?.skippedDates)
    }
}
