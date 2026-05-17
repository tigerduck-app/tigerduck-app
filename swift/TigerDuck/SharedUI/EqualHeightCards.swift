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

    /// Grows self to at least `height` when it's > 0. Using `minHeight`
    /// instead of a fixed `height` keeps a card that's naturally taller
    /// than the current lock from being clipped — important because
    /// `reportCardHeight()` is applied AFTER this modifier, so the
    /// reported value would otherwise echo the locked height back and
    /// the preference key would never see the real natural height of a
    /// card that came in tall (e.g. CurrentClassCard rendering after a
    /// shorter TodayCourseCard had already seeded the lock). The
    /// consumer monotonically grows its `@State` from preference
    /// updates, so within a couple of layout passes the row settles on
    /// the genuine tallest height with no clipping.
    @ViewBuilder
    func lockCardHeight(_ height: CGFloat) -> some View {
        if height > 0 {
            self.frame(minHeight: height, alignment: .top)
        } else {
            self
        }
    }
}
