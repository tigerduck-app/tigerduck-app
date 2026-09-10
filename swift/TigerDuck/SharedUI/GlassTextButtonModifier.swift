import SwiftUI

/// The text-label counterpart to the class table's `headerActions` capsule:
/// Liquid Glass on iOS 26, and below it a filled capsule rather than the
/// rounded rectangle `.bordered` draws by default.
///
/// The shape is the whole point of the pre-26 branch. `.bordered` already
/// fills with `.secondarySystemFill` — the same fill the class table paints
/// its own capsule with — so the two only ever disagreed on corner radius,
/// and a rounded rectangle beside a capsule reads as a different class of
/// control rather than the same one. `.buttonBorderShape` restates the shape
/// without giving up what `.bordered` supplies for free: the pressed state,
/// the disabled treatment, and Dynamic Type sizing.
///
/// Applied by Home's "Now" and Calendar's "Today" — the two page-header
/// actions that sit a tab away from the class table's reset/add pair.
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
