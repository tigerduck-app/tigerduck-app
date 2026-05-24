import SwiftUI
#if os(iOS)
import PassKit
#endif

struct LibraryView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
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
    /// `true` when EDR is *actually* delivering extra luminance to the QR
    /// right now, so the Metal renderer's local highlight is enough and we
    /// can leave global brightness alone.
    ///
    /// Neither `HDRQRCodeImage.isSupported` (only proves a Metal device
    /// exists) nor `potentialEDRHeadroom` (the display's *theoretical* max,
    /// still > 1 while EDR is thermally throttled) is a reliable signal.
    /// `currentEDRHeadroom` reflects the headroom usable at this moment and
    /// collapses to `1.0` on SDR panels or when EDR is unavailable.
    private var edrIsActive: Bool {
        HDRQRCodeImage.isSupported && UIScreen.main.currentEDRHeadroom > 1.0
    }

    /// Pin the screen at full brightness while the QR is on-screen — the
    /// fallback Apple Wallet-style behaviour for displays that can't drive
    /// EDR. When EDR is genuinely active the Metal renderer already makes
    /// the QR pop locally, so the global brightness override is skipped to
    /// preserve the local-highlight behaviour this view is built around.
    private func boostBrightnessForQR() {
        guard !edrIsActive else { return }
        if savedBrightness == nil {
            savedBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 1.0
    }

    private func restoreBrightness() {
        guard let saved = savedBrightness else { return }
        UIScreen.main.brightness = saved
        savedBrightness = nil
    }
    #else
    private func boostBrightnessForQR() {}
    private func restoreBrightness() {}
    #endif

    /// iPad rotates freely, so anchor the QR to vertical center to keep its
    /// on-screen position stable across orientation changes. iPhone is
    /// portrait-locked by Info.plist and stays on the regular top-aligned
    /// scroll layout. macOS has no `UIDevice`; the Mac surface doesn't
    /// expose LibraryView today but the file still compiles into the Mac
    /// target, so fall through to the regular layout instead.
    private var shouldCenterQRForRotation: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad && viewModel.isLoggedIn
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
            HStack(spacing: TigerDuckTheme.Spacing.xs) {
                Circle()
                    .fill(viewModel.isLoggedIn ? Color.green : Color.textSecondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(viewModel.isLoggedIn
                    ? String(localized: "library_status_logged_in")
                    : String(localized: "common_not_logged_in"))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
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
                .foregroundStyle(Color.accentPrimary)

            Text(String(localized: "library_login_qr_prompt"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)

            Text(String(localized: "library_password_hint"))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                TextField(String(localized: "login_student_id"), text: $viewModel.libUsername)
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
                    placeholder: String(localized: "library_login_password"),
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
                        Color.accentPrimary.opacity(disabled ? 0.5 : 1),
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
                ? String(localized: "library_logging_in_label")
                : String(localized: "library_login_action"))
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
                    .foregroundStyle(Color.accentPrimary)

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
