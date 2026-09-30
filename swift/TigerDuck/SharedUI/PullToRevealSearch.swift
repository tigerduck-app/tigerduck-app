import SwiftUI

extension View {
    /// Pull-to-reveal for a search field that sits in a list's own content, under a title row —
    /// what `.searchable`'s navigation-bar drawer does for a page with a large navigation title
    /// (`BulletinsView`). A page whose title is a content row, to line up with Home and Class
    /// table, cannot use that drawer: with no large title to fold it under, the bar keeps the
    /// field on screen at rest.
    ///
    /// A pull past the top sets `isRevealed`; the next scroll down clears it again unless the
    /// search `isActive` — text in it, or the keyboard up. The page shows the field while
    /// `isRevealed` is set.
    func pullToRevealSearch(isRevealed: Binding<Bool>, isActive: Bool) -> some View {
        modifier(PullToRevealSearch(isRevealed: isRevealed, isActive: isActive))
    }
}

private struct PullToRevealSearch: ViewModifier {
    @Binding var isRevealed: Bool
    let isActive: Bool

    /// Neither can pull a list past its top, so under either the field simply stays.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled

    private var isPinned: Bool { voiceOverEnabled || switchControlEnabled }

    /// Only a change of zone reaches the action, not every frame of a scroll. So the field folds
    /// the moment a scroll sets off, while it is still on screen and moving the way the content
    /// already is, and the rows below it never jump.
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

    /// Where the list's top edge is. The distances are scroll distances, not layout spacing.
    nonisolated enum Zone: Equatable {
        case pulled, top, scrolled

        /// Short of where `.refreshable` fires, so a light pull only reveals the field and a long
        /// one refreshes as well — as a pull does under `.searchable`.
        private static let revealDistance: CGFloat = 32
        /// Enough to ignore the settle of a bounce.
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
