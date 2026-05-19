import SwiftUI

struct LibraryView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = LibraryViewModel()
    @State private var showNotImplementedAlert = false
    /// Pre-boost brightness, captured the first time we max the screen
    /// for the QR. `nil` means we are not currently overriding brightness.
    @State private var savedBrightness: CGFloat?

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
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
            if viewModel.isLoggedIn { boostBrightness() }
        }
        .onDisappear {
            viewModel.onDisappear()
            restoreBrightness()
        }
        .onChange(of: viewModel.isLoggedIn) { _, loggedIn in
            if loggedIn { boostBrightness() } else { restoreBrightness() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                viewModel.onAppear()
                if viewModel.isLoggedIn { boostBrightness() }
            case .background, .inactive:
                viewModel.stopTimers()
                // Don't leave the device pinned at full brightness once
                // the user is no longer looking at the QR. Restore in
                // `.inactive` too so a force-quit from Control Center
                // or an incoming call doesn't strand the screen at 1.0.
                restoreBrightness()
            @unknown default:
                viewModel.stopTimers()
            }
        }
    }

    // MARK: - Brightness

    #if os(iOS)
    private func boostBrightness() {
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
    private func boostBrightness() {}
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
                .font(.system(size: 56))
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
                    .padding(TigerDuckTheme.Spacing.md)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))

                SecureField(String(localized: "library_login_password"), text: $viewModel.libPassword)
                    .textContentType(.password)
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
