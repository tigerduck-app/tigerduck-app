import SwiftUI
import Defaults

/// The two languages What's New is written in. Like the `whatsnew.json`
/// summary, feature-page copy is authored in Traditional Chinese and
/// English only — not through `app-translation` — so a release's
/// What's New is one bilingual edit rather than a translation round.
enum WhatsNewLanguage: Equatable {
    case zhHant, en

    /// Every Chinese-family language (Mandarin in either script,
    /// Cantonese, Wu, Min Nan, Hakka, Classical) reads Traditional
    /// Chinese; everything else reads English.
    init(languageTag: String) {
        self = Self.isChineseFamily(languageTag) ? .zhHant : .en
    }

    /// The reader's language: the in-app override when one is set,
    /// otherwise the device locale. Feature pages and the summary lookup
    /// both resolve against this tag so they never disagree.
    nonisolated static var currentLanguageTag: String {
        let stored = Defaults[.appLanguage]
        if stored.lowercased() != "system" { return stored }
        return Locale.current.identifier
    }

    static var current: WhatsNewLanguage {
        WhatsNewLanguage(languageTag: currentLanguageTag)
    }

    /// ISO 639 codes treated as Chinese-family — mirrors
    /// ``LanguageManager/chineseLanguageCodes`` (kept local because that
    /// one is private).
    private nonisolated static let sinitic: Set<String> = ["zh", "yue", "nan", "hak", "wuu", "lzh"]

    nonisolated static func isChineseFamily(_ languageTag: String) -> Bool {
        let code = Locale(identifier: languageTag).language.languageCode?.identifier ?? ""
        return sinitic.contains(code)
    }
}

/// A piece of feature-page copy in both of What's New's languages. Both
/// are required, so a page can't ship half-translated.
struct WhatsNewText: Equatable {
    let en: String
    let zhHant: String

    func resolved(for language: WhatsNewLanguage) -> String {
        switch language {
        case .zhHant: zhHant
        case .en: en
        }
    }
}

extension EnvironmentValues {
    /// The language the What's New sheet is showing, set by the flow so a
    /// custom demo or page can pick its own copy to match.
    @Entry var whatsNewLanguage: WhatsNewLanguage = .en
}
