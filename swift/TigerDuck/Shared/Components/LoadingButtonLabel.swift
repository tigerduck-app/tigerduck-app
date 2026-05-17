import SwiftUI

/// Button label that swaps to a spinner without resizing.
///
/// The original content stays in the layout (rendered transparent) so the
/// button keeps the same intrinsic width and height during the loading
/// state. Use as the `label:` of any `Button`:
///
/// ```
/// Button { ... } label: {
///     LoadingButtonLabel(isLoading: viewModel.isWorking, tint: .white) {
///         Text("Save")
///     }
/// }
/// ```
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
