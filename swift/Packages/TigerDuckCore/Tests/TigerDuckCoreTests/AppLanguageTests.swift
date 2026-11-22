import Foundation
import Testing
import TigerDuckCore

struct AppLanguageTests {
    private static func bundle(_ tables: [String: [String: String]]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppLanguageTests-\(UUID().uuidString)")
        for (localization, table) in tables {
            let lproj = root.appending(path: "\(localization).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
            try data.write(to: lproj.appending(path: "Localizable.strings"))
        }
        return try #require(Bundle(url: root))
    }

    private static let tables = [
        "en": ["tomorrow": "Tomorrow", "only_en": "English only"],
        "zh-Hant": ["tomorrow": "明天"],
    ]

    @Test func aTagLooksTheKeyUpInItsOwnLocalization() throws {
        let bundle = try Self.bundle(Self.tables)
        #expect(AppLanguage(tag: "zh-Hant").string("tomorrow", bundle: bundle) == "明天")
        #expect(AppLanguage(tag: "en").string("tomorrow", bundle: bundle) == "Tomorrow")
    }

    @Test func withoutATagTheBundlesOwnChoiceIsUsed() throws {
        let bundle = try Self.bundle(Self.tables)
        let system = bundle.localizedString(forKey: "tomorrow", value: nil, table: nil)
        #expect(AppLanguage(tag: nil).string("tomorrow", bundle: bundle) == system)
        #expect(AppLanguage(tag: nil).locale == .current)
    }

    @Test func aKeyTheTagsLocalizationLacksFallsBackToTheSystemsString() throws {
        let bundle = try Self.bundle(Self.tables)
        let system = bundle.localizedString(forKey: "only_en", value: nil, table: nil)
        #expect(AppLanguage(tag: "zh-Hant").string("only_en", bundle: bundle) == system)
    }
}
