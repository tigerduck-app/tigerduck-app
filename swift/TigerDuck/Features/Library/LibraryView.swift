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
    @FocusState private var loginField: LoginField?

    private enum LoginField { case username, password }
    #if os(iOS)
    /// Token returned by `PKPassLibrary.requestAutomaticPassPresentationSuppression`.
    /// Held only while the QR page is on-screen so a side-button double-press
    /// can't fire up Apple Pay / Express Transit and cover the library QR.
    @State private var passSuppressionToken: PKSuppressionRequestToken?
    @State private var hostScreen = WeakScreen()
    @State private var brightnessToken = UUID()
    #endif

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 56
    @State private var presenceID = UUID()

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .onAppear { LibraryPagePresence.shared.appear(presenceID) }
        .onDisappear { LibraryPagePresence.shared.disappear(presenceID) }
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
        #if os(iOS)
        .onHostScreenChange { screen in
            hostScreen = WeakScreen(screen)
            guard screen != nil else { return restoreBrightness() }
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
                releaseExpressTransit()
                restoreBrightness()
            @unknown default:
                viewModel.stopTimers()
                releaseExpressTransit()
                restoreBrightness()
            }
        }
    }

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

    private func boostBrightnessForQR() {
        guard let screen = hostScreen.screen, !edrIsAvailable else {
            restoreBrightness()
            return
        }
        LibraryBrightnessCoordinator.shared.boost(screen, token: brightnessToken)
    }

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
                isLoading: viewModel.isLoadingQR,
                lastSynced: .at(viewModel.codeFetchedAt)
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

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

    private var qrSection: some View {
        LibraryQRCodeView(
            qrImage: viewModel.qrCodeImage,
            countdown: viewModel.countdown,
            isLoading: viewModel.isLoadingQR,
            username: viewModel.signedInUsername
        )
    }

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
}

@Observable
final class LibraryPagePresence {
    static let shared = LibraryPagePresence()

    private var pages: Set<UUID> = []

    var isShown: Bool { !pages.isEmpty }

    func appear(_ page: UUID) { pages.insert(page) }

    func disappear(_ page: UUID) { pages.remove(page) }
}
