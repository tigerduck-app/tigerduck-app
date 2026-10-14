#if os(iOS)
import SwiftUI
import UIKit

/// Wires `FlipDetector` into the app, gated by the user's switch, scene phase
/// and idiom. A face-down gesture goes through the widget-destination drain,
/// so the tab switching stays in one place.
///
/// Attach to the root tab view via `.flipToLibraryAttached()`.
private struct FlipToLibraryModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var detector: FlipDetector?

    func body(content: Content) -> some View {
        content
            .onAppear {
                reconcile()
                // Not in this pass: the launch sets What's New in the same one.
                Self.offerGesture(appState: appState, waitFirst: true)
            }
            .onChange(of: appState.flipToLibraryEnabled) { _, _ in reconcile() }
            .onChange(of: appState.isLibraryLoggedIn) { _, _ in
                reconcile()
                Self.offerGesture(appState: appState)
            }
            .onChange(of: appState.updateNotifyCoordinator.activeNotifySheet == nil) { _, isClear in
                if isClear { Self.offerGesture(appState: appState) }
            }
            .onChange(of: appState.visibleLibraryPages == 0) { _, leftLibrary in
                if leftLibrary { Self.offerGesture(appState: appState) }
            }
            .onChange(of: scenePhase) { _, new in
                // Tear down only on .background. .inactive comes with transient
                // interruptions (Control Center, a banner), and tearing down then would
                // wipe in-progress debounce state and churn CoreMotion several times a minute.
                if new == .background || new == .active {
                    reconcile()
                }
                if new == .active { Self.offerGesture(appState: appState) }
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
                enabled: appState.flipToLibraryEnabled,
                signedInToLibrary: appState.isLibraryLoggedIn,
                inBackground: scenePhase == .background
            )
    }

    private func reconcile() {
        if shouldBeActive {
            if detector == nil {
                // Snapshot appState into a local, as Apple advises for environment values,
                // instead of reading the modifier's @Environment wrapper inside this
                // long-lived escaping closure.
                let appState = self.appState
                detector = FlipDetector { handleFaceDown(appState: appState) }
            }
            detector?.start()
        } else {
            detector?.stop()
            detector = nil
        }
    }

    private func handleFaceDown(appState: AppState) {
        // Fire-time guards: settings can flip while a sensor event was in
        // flight, and the library session can come and go independently of
        // the registration gate.
        guard appState.flipToLibraryEnabled, appState.isLibraryLoggedIn else { return }

        // Skip while a modal is up: a tab switch would land behind it. Sheets are not tracked
        // centrally, so ask UIKit's presentation chain; each one is a UIKit modal.
        guard !Self.isAnyModalPresented() else { return }

        appState.openFromWidget(.library)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Asks once whether to turn the gesture on, after a library sign-in or at a launch already
    /// signed in. A sheet already up, such as the sign-in's own, is waited out for a few seconds,
    /// since SwiftUI rejects the root-level prompt sheet over it; past that the next return asks.
    /// What's New and the update prompt are waited out to their end, which asks again.
    private static func offerGesture(appState: AppState, attemptsLeft: Int = 10, waitFirst: Bool = false) {
        guard FlipDetector.isSupported,
              FlipToLibraryGate.offersGesture(
                  signedInToLibrary: appState.isLibraryLoggedIn,
                  enabled: appState.flipToLibraryEnabled,
                  asked: FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary),
                  onLibraryPage: appState.visibleLibraryPages > 0
              )
        else { return }
        let waits = FlipToLibraryGate.offerWaits(
            sheetPresented: isAnyModalPresented(),
            notifySheetPending: appState.updateNotifyCoordinator.activeNotifySheet != nil
        )
        guard !waitFirst, !waits else {
            guard attemptsLeft > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                offerGesture(appState: appState, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        FlipToLibraryPromptPresenter.requestPrompt(appState: appState)
    }

    /// True when the foreground-active window has anything modally
    /// presented above its root. Walks the presentation chain because the
    /// topmost modal is the one that would conflict — sheets-over-sheets
    /// are rare in this app but the walk is cheap.
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

/// Whether the flip listens: with the switch on and a library account signed in, as the switch in
/// Settings shows it, and the app not in the background.
enum FlipToLibraryGate {
    static func isArmed(enabled: Bool, signedInToLibrary: Bool, inBackground: Bool) -> Bool {
        enabled && signedInToLibrary && !inBackground
    }

    /// Whether to ask to turn the gesture on: signed in to the library, with the switch off and
    /// the question never answered. Not over the Library page, where the sheet would cover the
    /// code someone just signed in to show; leaving the page asks.
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
    /// Install the flip-to-library sensor lifecycle on this view. iPhone
    /// only — on iPad the modifier is intentionally never attached, so no
    /// scene-phase / preference observers fire and no `FlipDetector` is
    /// ever instantiated. This matches the hidden Settings row in
    /// `LibrarySettingsView`: on iPad the feature does not exist at all.
    /// The inner `shouldBeActive` guard keeps the iPhone-side belt for
    /// `FlipDetector.isSupported` and runtime state.
    @ViewBuilder
    func flipToLibraryAttached() -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            modifier(FlipToLibraryModifier())
        } else {
            self
        }
    }
}

/// The question that offers the flip gesture, shared with the Debug → Triggers page, which
/// replays it after `FirstTriggerPromptCenter.shared.reset(.flipToLibrary)`.
enum FlipToLibraryPromptPresenter {
    /// No-ops once the question has been answered.
    static func requestPrompt(appState: AppState) {
        FirstTriggerPromptCenter.shared.requestIfFirstTime(.flipToLibrary) {
            FirstTriggerPromptContent(
                title: String(localized: "first_trigger_flip_to_library_title"),
                message: String(localized: "settings_flip_to_library_summary"),
                animation: .phoneFlip,
                acceptLabel: String(localized: "first_trigger_flip_to_library_turn_on"),
                declineLabel: String(localized: "permission_warning_action_later"),
                onAccept: { appState.flipToLibraryEnabled = true },
                // Stored, so Maybe later is not read as 2.4's Keep on, which left the switch unset.
                onDecline: { appState.flipToLibraryEnabled = false }
            )
        }
    }
}
#endif
