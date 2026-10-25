import Foundation

/// The language chosen in the phone app (`WatchSnapshot.languageTag`), which the Watch app and its
/// complication show, or the Watch's own before the phone has sent one.
/// `String(localized:locale:)` only formats in its locale and still looks the key up in the
/// system's language, so `string(_:)` picks the localization from the tag itself.
public nonisolated struct WatchLanguage: Equatable, Sendable {
    public let tag: String?

    public init(tag: String?) {
        self.tag = tag
    }

    public var locale: Locale {
        tag.map(Locale.init(identifier:)) ?? .current
    }

    public func string(_ key: String, bundle: Bundle = .main) -> String {
        let system = bundle.localizedString(forKey: key, value: nil, table: nil)
        guard let tag,
              let localization = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [tag]).first,
              let lproj = bundle.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:))
        else { return system }
        return lproj.localizedString(forKey: key, value: system, table: nil)
    }

    public func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
