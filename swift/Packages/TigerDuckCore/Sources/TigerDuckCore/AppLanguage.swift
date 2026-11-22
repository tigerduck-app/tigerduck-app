import Foundation

/// The language chosen in the app's settings, which the Watch, the widgets and the Live Activity
/// show, or the device's when `tag` is nil. They run in processes of their own, which look keys up
/// in the device's language whatever the app chose.
/// `String(localized:locale:)` only formats in its locale and still looks the key up in the
/// system's language, so `string(_:)` picks the localization from the tag itself.
public struct AppLanguage: Equatable, Sendable {
    public let tag: String?

    public init(tag: String?) {
        self.tag = tag
    }

    public var locale: Locale {
        tag.map(Locale.init(identifier:)) ?? .current
    }

    public func string(_ key: LocalizedStringResource, bundle: Bundle = .main) -> String {
        let system = bundle.localizedString(forKey: key.key, value: nil, table: nil)
        guard let tag,
              let localization = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [tag]).first,
              let lproj = bundle.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:))
        else { return system }
        return lproj.localizedString(forKey: key.key, value: system, table: nil)
    }

    public func format(_ key: LocalizedStringResource, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
