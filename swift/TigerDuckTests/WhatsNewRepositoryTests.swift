// `WhatsNewRepository`, decoding the `whatsnew.json` summary: item rows, the legacy
// `highlights` list, the blanks the selector filters out, and the locale fallback.
// Drives the static selector directly, plus one check that the bundled JSON decodes.
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WhatsNewRepositoryTests {
    @Test func itemRowsDecodeWithTheirSymbolTitleAndBody() throws {
        let entry = try #require(select("""
        { "en": { "title": "What's new", "items": [
            { "symbol": "envelope.fill", "title": "School Mail", "body": "Read your NTUST mail." }
        ] } }
        """))
        #expect(entry.title == "What's new")
        #expect(entry.items == [.init(symbol: "envelope.fill", title: "School Mail", body: "Read your NTUST mail.")])
    }

    @Test func legacyHighlightsBecomeBodyOnlyRows() throws {
        let entry = try #require(select("""
        { "en": { "title": "What's new", "highlights": ["One.", "Two."] } }
        """))
        #expect(entry.items == [
            .init(symbol: nil, title: nil, body: "One."),
            .init(symbol: nil, title: nil, body: "Two."),
        ])
    }

    @Test func itemsWinOverHighlights() throws {
        let entry = try #require(select("""
        { "en": { "title": "T", "items": [{ "title": "Row" }], "highlights": ["Old."] } }
        """))
        #expect(entry.items == [.init(symbol: nil, title: "Row", body: nil)])
    }

    @Test func blankFieldsAreTrimmedAwayAndEmptyRowsDropped() throws {
        let entry = try #require(select("""
        { "en": { "title": "  T  ", "items": [
            { "symbol": " ", "title": "  Row  ", "body": "" },
            { "symbol": "star", "title": " ", "body": "  " }
        ] } }
        """))
        #expect(entry.title == "T")
        #expect(entry.items == [.init(symbol: nil, title: "Row", body: nil)])
    }

    @Test func itemsWithNothingUsableFallBackToHighlights() throws {
        let entry = try #require(select("""
        { "en": { "title": "T", "items": [{ "symbol": "star" }], "highlights": ["Old."] } }
        """))
        #expect(entry.items == [.init(symbol: nil, title: nil, body: "Old.")])
    }

    @Test func aBlankTitleOrNoRowsIsNoEntry() {
        #expect(select(#"{ "en": { "title": " ", "items": [{ "title": "Row" }] } }"#) == nil)
        #expect(select(#"{ "en": { "title": "T", "items": [] } }"#) == nil)
        #expect(select(#"{ "en": { "title": "T" } }"#) == nil)
    }

    @Test func chineseReadersGetTheTraditionalBlockAndOthersEnglish() throws {
        let json = """
        { "en": { "title": "EN", "highlights": ["e"] }, "zh-TW": { "title": "ZH", "highlights": ["z"] } }
        """
        #expect(select(json, languageTag: "zh-Hant-TW")?.title == "ZH")
        #expect(select(json, languageTag: "zh-Hans-CN")?.title == "ZH")
        #expect(select(json, languageTag: "yue-Hant-HK")?.title == "ZH")
        #expect(select(json, languageTag: "ja-JP")?.title == "EN")
    }

    @Test func aMalformedVersionDropsOnlyItsOwnSummary() throws {
        let json = """
        {
          "2.2.0": { "en": { "title": "Bad", "items": { "title": "not an array" } } },
          "2.3.0": { "en": { "title": "Good", "items": [{ "title": "Row" }] } }
        }
        """
        let byVersion = try #require(WhatsNewRepository.decodeByVersion(Data(json.utf8)))
        #expect(byVersion["2.2.0"] == nil)
        let good = WhatsNewRepository.select(versionEntry: byVersion["2.3.0"], version: "2.3.0", languageTag: "en")
        #expect(good?.title == "Good")
    }

    @Test func theShippedJSONDecodesAndEveryKeyIsAVersion() throws {
        let url = try #require(Bundle.main.url(forResource: "whatsnew", withExtension: "json"))
        let byVersion = try JSONDecoder().decode(
            [String: [String: WhatsNewEntry]].self,
            from: Data(contentsOf: url)
        )
        #expect(!byVersion.isEmpty)
        for key in byVersion.keys {
            #expect(AppVersion(key) != nil, "unparseable version key \(key)")
        }
        #expect(WhatsNewRepository().latestEntry(languageTag: "en") != nil)
        // A ceiling below the newest entry stops at the newest one under it.
        #expect(WhatsNewRepository().latestEntry(languageTag: "en", upTo: AppVersion("2.2.0")!)?.version == "2.2.0")
        #expect(WhatsNewRepository().latestEntry(languageTag: "zh-Hant-TW") != nil)
    }

    // MARK: - Helpers

    private func select(_ json: String, languageTag: String = "en") -> WhatsNewRepository.ResolvedWhatsNew? {
        let versionEntry = try? JSONDecoder().decode([String: WhatsNewEntry].self, from: Data(json.utf8))
        return WhatsNewRepository.select(versionEntry: versionEntry, version: "9.9.9", languageTag: languageTag)
    }
}
