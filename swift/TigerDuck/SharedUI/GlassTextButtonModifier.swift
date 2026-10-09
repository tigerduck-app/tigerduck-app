import SwiftUI

/// The text-label counterpart to the class table's `headerActions` capsule:
/// Liquid Glass on iOS 26, and a filled capsule below it.
///
/// Before iOS 26 only the shape differs from `.bordered`, which already uses
/// the `.secondarySystemFill` the class table's capsule has; a rounded rectangle
/// next to a capsule reads as a different kind of control. `.buttonBorderShape`
/// fixes the shape and keeps the pressed, disabled and Dynamic Type handling of
/// `.bordered`. Used by Home's "Now" and Calendar's "Today" header actions.
struct GlassTextButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}
