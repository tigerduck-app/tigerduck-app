import SwiftUI

/// Preference key shared by the equal-height row's hidden measurement
/// layer. Reduce uses `max` so the tallest natural-height card wins.
struct MaxCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Horizontal row that forces every child to the height of the tallest
/// natural-height child seen so far. The locked height only grows during
/// a single on-screen visit — when a later-arriving child renders taller,
/// the row grows to match. It resets to zero on `.onDisappear` so the
/// next time the page is shown the row re-measures from scratch; that
/// matters in `TabView`, where SwiftUI keeps the view identity (and its
/// `@State`) alive across tab switches, so a one-time tall child like
/// the "current class" card wouldn't otherwise release its grip on the
/// row height after the user leaves and comes back.
///
/// Implementation: a visible HStack pinned to `lockedHeight` is shadowed
/// by a hidden HStack rendering the same `content()` at its intrinsic
/// (natural) height. The hidden layer feeds the max natural height back
/// through `MaxCardHeightKey`, the consumer monotonically grows
/// `lockedHeight`, and the visible layer pins every child to it. We
/// can't measure the visible layer directly because its `.frame(height:)`
/// echoes the locked value back — re-rendering `content()` in a hidden
/// `.fixedSize(vertical:)` layer is the simplest way to get a true
/// natural measurement without a custom Layout.
struct EqualHeightHStack<Content: View>: View {
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    @State private var lockedHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            content()
        }
        .frame(height: lockedHeight > 0 ? lockedHeight : nil, alignment: .top)
        .background(measurementLayer)
        .onPreferenceChange(MaxCardHeightKey.self) { newValue in
            if newValue > lockedHeight { lockedHeight = newValue }
        }
        .onDisappear { lockedHeight = 0 }
    }

    private var measurementLayer: some View {
        HStack(alignment: alignment, spacing: spacing) {
            content()
        }
        // `.fixedSize(vertical: true)` lets each child report its
        // intrinsic height regardless of what `.frame(height:)` would
        // otherwise propose down — that's what makes the natural-height
        // measurement independent of the visible layer's lock.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: MaxCardHeightKey.self, value: proxy.size.height)
            }
        )
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
