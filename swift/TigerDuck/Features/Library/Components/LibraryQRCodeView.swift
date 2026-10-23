import SwiftUI

struct LibraryQRCodeView: View {
    let qrImage: UIImage?
    let countdown: Int
    let isLoading: Bool
    let username: String?
    var showsCountdown = true

    @State private var ringFraction: CGFloat = 0

    private static let qrCodeMaxWidth: CGFloat = 500

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Text(String(localized: "library_virtual_pass_title"))
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                if let username {
                    Text("|")
                        .foregroundStyle(Color.textSecondary.opacity(0.5))
                    Text(username)
                        .font(TigerDuckTheme.Typography.headline)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, TigerDuckTheme.Spacing.md)

            qrCodeContent
                .frame(maxWidth: Self.qrCodeMaxWidth)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)

            if showsCountdown { countdownRow }
        }
        .glassCard(cornerRadius: TigerDuckTheme.CornerRadius.xl)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var countdownRow: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            ZStack {
                Circle()
                    .stroke(
                        Color.textSecondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                Circle()
                    .trim(from: 0, to: ringFraction)
                    .stroke(
                        .tint,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            .onAppear { ringFraction = CGFloat(countdown) / 30.0 }
            .onChange(of: countdown) { oldValue, newValue in
                let target = CGFloat(newValue) / 30.0
                if newValue < oldValue {
                    withAnimation(.linear(duration: 1)) { ringFraction = target }
                } else {
                    ringFraction = target
                }
            }

            Text(String(format: String(localized: "library_qr_refresh_in_seconds"), countdown))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(.bottom, TigerDuckTheme.Spacing.md)
    }

    @ViewBuilder
    private var qrCodeContent: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(1.5)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let image = qrImage {
            qrMatrix(image).screenCaptureProtected()
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: heroIconSize))
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    @ViewBuilder
    private func qrMatrix(_ image: UIImage) -> some View {
        #if os(iOS)
        ZStack {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
            HDRQRCodeImage(image: image)
                .aspectRatio(1, contentMode: .fit)
        }
        #else
        Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
        #endif
    }
}
