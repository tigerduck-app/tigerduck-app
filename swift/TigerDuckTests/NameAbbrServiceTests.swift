import XCTest
@testable import TigerDuck

final class NameAbbrServiceTests: XCTestCase {
    // After Task 1 + Xcode bundle step, the JSON files are in the app bundle.
    // These tests verify the service can load and apply abbreviations.

    func test_abbreviateName_unknownName_returnsOriginal() {
        let svc = NameAbbrService.shared
        let result = svc.abbreviateName("A Completely Made Up Course Name XYZ123")
        XCTAssertEqual(result, "A Completely Made Up Course Name XYZ123")
    }

    func test_abbreviateName_knownName_returnsShortened() {
        // ".NET Programming" → ".NET Prog" per class-name-abbr.json
        let svc = NameAbbrService.shared
        let result = svc.abbreviateName(".NET Programming")
        XCTAssertEqual(result, ".NET Prog")
    }

    func test_abbreviateClassroom_alphanumericRoom_returnsUnchanged() {
        // "TR-313" has no Mandarin, short = "TR-313"; should be returned as-is
        let svc = NameAbbrService.shared
        let result = svc.abbreviateClassroom("TR-313", display: "original")
        XCTAssertEqual(result, "TR-313")
    }

    func test_abbreviateClassroom_mandarinRoom_originalDisplay() {
        // "115研討室" → shortened_name = "115研討室"
        let svc = NameAbbrService.shared
        let result = svc.abbreviateClassroom("115研討室", display: "original")
        XCTAssertEqual(result, "115研討室")
    }

    func test_abbreviateClassroom_mandarinRoom_pinyinDisplay() {
        // "115研討室" → pinyin = "115 Yan Tao Shi"
        let svc = NameAbbrService.shared
        let result = svc.abbreviateClassroom("115研討室", display: "pinyin")
        XCTAssertEqual(result, "115 Yan Tao Shi")
    }

    func test_abbreviateClassroom_mandarinRoom_translatedDisplay() {
        // "115研討室" → translated = "115 Seminar Room"
        let svc = NameAbbrService.shared
        let result = svc.abbreviateClassroom("115研討室", display: "translated")
        XCTAssertEqual(result, "115 Seminar Room")
    }

    func test_abbreviateClassroom_multipleRooms_eachAbbreviated() {
        let svc = NameAbbrService.shared
        let result = svc.abbreviateClassroom("TR-313, 115研討室", display: "translated")
        XCTAssertEqual(result, "TR-313, 115 Seminar Room")
    }

    func test_rawNameCacheRoundtrip() {
        let svc = NameAbbrService.shared
        svc.storeRawName(courseNo: "EC1013701", name: "Calculus (I)")
        XCTAssertEqual(svc.rawName(for: "EC1013701"), "Calculus (I)")
        svc.clearRawNameCache()
        XCTAssertNil(svc.rawName(for: "EC1013701"))
    }
}
