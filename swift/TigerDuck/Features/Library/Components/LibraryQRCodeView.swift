import SwiftUI

struct LibraryQRCodeView: View {
    let qrImage: UIImage?
    let countdown: Int
    let isLoading: Bool
    let username: String?

    /// Caps the rendered QR width so it stays comfortable on iPad and tunable
    /// for field testing. Adjust here; the view squares itself via the
    /// 1:1 aspect ratio below.
    private static let qrCodeMaxWidth: CGFloat = 250

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
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

            // QR Code
            qrCodeContent
                .frame(maxWidth: Self.qrCodeMaxWidth)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, TigerDuckTheme.Spacing.xxl)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)

            // Countdown
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ZStack {
                    Circle()
                        .stroke(Color.textSecondary.opacity(0.3), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: CGFloat(countdown) / 30.0)
                        .stroke(Color.accentPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: countdown)
                }
                .frame(width: 18, height: 18)

                Text(String(format: String(localized: "library_qr_refresh_in_seconds"), countdown))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.bottom, TigerDuckTheme.Spacing.md)
        }
        .glassCard(cornerRadius: TigerDuckTheme.CornerRadius.xl)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    @ViewBuilder
    private var qrCodeContent: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(1.5)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let image = qrImage {
            #if os(iOS)
            // EDR-backed Metal renderer — drives pixels >1.0 on HDR-capable
            // displays so the QR "pops" out of the surrounding glass card
            // without changing system brightness. Falls back to the SDR
            // `Image` below if Metal can't initialise (no MTLDevice / shader
            // build failure), since the Metal view then draws transparent.
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
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: heroIconSize))
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}
