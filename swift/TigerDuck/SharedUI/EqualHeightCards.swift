import SwiftUI

/// Preference key used by horizontally-laid-out card rows (today
/// carousel, time-machine card slot) to negotiate a shared height: each
/// child reports its natural height, the parent reduces to the max, and
/// then pushes that value back down so every card lines up with the
/// tallest one.
///
/// Reduce uses `max` so the *tallest* contributor wins. Combined with a
/// "monotonically grow" pattern in the consumer's `@State`, this gives a
/// height that locks to whatever the tallest card seen during the
/// parent's lifetime was — and only resets when the parent unmounts
/// (i.e. the user leaves the page).
struct MaxCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Measures self and emits its height through `MaxCardHeightKey` so a
    /// surrounding row can pick the tallest. Use on each card that
    /// participates in the equal-height row.
    func reportCardHeight() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: MaxCardHeightKey.self, value: proxy.size.height)
            }
        )
    }

    /// Pins self to `height` when it's > 0. While the locked height is
    /// still being measured (first frame), passes through so the natural
    /// height is reported back to the preference key — otherwise we'd
    /// dead-lock at 0.
    @ViewBuilder
    func lockCardHeight(_ height: CGFloat) -> some View {
        if height > 0 {
            self.frame(height: height, alignment: .top)
        } else {
            self
        }
    }
}
