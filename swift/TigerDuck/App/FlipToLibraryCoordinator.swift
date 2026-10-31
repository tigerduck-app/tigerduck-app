#if os(iOS)
import SwiftUI
import UIKit

private struct FlipToLibraryModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var detector: FlipDetector?

    func body(content: Content) -> some View {
        content
            .onAppear {
                reconcile()
                Self.offerGesture(app: app, waitFirst: true)
            }
            .onChange(of: app.preferences.flipToLibraryEnabled) { _, _ in reconcile() }
            .onChange(of: app.library.isLoggedIn) { _, _ in
                reconcile()
                Self.offerGesture(app: app)
            }
            .onChange(of: app.updateNotifyCoordinator.activeNotifySheet == nil) { _, isClear in
                if isClear { Self.offerGesture(app: app) }
            }
            .onChange(of: LibraryPagePresence.shared.isShown) { _, shown in
                if !shown { Self.offerGesture(app: app) }
            }
            .onChange(of: scenePhase) { _, new in
                // Tear down only on .background. .inactive comes with transient
                // interruptions (Control Center, a banner), and tearing down then would
                // wipe in-progress debounce state and churn CoreMotion several times a minute.
                if new == .background || new == .active {
                    reconcile()
                }
                if new == .active { Self.offerGesture(app: app) }
            }
            .onDisappear {
                detector?.stop()
                detector = nil
            }
    }

    private var shouldBeActive: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            && FlipDetector.isSupported
            && FlipToLibraryGate.isArmed(
                enabled: app.preferences.flipToLibraryEnabled,
                signedInToLibrary: app.library.isLoggedIn,
                inBackground: scenePhase == .background
            )
    }

    private func reconcile() {
        if shouldBeActive {
            if detector == nil {
                // Snapshot app into a local, as Apple advises for environment values,
                // instead of reading the modifier's @Environment wrapper inside this
                // long-lived escaping closure.
                let app = self.app
                detector = FlipDetector { handleFaceDown(app: app) }
            }
            detector?.start()
        } else {
            detector?.stop()
            detector = nil
        }
    }

    private func handleFaceDown(app: AppEnvironment) {
        guard app.preferences.flipToLibraryEnabled, app.library.isLoggedIn else { return }

        guard !Self.isAnyModalPresented() else { return }

        app.router.openFromWidget(.library)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// signed in. A sheet already up, such as the sign-in's own, is waited out for a few seconds,
    /// since SwiftUI rejects the root-level prompt sheet over it; past that the next return asks.
    private static func offerGesture(app: AppEnvironment, attemptsLeft: Int = 10, waitFirst: Bool = false) {
        guard FlipDetector.isSupported,
              FlipToLibraryGate.offersGesture(
                  signedInToLibrary: app.library.isLoggedIn,
                  enabled: app.preferences.flipToLibraryEnabled,
                  asked: FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary),
                  onLibraryPage: LibraryPagePresence.shared.isShown
              )
        else { return }
        let waits = FlipToLibraryGate.offerWaits(
            sheetPresented: isAnyModalPresented(),
            notifySheetPending: app.updateNotifyCoordinator.activeNotifySheet != nil
        )
        guard !waitFirst, !waits else {
            guard attemptsLeft > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                offerGesture(app: app, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        FlipToLibraryPromptPresenter.requestPrompt(app: app)
    }

    private static func isAnyModalPresented() -> Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              let root = window.rootViewController
        else { return false }
        return root.presentedViewController != nil
    }
}

enum FlipToLibraryGate {
    static func isArmed(enabled: Bool, signedInToLibrary: Bool, inBackground: Bool) -> Bool {
        enabled && signedInToLibrary && !inBackground
    }

    static func offersGesture(signedInToLibrary: Bool, enabled: Bool, asked: Bool, onLibraryPage: Bool) -> Bool {
        signedInToLibrary && !enabled && !asked && !onLibraryPage
    }

    /// Whether the offer waits: behind a sheet already up, and behind What's New or the update
    /// prompt, which share the root with it, where two sheets set in one render leave one unshown.
    static func offerWaits(sheetPresented: Bool, notifySheetPending: Bool) -> Bool {
        sheetPresented || notifySheetPending
    }
}

extension View {
    @ViewBuilder
    func flipToLibraryAttached() -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            modifier(FlipToLibraryModifier())
        } else {
            self
        }
    }
}

enum FlipToLibraryPromptPresenter {
    static func requestPrompt(app: AppEnvironment) {
        FirstTriggerPromptCenter.shared.requestIfFirstTime(.flipToLibrary) {
            FirstTriggerPromptContent(
                title: String(localized: "first_trigger_flip_to_library_title"),
                message: String(localized: "settings_flip_to_library_summary"),
                animation: .phoneFlip,
                acceptLabel: String(localized: "first_trigger_flip_to_library_turn_on"),
                declineLabel: String(localized: "permission_warning_action_later"),
                onAccept: { app.preferences.flipToLibraryEnabled = true },
                onDecline: { app.preferences.flipToLibraryEnabled = false }
            )
        }
    }
}
#endif
