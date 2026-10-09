import SwiftUI

/// Button label that swaps to a spinner without resizing.
///
/// The content stays in the layout, rendered transparent, so the button keeps its intrinsic
/// width and height while loading. Use it as the `label:` of any `Button`.
struct LoadingButtonLabel<Content: View>: View {
    let isLoading: Bool
    var tint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content().opacity(isLoading ? 0 : 1)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            }
        }
    }
}
