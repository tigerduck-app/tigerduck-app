import SwiftUI

// iOS 18 changed scroll-view gesture arbitration: a plain `.onTapGesture`
// placed on content inside a ScrollView / LazyVGrid loses to the scroll view
// and only registers on the *second* tap, and a plain `.onTapGesture` /
// `.onLongPressGesture` installed over the whole scroll content competes with —
// and swallows — the *first* tap on every interactive child.
//
// The fix, centralized here so every scroll-embedded surface applies it the
// same way (and new surfaces can't forget it):
//   • wrap tap targets in a real `Button` — its tap wins arbitration;
//   • attach whole-view recognizers (keyboard dismiss, edit-mode long-press)
//     via `.simultaneousGesture` so they coexist without eating child taps.
extension View {
    /// Wraps the view in a borderless `Button` whose tap wins iOS 18 gesture
    /// arbitration against an enclosing scroll view. `.contentShape` keeps the
    /// whole frame (including transparent padding) hittable; `Button` supplies
    /// the `.isButton` accessibility trait automatically.
    ///
    /// `onPressChanged`, when supplied, reports the Button's press state —
    /// `true` at touch-down (before the tap action is delivered on release),
    /// `false` when the press lifts or cancels. Callers that run a
    /// `.simultaneousGesture` drag alongside the tap use the touch-down edge as
    /// a per-interaction reset hook that doesn't depend on callback ordering.
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
