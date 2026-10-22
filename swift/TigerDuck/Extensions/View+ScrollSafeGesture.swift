import SwiftUI

extension View {
    func scrollSafeTapAction(
        onPressChanged: ((Bool) -> Void)? = nil,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            self.contentShape(Rectangle())
        }
        .buttonStyle(ScrollSafeButtonStyle(onPressChanged: onPressChanged))
    }

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

    func simultaneousTapGesture(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture().onEnded(action))
    }
}

private struct ScrollSafeButtonStyle: ButtonStyle {
    let onPressChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged?(isPressed)
            }
    }
}
