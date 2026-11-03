import SwiftUI

struct LibraryView: View {
    var embedded = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var viewModel = LibraryViewModel()
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
        .modifier(LibraryPageLifecycle(viewModel: viewModel))
        .pageMenu(.library)
    }

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
                    LibraryLoginForm(viewModel: viewModel)
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
            HStack(spacing: TigerDuckTheme.Spacing.lg) {
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
                PageMenuButton(page: .library) { LibraryMenuItems() }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            let retry: (() -> Void)? = viewModel.isWaitingToRetry ? { viewModel.retryNow() } : nil
            LibraryErrorBanner(message: error, retry: retry)
        }
    }

    private var qrSection: some View {
        LibraryQRCodeView(
            qrImage: viewModel.qrCodeImage,
            countdown: viewModel.countdown,
            isLoading: viewModel.isLoadingQR,
            username: viewModel.signedInUsername,
            showsCountdown: !viewModel.isWaitingToRetry
        )
    }
}

struct LibraryMenuItems: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.settingsState) private var state

    var body: some View {
        @Bindable var preferences = preferences
        if SettingsRow.flipToLibrary.isShown(in: state) {
            Section {
                PageMenuToggle(
                    row: .flipToLibrary,
                    isOn: LibrarySettingsView.flipSwitch($preferences.flipToLibraryEnabled, signedIn: state.library.isSignedIn)
                )
            }
        }
        Section { FullSettingsButton() }
        LibrarySignOutSection()
    }
}

struct LibraryErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
            if let retry {
                Spacer(minLength: TigerDuckTheme.Spacing.sm)
                Button(String(localized: "action_retry"), action: retry)
                    .font(.subheadline.weight(.semibold))
                    .modifier(GlassTextButtonModifier())
                    .fixedSize()
            }
        }
        .cardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
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
