import SwiftUI

/// The ⋯ menu at the top right of a page header, beside its `SyncStatusDot`.
///
/// Below iOS 26 it matches the Calendar "Today" button (40.33pt, a padded `.bordered`), so
/// header controls are one size across pages. On 26 Today's `.buttonStyle(.glass)` is 28.33pt, and glass
/// that short behind an icon reads as a sliver, so this is 36pt. The `.subheadline` glyph carries
/// the optical weight of Today's caption label. `HeaderControlMetricsTests` measures both against
/// the live Today button.
struct HeaderMenuButton<Items: View>: View {
    static var height: CGFloat {
        if #available(iOS 26, *) { 36 } else { 40 }
    }

    let accessibilityLabel: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        let menu = Menu(content: items) {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: Self.height, height: Self.height)
                // The glyph is smaller than its circle; without this only the glyph is tappable.
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(accessibilityLabel))
        if #available(iOS 26, *) {
            menu.glassEffect(.regular.interactive(), in: .circle)
        } else {
            // Below 26 no glass supplies a backing, and a bare glyph reads as unfinished beside
            // Today's filled pill. `.secondarySystemFill` is what `.bordered` fills with.
            menu.background(Circle().fill(Color(uiColor: .secondarySystemFill)))
        }
    }
}
