import SwiftUI

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
