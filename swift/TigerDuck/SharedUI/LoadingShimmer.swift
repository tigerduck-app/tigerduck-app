import SwiftUI

struct LoadingShimmer: View {
    @State private var phase: CGFloat = 0

    var body: some View {
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
                    .offset(x: phase)
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 300
                }
            }
    }
}
