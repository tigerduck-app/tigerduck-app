import SwiftUI

// Since iOS 18 a plain `.onTapGesture` inside a ScrollView or LazyVGrid loses to the scroll view
// until the second tap, and a tap or long-press over all of it swallows each child's first tap.
// These helpers make tap targets `Button`s and add whole-view gestures via `.simultaneousGesture`.
extension View {
    /// Wraps the view in a borderless `Button`, whose tap wins iOS 18 gesture arbitration against
    /// an enclosing scroll view. `.contentShape` keeps the whole frame, transparent padding
    /// included, hittable, and `Button` supplies the `.isButton` accessibility trait.
    ///
    /// `onPressChanged` reports the press state: `true` at touch-down, before the action fires on
    /// release, and `false` when the press lifts or cancels. Callers running a
    /// `.simultaneousGesture` drag alongside use the touch-down edge as a per-interaction reset
    /// that does not depend on callback ordering.
    func scrollSafeTapAction(
        onPressChanged: ((Bool) -> Void)? = nil,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            self.contentShape(Rectangle())
        }
        .buttonStyle(ScrollSafeButtonStyle(onPressChanged: onPressChanged))
    }

    /// A 0.5 s long-press that enters an edit / reorder mode, attached as a
    /// `.simultaneousGesture` so it never blocks child `Button` taps. Pass the
    /// caller's `reduceMotion` so the enter animation honors the setting.
    func longPressToEdit(
        reduceMotion: Bool,
        perform action: @escaping () -> Void
    ) -> some View {
        simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    withAnimation(reduceMotion ? nil : .smoothSpring) { action() }
                }
        )
    }

    /// A keyboard / focus-dismiss tap attached as a `.simultaneousGesture` so it
    /// doesn't swallow taps on interactive children — the iOS 18 failure mode
    /// that left onboarding links dead.
    func dismissTapGesture(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture().onEnded(action))
    }
}

/// Visually inert button style (no border, background, or press dimming —
/// identical to `.plain` for the content cards `scrollSafeTapAction` wraps)
/// that additionally forwards `configuration.isPressed` so callers can observe
/// the press lifecycle. Reading `isPressed` requires a `ButtonStyle`; there is
/// no plain-modifier equivalent.
private struct ScrollSafeButtonStyle: ButtonStyle {
    let onPressChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged?(isPressed)
            }
    }
}
