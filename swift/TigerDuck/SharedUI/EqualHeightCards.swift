import SwiftUI

/// Preference key shared by the equal-height row's hidden measurement
/// layer. Reduce uses `max` so the tallest natural-height card wins.
struct MaxCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Horizontal row that pins every child to the tallest natural height seen so
/// far. The height only grows during one on-screen visit and resets on
/// `.onDisappear`, because `TabView` keeps `@State` across tab switches and a
/// once-tall child, like the "current class" card, would otherwise keep it.
///
/// A hidden copy of `content()` at natural height reports the max through
/// `MaxCardHeightKey`, the simplest measure short of a custom Layout; the visible
/// row cannot measure itself, as its `.frame(height:)` echoes the locked value.
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
        // `.fixedSize(vertical: true)` lets each child report its intrinsic height
        // whatever `.frame(height:)` proposes, so the measurement does not depend
        // on the visible layer's lock.
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
