import Foundation
import Testing
import UIKit

@testable import TigerDuck

@MainActor
@Suite("Feature card names")
struct FeatureCardNameTests {
    private static let font = UIFont.preferredFont(forTextStyle: .headline)
    private static let english = Locale(identifier: "en_US")

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    @Test("a name whose words fit keeps them whole")
    func fittingNameIsUnchanged() {
        let name = "Class Table"
        #expect(FeatureCardView.hyphenated(name, width: Self.width(of: "Table") + 1, font: Self.font, locale: Self.english) == name)
    }

    @Test("only a word wider than the card gets soft hyphens")
    func overlongWordIsHyphenated() {
        let name = "My Announcements"
        let result = FeatureCardView.hyphenated(
            name, width: Self.width(of: "Announce"), font: Self.font, locale: Self.english
        )
        let words = result.split(separator: " ").map(String.init)
        #expect(words[0] == "My")
        #expect(words[1].contains("\u{00AD}"))
        #expect(result.replacingOccurrences(of: "\u{00AD}", with: "") == name)
    }

    @Test("Chinese, and a card not measured yet, are left as they are")
    func noHyphenationWithoutALanguageOrWidth() {
        let name = "校園信箱"
        #expect(FeatureCardView.hyphenated(name, width: 10, font: Self.font, locale: Locale(identifier: "zh_TW")) == name)
        #expect(FeatureCardView.hyphenated("Announcements", width: 0, font: Self.font, locale: Self.english) == "Announcements")
    }
}
