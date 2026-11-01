import SwiftUI
#if os(iOS)
import PassKit
#endif

struct LibraryPageLifecycle: ViewModifier {
    let viewModel: LibraryViewModel

    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var passSuppressionToken: PKSuppressionRequestToken?
    @State private var hostScreen = WeakScreen()
    @State private var brightnessToken = UUID()
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear {
                viewModel.onLibraryStateChanged = { app.library.noteChange() }
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
    /// Reads `potentialEDRHeadroom`, which Apple documents as queryable before any
    /// EDR content is shown, and which is `1.0` on SDR panels. `currentEDRHeadroom`
    /// reads `1.0` until the Metal layer draws, so it would boost every device. A
    /// thermally throttled EDR panel shows the QR at SDR white, which still scans.
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
}
