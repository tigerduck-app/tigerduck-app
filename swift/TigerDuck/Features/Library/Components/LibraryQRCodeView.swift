import SwiftUI

struct LibraryQRCodeView: View {
    let qrImage: UIImage?
    let countdown: Int
    let isLoading: Bool
    let username: String?

    /// Animated trim fraction driving the countdown ring (0 → 1).
    ///
    /// Kept separate from `countdown` so we can pick the animation per
    /// transition: a tick (countdown decreasing) gets a 1-second linear
    /// sweep, while an initial fill or QR refresh (countdown jumping
    /// back up to 30) snaps instantly. Without this split, the
    /// `.animation` modifier would animate the 0 → 30 jump too and the
    /// user sees the ring "load full" over a second before the actual
    /// countdown starts.
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

            // QR Code — has comfortable inset on both sides so the
            // matrix doesn't run right to the card edge.
            //
            // `.screenCaptureProtected()` wraps ONLY the matrix subtree,
            // not the whole card. The wrapper hosts content through
            // `UIHostingController` and intercepts SwiftUI's sizing
            // protocol — when applied at the card level, it squished
            // the QR because the title + countdown rows reported their
            // own row heights and the wrapper's compressed-fit probe
            // gave the aspect-ratio QR row 0 height. Wrapping the
            // matrix directly puts the `.aspectRatio(1, .fit)` modifier
            // OUTSIDE the wrap, so SwiftUI proposes a finite square
            // straight to the wrap.
            qrCodeContent
                .screenCaptureProtected()
                .frame(maxWidth: Self.qrCodeMaxWidth)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)

            // Countdown
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ZStack {
                    // Both rings share the SAME `StrokeStyle` (matching
                    // lineWidth + lineCap) so they trace pixel-identical
                    // paths. Mismatched caps (`.butt` vs `.round`) were
                    // why the grey peeked through the blue at the seam.
                    Circle()
                        .stroke(
                            Color.textSecondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                    Circle()
                        .trim(from: 0, to: ringFraction)
                        .stroke(
                            Color.accentPrimary,
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
        // Outer breathing room so the card sits inside the screen edges
        // rather than running flush to them. The sensitive part (the QR
        // matrix) is wrapped with `.screenCaptureProtected()` at its own
        // call site above — wrapping the entire card here instead
        // interfered with the aspect-ratio sizing and rendered the QR
        // at half size.
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
