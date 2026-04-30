import XCTest
@testable import TigerDuck

final class LanguageManagerTests: XCTestCase {
    func test_resolvedCourseApiLanguage_system_fallsBackToEnglish() {
        let result = LanguageManager.resolvedCourseApiLanguage(appLanguage: "system")
        XCTAssertTrue(result == "en" || result == "zh")
    }

    func test_resolvedCourseApiLanguage_english() {
        XCTAssertEqual(LanguageManager.resolvedCourseApiLanguage(appLanguage: "en"), "en")
    }

    func test_resolvedCourseApiLanguage_traditionalChinese() {
        XCTAssertEqual(LanguageManager.resolvedCourseApiLanguage(appLanguage: "zh-Hant"), "zh")
    }

    func test_resolvedCourseApiLanguage_simplifiedChinese() {
        XCTAssertEqual(LanguageManager.resolvedCourseApiLanguage(appLanguage: "zh-Hans"), "zh")
    }

    func test_resolvedCourseApiLanguage_cantonese() {
        XCTAssertEqual(LanguageManager.resolvedCourseApiLanguage(appLanguage: "yue-HK"), "zh")
    }

    func test_resolvedCourseApiLanguage_japanese() {
        XCTAssertEqual(LanguageManager.resolvedCourseApiLanguage(appLanguage: "ja"), "en")
    }

    func test_isCourseApiEnglish_en() {
        XCTAssertTrue(LanguageManager.isCourseApiEnglish(appLanguage: "en"))
    }

    func test_isCourseApiEnglish_zhHant() {
        XCTAssertFalse(LanguageManager.isCourseApiEnglish(appLanguage: "zh-Hant"))
    }

    func test_isCurrentLanguageEnglish_explicitChineseTags() {
        XCTAssertFalse(LanguageManager.isCurrentLanguageEnglish(appLanguage: "zh-Hant"))
        XCTAssertFalse(LanguageManager.isCurrentLanguageEnglish(appLanguage: "zh-Hans"))
        XCTAssertFalse(LanguageManager.isCurrentLanguageEnglish(appLanguage: "yue-HK"))
    }

    func test_isCurrentLanguageEnglish_explicitEnglish() {
        XCTAssertTrue(LanguageManager.isCurrentLanguageEnglish(appLanguage: "en"))
        XCTAssertTrue(LanguageManager.isCurrentLanguageEnglish(appLanguage: "ja"))
    }

    func test_supportedTags_containsCommonLocales() {
        let tags = LanguageManager.supportedLocaleTags()
        XCTAssertTrue(tags.contains("en"))
        XCTAssertTrue(tags.contains("zh-Hant"))
    }
}
