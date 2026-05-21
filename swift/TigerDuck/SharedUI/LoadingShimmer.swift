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
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
    }
}
