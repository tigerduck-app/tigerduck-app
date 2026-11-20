import SwiftUI

extension View {
    /// with a large navigation title (`BulletinsView`) gets this from `.searchable`'s drawer;
    /// a page whose title is a content row, to line up with Home and Class table, cannot: with
    /// no large title to fold under, the bar keeps the field on screen at rest.
    func pullToRevealSearch(isRevealed: Binding<Bool>, isActive: Bool) -> some View {
        modifier(PullToRevealSearch(isRevealed: isRevealed, isActive: isActive))
    }
}

private struct PullToRevealSearch: ViewModifier {
    @Binding var isRevealed: Bool
    let isActive: Bool

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled

    private var isPinned: Bool { voiceOverEnabled || switchControlEnabled }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Zone.self) { geometry in
                Zone(offset: geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, zone in
                if zone == .pulled, !isRevealed {
                    withAnimation(.snappy) { isRevealed = true }
                } else if zone == .scrolled, isRevealed, !isActive, !isPinned {
                    withAnimation(.snappy) { isRevealed = false }
                }
            }
            .onChange(of: isPinned, initial: true) { _, pinned in
                if pinned { isRevealed = true }
            }
    }

    nonisolated enum Zone: Equatable {
        case pulled, top, scrolled

        private static let revealDistance: CGFloat = 32
        private static let foldDistance: CGFloat = 8

        init(offset: CGFloat) {
            if offset < -Self.revealDistance {
                self = .pulled
            } else if offset > Self.foldDistance {
                self = .scrolled
            } else {
                self = .top
            }
        }
    }
}
