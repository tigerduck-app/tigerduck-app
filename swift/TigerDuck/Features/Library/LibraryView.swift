import SwiftUI
#if os(iOS)
import PassKit
#endif

struct LibraryView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var viewModel = LibraryViewModel()
    @State private var showNotImplementedAlert = false
    @FocusState private var loginField: LoginField?

    private enum LoginField { case username, password }
    #if os(iOS)
    /// Token returned by `PKPassLibrary.requestAutomaticPassPresentationSuppression`.
    /// Held only while the QR page is on-screen so a side-button double-press
    /// can't fire up Apple Pay / Express Transit and cover the library QR.
    @State private var passSuppressionToken: PKSuppressionRequestToken?
    /// The screen hosting this view right now, from ``HostScreenReader``.
    /// Empty until the view is in a window, and weak because the panel can
    /// go away underneath us.
    @State private var hostScreen = WeakScreen()
    /// This instance's claim on the brightness override. Several
    /// `LibraryView`s can be alive at once — the tab plus the embedded
    /// copies Home and More push — so the override itself is owned by
    /// ``LibraryBrightnessCoordinator`` and each view only holds a ticket.
    @State private var brightnessToken = UUID()
    #endif

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 56

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
    }

    private var content: some View {
        Group {
            if shouldCenterQRForRotation {
                qrCenteredLayout
            } else {
                scrollableLayout
            }
        }
        .background(Color.backgroundPrimary)
        .onAppear {
            // Wired before `load()`/`onAppear()`, both of which can already
            // discover an expired token and flip the stored state.
            viewModel.onLibraryStateChanged = { appState.notifyLibraryStateChanged() }
            viewModel.load()
            viewModel.onAppear()
            if viewModel.isLoggedIn {
                suppressExpressTransit()
                boostBrightnessForQR()
            }
        }
        .onDisappear {
            viewModel.onDisappear()
            releaseExpressTransit()
            restoreBrightness()
        }
        // A fold moves the window to the other display. The QR must arrive there
        // boosted and the display left behind must get its brightness back, or a
        // fold leaves a dim code at the scanner or the inner panel at 100% until quit.
        #if os(iOS)
        .onHostScreenChange { screen in
            hostScreen = WeakScreen(screen)
            // Leaving the window is as much a reason to let go of the panel
            // as leaving the page is.
            guard screen != nil else { return restoreBrightness() }
            // A screen change while the scene is inactive or backgrounded
            // must not take back the claim the scene-phase handler just
            // released; `.active` boosts the new screen on the way back.
            guard viewModel.isLoggedIn, scenePhase == .active else { return }
            boostBrightnessForQR()
        }
        #endif
        .onChange(of: viewModel.isLoggedIn) { _, loggedIn in
            if loggedIn {
                suppressExpressTransit()
                boostBrightnessForQR()
            } else {
                releaseExpressTransit()
                restoreBrightness()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                viewModel.onAppear()
                if viewModel.isLoggedIn {
                    suppressExpressTransit()
                    boostBrightnessForQR()
                }
            case .background, .inactive:
                viewModel.stopTimers()
                // Re-enable Express Transit as soon as the QR leaves the
                // foreground — a backgrounded app should not keep the
                // user's transit card globally suppressed.
                releaseExpressTransit()
                // Same reasoning for brightness: don't pin the screen at
                // 1.0 if the user is no longer looking at the QR.
                restoreBrightness()
            @unknown default:
                // A phase we do not know about is not a reason to keep the
                // user's transit card suppressed or their panel pinned at
                // full. Tear down exactly as the known non-active cases do.
                viewModel.stopTimers()
                releaseExpressTransit()
                restoreBrightness()
            }
        }
    }

    // MARK: - Express Transit suppression

    #if os(iOS)
    // TODO: Request `com.apple.developer.passkit.pass-presentation-suppression` from
    // Apple. Until granted, production signing strips it from `TigerDuck.entitlements`,
    // so the call gets `.notSupported` and the side button still opens Express Transit.
    private func suppressExpressTransit() {
        guard passSuppressionToken == nil else { return }
        let token = PKPassLibrary.requestAutomaticPassPresentationSuppression { _ in }
        passSuppressionToken = token
    }

    private func releaseExpressTransit() {
        guard let token = passSuppressionToken else { return }
        PKPassLibrary.endAutomaticPassPresentationSuppression(withRequestToken: token)
        passSuppressionToken = nil
    }
    #else
    private func suppressExpressTransit() {}
    private func releaseExpressTransit() {}
    #endif

    // MARK: - Brightness boost (scanner readability)

    #if os(iOS)
    /// `true` when this display can drive EDR at all, so the Metal renderer's
    /// local highlight carries the QR and global brightness is left alone.
    ///
    /// Reads `potentialEDRHeadroom`, which Apple documents as queryable before any
    /// EDR content is shown, and which is `1.0` on SDR panels. `currentEDRHeadroom`
    /// reads `1.0` until the Metal layer draws, so it would boost every device. A
    /// thermally throttled EDR panel shows the QR at SDR white, which still scans.
    /// See docs/decisions/0009-library-qr-brightness.md.
    private var edrIsAvailable: Bool {
        guard let screen = hostScreen.screen else { return false }
        return HDRQRCodeImage.isSupported && screen.potentialEDRHeadroom > 1.0
    }

    /// Pin the screen at full brightness while the QR is on-screen — the
    /// fallback Apple Wallet-style behaviour for displays that can't drive
    /// EDR. When EDR is genuinely active the Metal renderer already makes
    /// the QR pop locally, so the global brightness override is skipped to
    /// preserve the local-highlight behaviour this view is built around.
    private func boostBrightnessForQR() {
        guard let screen = hostScreen.screen, !edrIsAvailable else {
            // Not boosting means this view must not hold the override at all. After a
            // move to an EDR display, a bare `return` would leave the SDR panel behind
            // pinned at 1.0 with nothing on it until teardown.
            restoreBrightness()
            return
        }
        LibraryBrightnessCoordinator.shared.boost(screen, token: brightnessToken)
    }

    /// Safe to call unconditionally: the coordinator ignores a token it is
    /// not holding, and only restores the panel once every claim is gone.
    private func restoreBrightness() {
        LibraryBrightnessCoordinator.shared.release(token: brightnessToken)
    }
    #else
    private func boostBrightnessForQR() {}
    private func restoreBrightness() {}
    #endif

    /// A wide canvas rotates freely, so anchor the QR to vertical center to keep
    /// its on-screen position stable across orientation changes. A compact one is
    /// portrait in practice and keeps the regular top-aligned scroll layout.
    ///
    /// Keyed on size class, not idiom: a foldable's inner display ignores the
    /// app's supported orientations and reports the `.phone` idiom while regular
    /// in both dimensions, so "iPhone is portrait-locked" does not hold. macOS has
    /// no size class here but does not show LibraryView, so it falls through.
    private var shouldCenterQRForRotation: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular && viewModel.isLoggedIn
        #else
        false
        #endif
    }

    private var qrCenteredLayout: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            headerSection
            errorBanner
            Spacer(minLength: 0)
            qrSection
            Spacer(minLength: 0)
        }
        .padding(.bottom, TigerDuckTheme.Spacing.xxl)
    }

    private var scrollableLayout: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                headerSection
                errorBanner
                if viewModel.isLoggedIn {
                    qrSection
                } else {
                    loginPrompt
                }
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text(String(localized: "feature_library"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            SyncStatusDot(
                status: viewModel.errorMessage != nil ? .failed : (viewModel.isLoggedIn ? .ok : .unknown),
                label: String(localized: "feature_library"),
                icon: "books.vertical.fill",
                text: viewModel.isLoggedIn
                    ? String(localized: "library_status_signed_in")
                    : String(localized: "common_not_signed_in"),
                isLoading: viewModel.isLoadingQR
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    // MARK: - Error

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
            }
            .cardPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }

    // MARK: - QR Code Section

    private var qrSection: some View {
        LibraryQRCodeView(
            qrImage: viewModel.qrCodeImage,
            countdown: viewModel.countdown,
            isLoading: viewModel.isLoadingQR,
            username: LibraryService.storedUsername
        )
    }

    // MARK: - Login Prompt

    private var loginPrompt: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            Image(systemName: "qrcode")
                .font(.system(size: heroIconSize))
                .foregroundStyle(.tint)

            Text(String(localized: "library_sign_in_qr_prompt"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)

            Text(String(localized: "library_password_hint"))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                TextField(String(localized: "sign_in_student_id"), text: $viewModel.libUsername)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($loginField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { loginField = .password }
                    .padding(TigerDuckTheme.Spacing.md)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))

                // `PasswordField`, not a bare `SecureField`: it adds the reveal toggle
                // and a `.screenCaptureProtected` wrapper that hides the revealed
                // plaintext from screenshots and screen recording.
                PasswordField(
                    placeholder: String(localized: "library_sign_in_password"),
                    text: $viewModel.libPassword,
                    focusBinding: $loginField,
                    focusValue: .password,
                    onSubmit: { viewModel.loginAndStart() }
                )
                .padding(TigerDuckTheme.Spacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))
            }

            loginButton
        }
        .cardPadding()
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    @ViewBuilder
    private var loginButton: some View {
        let disabled = viewModel.libUsername.isEmpty || viewModel.libPassword.isEmpty || viewModel.isLoggingIn

        if #available(iOS 26, *) {
            Button {
                viewModel.loginAndStart()
            } label: {
                loginButtonLabel
            }
            .buttonStyle(.glassProminent)
            .disabled(disabled)
        } else {
            Button {
                viewModel.loginAndStart()
            } label: {
                loginButtonLabel
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(TigerDuckTheme.Spacing.md)
                    .background(
                        .tint.opacity(disabled ? 0.5 : 1),
                        in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md)
                    )
            }
            .disabled(disabled)
        }
    }

    private var loginButtonLabel: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            if viewModel.isLoggingIn {
                ProgressView()
                    .tint(.white)
            }
            Text(viewModel.isLoggingIn
                ? String(localized: "library_signing_in_label")
                : String(localized: "library_sign_in_action"))
                .font(TigerDuckTheme.Typography.headline)
        }
    }

    // MARK: - Library Features

    private var libraryFeaturesSection: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            featureCard(
                icon: "door.left.hand.open",
                title: String(localized: "library_feature_discussion_room"),
                subtitle: String(localized: "library_coming_soon_badge")
            )
            featureCard(
                icon: "mic.fill",
                title: String(localized: "library_feature_lecture"),
                subtitle: String(localized: "library_coming_soon_badge")
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .notImplementedAlert(isPresented: $showNotImplementedAlert)
    }

    private func featureCard(icon: String, title: String, subtitle: String) -> some View {
        Button {
            showNotImplementedAlert = true
        } label: {
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)

                Text(title)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)

                Text(subtitle)
                    .font(TigerDuckTheme.Typography.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, TigerDuckTheme.Spacing.lg)
            .glassCard()
        }
        .buttonStyle(.plain)
    }
}
