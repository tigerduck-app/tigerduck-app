import SwiftUI

struct LibraryQRCodeView: View {
    let qrImage: UIImage?
    let countdown: Int
    let isLoading: Bool
    let username: String?

    /// Caps the rendered QR width on the iPad-centered layout — without
    /// it the QR would balloon past a readable scan distance on the
    /// larger geometry. On iPhone (≤ Pro Max width ~430pt) this cap is
    /// not reached, so the QR fills the screen edge-to-edge.
    private static let qrCodeMaxWidth: CGFloat = 500

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

            // QR Code — edge-to-edge on iPhone (capped on iPad via
            // `qrCodeMaxWidth`). No inner horizontal padding so the
            // matrix touches the card sides; the card itself has no
            // outer horizontal padding either (see below), so the QR
            // spans the full screen width on iPhone.
            qrCodeContent
                .frame(maxWidth: Self.qrCodeMaxWidth)
                .aspectRatio(1, contentMode: .fit)
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
        // No outer horizontal padding: the card runs edge-to-edge so
        // the QR inside can be as wide as the iPhone screen.
        // The QR encodes a one-shot library bearer that a screen grab
        // would let a bystander scan from a recording or AirPlay
        // mirror. Mirrors Android `LibraryScreen.SecureScreen(secure =
        // isLoggedIn)`; redundant with the screen-level protection on
        // `LibraryView` but kept as defense in depth in case this
        // component is dropped into a context without that wrap.
        .screenCaptureProtected()
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
