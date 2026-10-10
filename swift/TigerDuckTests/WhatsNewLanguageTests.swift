// `WhatsNewLanguage` and `WhatsNewText`: What's New is written in Traditional Chinese
// and English only. Every Chinese-family language reads zh-Hant and everything else
// reads English, the same split the `whatsnew.json` summary uses.
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WhatsNewLanguageTests {
    @Test(arguments: ["zh-Hant-TW", "zh_TW", "zh-Hans-CN", "zh-HK", "yue-Hant-HK", "nan-TW", "hak", "wuu", "lzh"])
    func chineseFamilyReadsTraditionalChinese(tag: String) {
        #expect(WhatsNewLanguage(languageTag: tag) == .zhHant)
    }

    @Test(arguments: ["en", "en-US", "en_TW", "ja-JP", "ko-KR", "vi-VN", "fr-FR", ""])
    func everythingElseReadsEnglish(tag: String) {
        #expect(WhatsNewLanguage(languageTag: tag) == .en)
    }

    @Test func textResolvesToItsLanguage() {
        let text = WhatsNewText(en: "Reset", zhHant: "恢復預設")
        #expect(text.resolved(for: .en) == "Reset")
        #expect(text.resolved(for: .zhHant) == "恢復預設")
    }
}
