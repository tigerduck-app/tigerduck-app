import SwiftUI
import Defaults

enum WhatsNewLanguage: Equatable {
    case zhHant, en

    init(languageTag: String) {
        self = Self.isChineseFamily(languageTag) ? .zhHant : .en
    }

    nonisolated static var currentLanguageTag: String {
        let stored = Defaults[.appLanguage]
        if stored.lowercased() != "system" { return stored }
        return Locale.current.identifier
    }

    static var current: WhatsNewLanguage {
        WhatsNewLanguage(languageTag: currentLanguageTag)
    }

    private nonisolated static let sinitic: Set<String> = ["zh", "yue", "nan", "hak", "wuu", "lzh"]

    nonisolated static func isChineseFamily(_ languageTag: String) -> Bool {
        let code = Locale(identifier: languageTag).language.languageCode?.identifier ?? ""
        return sinitic.contains(code)
    }
}

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
    @Entry var whatsNewLanguage: WhatsNewLanguage = .en
}
