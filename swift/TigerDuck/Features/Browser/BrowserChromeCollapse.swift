import SwiftUI

/// Hides the browser's chrome while the page scrolls down and brings it back on a scroll up; a
/// few points of jitter, and scrolling near the top of the page, change nothing.
nonisolated struct BrowserChromeCollapse: Equatable {
    private(set) var isCollapsed = false
    private var lastOffset: CGFloat = 0

    static let jitter: CGFloat = 4
    static let topZone: CGFloat = 40

    /// `offset` is how far the page has scrolled from its top.
    mutating func scrolled(to offset: CGFloat) {
        let delta = offset - lastOffset
        lastOffset = offset
        if delta > Self.jitter, offset > Self.topZone {
            isCollapsed = true
        } else if delta < -Self.jitter {
            isCollapsed = false
        }
    }

    mutating func expand() {
        isCollapsed = false
    }
}

extension View {
    /// Liquid glass over the page on iOS 26, a material below it; nothing opaque under the chrome.
    @ViewBuilder
    func browserGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.14), radius: 11, y: 6)
        }
    }
}
