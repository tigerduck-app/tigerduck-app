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
    /// Pre-boost screen brightness, captured the first time we max the
    /// screen for the QR page. `nil` means we are not currently
    /// overriding brightness.
    @State private var savedBrightness: CGFloat?
    /// The screen `savedBrightness` was taken from and that is currently
    /// pinned bright. Held separately because on a foldable the QR can
    /// move between displays while the boost is live, and the restore has
    /// to go back to the panel we actually touched.
    @State private var boostedScreen: UIScreen?
    /// The screen hosting this view right now, from ``HostScreenReader``.
    /// `nil` until the view is in a window.
    @State private var hostScreen: UIScreen?
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
        // Folding the device hands the window to the other display. The
        // QR has to arrive there already boosted, and the display we are
        // leaving has to get its brightness back — otherwise a fold either
        // leaves a dim code at the scanner or strands the inner panel at
        // 100% until the user quits.
        #if os(iOS)
        .onHostScreenChange { screen in
            hostScreen = screen
            guard viewModel.isLoggedIn else { return }
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
                viewModel.stopTimers()
            }
        }
    }

    // MARK: - Express Transit suppression

    #if os(iOS)
    // TODO: 此 API 需要 `com.apple.developer.passkit.pass-presentation-suppression`
    // 特殊權限,目前尚未向 Apple 申請核准。entitlement key 已先加在
    // `TigerDuck.entitlements`,但核准前 production build 簽署時會被剝除,
    // 呼叫只會拿到 `.notSupported`,Express Transit 仍可被側鍵雙擊喚起。
    // 待 Apple 核准後移除本 TODO。
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
    /// The question has to be answerable *before* any EDR content exists,
    /// which is precisely what rules out `currentEDRHeadroom`. Apple
    /// documents that one as changing "depending on its configuration and
    /// whether it's displaying extended dynamic range content" — so at
    /// `onAppear`, before `EDRMetalQRView`'s `CAMetalLayer` has drawn a
    /// single frame, it always reads `1.0`. The guard then lets the global
    /// boost through on every device, and nothing re-evaluates it, which is
    /// how an EDR iPhone still ended up pinned at full system brightness.
    ///
    /// `potentialEDRHeadroom` is the property Apple documents as queryable
    /// "even when the screen isn't displaying extended dynamic range
    /// content", and it collapses to `1.0` on SDR panels — exactly the case
    /// that still needs the Wallet-style fallback.
    ///
    /// Tradeoff: a thermally throttled EDR display reports potential > 1
    /// while delivering less, so the QR renders at ordinary SDR white rather
    /// than boosted. The SDR `Image` stacked under the Metal layer in
    /// `LibraryQRCodeView` keeps it scannable, and overriding system
    /// brightness is the behaviour this view exists to avoid.
    private var edrIsAvailable: Bool {
        guard let hostScreen else { return false }
        return HDRQRCodeImage.isSupported && hostScreen.potentialEDRHeadroom > 1.0
    }

    /// Pin the screen at full brightness while the QR is on-screen — the
    /// fallback Apple Wallet-style behaviour for displays that can't drive
    /// EDR. When EDR is genuinely active the Metal renderer already makes
    /// the QR pop locally, so the global brightness override is skipped to
    /// preserve the local-highlight behaviour this view is built around.
    private func boostBrightnessForQR() {
        // Already pinned on the screen we are on — nothing to do. Without
        // this the repeated `onAppear` / scene-phase calls would capture
        // an already-boosted 1.0 as the "pre-boost" value and the restore
        // would leave the panel at full.
        guard hostScreen !== boostedScreen else { return }
        // Moving between displays: give the old one its brightness back
        // before touching the new one.
        restoreBrightness()
        guard let hostScreen, !edrIsAvailable else { return }
        savedBrightness = hostScreen.brightness
        boostedScreen = hostScreen
        hostScreen.brightness = 1.0
    }

    private func restoreBrightness() {
        guard let saved = savedBrightness, let screen = boostedScreen else { return }
        screen.brightness = saved
        savedBrightness = nil
        boostedScreen = nil
    }
    #else
    private func boostBrightnessForQR() {}
    private func restoreBrightness() {}
    #endif

    /// A wide canvas rotates freely, so anchor the QR to vertical center
    /// to keep its on-screen position stable across orientation changes.
    /// A compact one is portrait in practice and stays on the regular
    /// top-aligned scroll layout.
    ///
    /// Keyed on the size class rather than the idiom because the premise
    /// the idiom check encoded — "iPhone is portrait-locked by Info.plist"
    /// — is false on a foldable: the inner display ignores the app's
    /// supported orientations, and it reports the `.phone` idiom while
    /// being regular in both dimensions. macOS has no size class here but
    /// does not expose LibraryView today, so it falls through.
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

                // `PasswordField` carries the eye-toggle reveal and the
                // matching `.screenCaptureProtected` wrapper that hides the
                // plaintext from screen recording / screenshots while
                // revealed — the bare `SecureField` had neither.
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
