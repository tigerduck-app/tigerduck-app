#if os(iOS)
import SwiftUI
import UIKit

/// Wires `FlipDetector` into the app, gated by user opt-in, the parent
/// library feature toggle, scene phase, and idiom. On a successful face-down
/// gesture, routes through the existing widget-destination drain so tab
/// switching (and the "library disabled" fall-through) stays in one place.
///
/// Attach to the root tab view via `.flipToLibraryAttached()`.
private struct FlipToLibraryModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var detector: FlipDetector?

    func body(content: Content) -> some View {
        content
            .onAppear { reconcile() }
            .onChange(of: appState.flipToLibraryEnabled) { _, _ in reconcile() }
            .onChange(of: appState.libraryFeatureEnabled) { _, _ in reconcile() }
            .onChange(of: scenePhase) { _, new in
                // Tear down only on .background. .inactive comes with transient
                // interruptions (Control Center, a banner), and tearing down then would
                // wipe in-progress debounce state and churn CoreMotion several times a minute.
                if new == .background || new == .active {
                    reconcile()
                }
            }
            .onDisappear {
                detector?.stop()
                detector = nil
            }
    }

    private var shouldBeActive: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            && FlipDetector.isSupported
            && appState.flipToLibraryEnabled
            && appState.libraryFeatureEnabled
            && scenePhase != .background
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
        guard appState.libraryFeatureEnabled,
              appState.flipToLibraryEnabled else { return }

        // Skip while a modal is up: SwiftUI may reject or defer the root-level prompt sheet
        // over it, leaving `pending` set, and a tab switch would land behind it. Sheets are
        // not tracked centrally, so ask UIKit's presentation chain; each one is a UIKit modal.
        guard !Self.isAnyModalPresented() else { return }

        // The toggle defaults to on so users discover the feature on their first
        // accidental flip. That flip shows a prompt to keep or disable it and does
        // not navigate, so the user is not thrown into an unfamiliar tab.
        if !FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary) {
            FlipToLibraryPromptPresenter.requestFirstTriggerPrompt(appState: appState)
            return
        }

        // Navigate even without a library session: the `openFromWidget(.library)`
        // drain shows the login flow inside the Library tab. Android no-ops here,
        // but the iOS Library view handles the signed-out case.
        appState.openFromWidget(.library)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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

/// Shared builder for the flip-to-library first-trigger prompt content.
/// Extracted from ``FlipToLibraryModifier`` so the Debug → Triggers page
/// can replay the same prompt as a real face-down gesture would, without
/// having to duplicate the localization keys or the callback semantics.
enum FlipToLibraryPromptPresenter {
    /// Queue the first-trigger prompt for the flip gesture. No-ops when
    /// the prompt has already been seen — call
    /// `FirstTriggerPromptCenter.shared.reset(.flipToLibrary)` first if
    /// you specifically want to re-test the first-trigger surface
    /// (debug Triggers page does this).
    static func requestFirstTriggerPrompt(appState: AppState) {
        FirstTriggerPromptCenter.shared.requestIfFirstTime(.flipToLibrary) {
            FirstTriggerPromptContent(
                title: String(localized: "first_trigger_flip_to_library_title"),
                message: String(localized: "first_trigger_flip_to_library_message"),
                animation: .phoneFlip,
                acceptLabel: String(localized: "first_trigger_flip_to_library_keep"),
                declineLabel: String(localized: "first_trigger_flip_to_library_turn_off"),
                onAccept: { /* leave toggle on, no nav this time */ },
                onDecline: { appState.flipToLibraryEnabled = false }
            )
        }
    }
}
#endif
