import SwiftUI

// Since iOS 18 a plain `.onTapGesture` inside a ScrollView or LazyVGrid loses to the scroll view
// until the second tap, and a tap or long-press over all of it swallows each child's first tap.
// These helpers make tap targets `Button`s and add whole-view gestures via `.simultaneousGesture`.
extension View {
    /// Wraps the view in a borderless `Button`, whose tap wins iOS 18 gesture arbitration against
    /// an enclosing scroll view. `.contentShape` keeps the whole frame, transparent padding
    /// included, hittable, and `Button` supplies the `.isButton` accessibility trait.
    func scrollSafeTapAction(
        onPressChanged: ((Bool) -> Void)? = nil,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            self.contentShape(Rectangle())
        }
        .buttonStyle(ScrollSafeButtonStyle(onPressChanged: onPressChanged))
    }

    func simultaneousTapGesture(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture().onEnded(action))
    }
}

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
