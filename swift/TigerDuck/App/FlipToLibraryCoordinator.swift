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
                // Only tear down on .background — .inactive happens for
                // transient interruptions (Control Center pull, banner) and
                // tearing down on those would wipe in-progress debounce
                // state and churn CoreMotion several times per minute.
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
                // Capture appState explicitly rather than relying on the
                // modifier struct's @Environment wrapper inside an escaping
                // closure (Apple's guidance: snapshot env values into local
                // bindings before passing into long-lived closures).
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

        // Don't fight an already-open root-level sheet. The first-trigger
        // host attaches to MainTabView while the NTUST login host attaches
        // to ContentView; presenting our sheet over login would land in
        // SwiftUI's undefined sheet-stacking territory. Navigation is also
        // unhelpful while a modal is up.
        guard !appState.isShowingNTUSTLoginSheet else { return }

        // First-trigger UX: the toggle defaults to ON so the user discovers
        // the feature on their first accidental flip. The prompt explains
        // what just happened and lets them keep or disable it — no
        // navigation happens on this first event so the user is not
        // jump-scared into an unfamiliar tab.
        if !FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary) {
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
            return
        }

        // Steady-state: navigate. Library session is not a registration gate
        // — when logged out, the existing `openFromWidget(.library)` drain
        // surfaces the login flow inside the Library tab, which is the
        // correct UX (Android silently no-ops, but the iOS Library view
        // already handles the unauth case gracefully).
        appState.openFromWidget(.library)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

extension View {
    /// Install the flip-to-library sensor lifecycle on this view. iPhone only.
    func flipToLibraryAttached() -> some View {
        modifier(FlipToLibraryModifier())
    }
}
#endif
