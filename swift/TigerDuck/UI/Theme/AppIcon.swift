import SwiftUI

/// An Icon Composer document in `swift/AppIcons/`, by its asset name. The asset name is also the
/// alternate icon name iOS stores for a device that picked it, so a released name never changes.
nonisolated enum AppIcon: String, CaseIterable, Identifiable, Sendable {
    case tigerDuck = "TigerDuck"
    case naihu = "Naihu"
    case tigerDuckChristmas = "TigerDuckChristmas"

    /// The picker's cells, in order: `nil` is the build's primary icon, whichever that is.
    static let choices: [AppIcon?] = [nil] + allCases

    var id: Self { self }

    var titleKey: LocalizedStringResource {
        switch self {
        case .tigerDuck: "app_icon_name_tigerduck"
        case .naihu: "app_icon_name_naihu"
        case .tigerDuckChristmas: "app_icon_name_tigerduck_christmas"
        }
    }

    /// Rendered by `tools/generate_app_icon_previews.py`.
    var preview: Image { Image("\(rawValue)Preview") }

    static func titleKey(of choice: AppIcon?) -> LocalizedStringResource {
        choice?.titleKey ?? "settings_app_icon_default"
    }

    /// The primary icon the asset catalog compiler wrote into Info.plist from
    /// `ASSETCATALOG_COMPILER_APPICON_NAME`.
    static func primary(in bundle: Bundle = .main) -> AppIcon? {
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        return (primary?["CFBundleIconName"] as? String).flatMap(AppIcon.init(rawValue:))
    }
}
