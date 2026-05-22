import SwiftUI

struct LoadingShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md)
                .fill(Color.cardSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.08), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        // Tie sweep distance to the actual width so a shimmer
                        // on a 60pt cell doesn't loop 5× and a 600pt cell
                        // never reaches the edge.
                        .offset(x: phase * proxy.size.width)
                }
                .clipped()
                .onAppear { syncShimmer() }
                // Reduce Motion can be switched on while the shimmer is still
                // mounted — re-sync so an in-flight sweep stops.
                .onChange(of: reduceMotion) { _, _ in syncShimmer() }
        }
    }

    private func syncShimmer() {
        guard !reduceMotion else {
            // Reissue a non-repeating animation so the running
            // `repeatForever` sweep settles instead of looping forever.
            withAnimation(.linear(duration: 0)) { phase = -1 }
            return
        }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
