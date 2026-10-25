import SwiftUI
import UIKit

struct FeatureCardView: View {
    let feature: AppFeature

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @State private var nameWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Image(systemName: feature.iconName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                Spacer()
            }
            Text(Self.hyphenated(feature.displayName, width: nameWidth, font: nameFont, locale: locale))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { nameWidth = $0 }
        }
        // Every card in a row is as tall as its longest name.
        .frame(maxHeight: .infinity, alignment: .top)
        .cardPadding()
        .glassCard()
    }

    private var nameFont: UIFont {
        UIFont.preferredFont(
            forTextStyle: .headline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        )
    }

    /// `name` with soft hyphens, at the points `locale` allows, in each word wider than `width`.
    /// A word that fits is left whole, so it moves to the next line instead of being hyphenated.
    static func hyphenated(_ name: String, width: CGFloat, font: UIFont, locale: Locale) -> String {
        guard width > 0, CFStringIsHyphenationAvailableForLocale(locale as CFLocale) else { return name }
        return name.split(separator: " ", omittingEmptySubsequences: false).map { word in
            let word = String(word)
            guard (word as NSString).size(withAttributes: [.font: font]).width > width else { return word }
            let hyphenated = NSMutableString(string: word)
            let whole = CFRange(location: 0, length: hyphenated.length)
            var index = whole.length
            // From the end, so each insertion leaves the earlier locations where they were.
            while index > 0 {
                let location = CFStringGetHyphenationLocationBeforeIndex(
                    word as CFString, index, whole, 0, locale as CFLocale, nil
                )
                guard location != kCFNotFound, location > 0 else { break }
                hyphenated.insert("\u{00AD}", at: location)
                index = location
            }
            return hyphenated as String
        }.joined(separator: " ")
    }
}
