import SwiftUI

struct LibraryQRCodeView: View {
    let qrImage: UIImage?
    let countdown: Int
    let isLoading: Bool
    let username: String?

    /// Animated trim fraction driving the countdown ring (0 → 1).
    ///
    /// Kept apart from `countdown` to pick the animation per transition: a tick
    /// gets a 1-second linear sweep, while the initial fill or a QR refresh
    /// (countdown back up to 30) snaps. A single `.animation` would animate that
    /// jump too, and the ring would visibly fill over a second before counting.
    @State private var ringFraction: CGFloat = 0

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

            // Padding keeps the matrix off the card edge. This `.aspectRatio(1, .fit)`
            // hands `qrCodeContent`'s `.screenCaptureProtected()` a finite square; at card
            // level, the wrapper's compressed-fit probe would give the QR row zero height.
            qrCodeContent
                .frame(maxWidth: Self.qrCodeMaxWidth)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)

            // Countdown
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ZStack {
                    // Both rings use the same `StrokeStyle` so they trace identical
                    // paths; mismatched caps (`.butt` vs `.round`) let the grey peek
                    // through the blue at the seam.
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
                        // Counting down: sweep over 1 second to match
                        // the timer tick.
                        withAnimation(.linear(duration: 1)) { ringFraction = target }
                    } else {
                        // Initial fill or QR refresh — snap, no
                        // "loading-full" sweep.
                        ringFraction = target
                    }
                }

                Text(String(format: String(localized: "library_qr_refresh_in_seconds"), countdown))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.bottom, TigerDuckTheme.Spacing.md)
        }
        .glassCard(cornerRadius: TigerDuckTheme.CornerRadius.xl)
        // Keep the card off the screen edges. `.screenCaptureProtected()` wraps only
        // the QR matrix, in `qrCodeContent`: wrapping the whole card here would break
        // the aspect-ratio sizing and render the QR at half size.
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    /// The three states of the QR slot. Only the middle one is wrapped in
    /// `.screenCaptureProtected()`.
    ///
    /// The wrapper is costly, and its documentation keeps it to small leaves: it
    /// hosts its subtree on a secure `UITextField`'s canvas, re-measures it every
    /// layout pass and walks the field's views on each `layoutSubviews`. A spinner
    /// animates forever, so that work would run on the main thread for the whole
    /// fetch, and neither it nor the placeholder carries a scannable credential.
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
        // The EDR Metal view drives pixels above 1.0, so the QR pops out of the glass
        // card without touching system brightness. If Metal cannot start (no device or
        // a shader build failure) it draws transparent and the SDR `Image` shows.
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
