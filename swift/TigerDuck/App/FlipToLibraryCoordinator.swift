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

        // Don't fight any already-open modal. The first-trigger prompt is
        // a root-level sheet, and presenting it over another sheet (NTUST
        // login, Settings flows, tab editor, in-app browser, feedback,
        // course pickers, etc.) lands in SwiftUI's undefined
        // sheet-stacking territory — SwiftUI may reject or defer the
        // presentation, leaving the prompt invisible while `pending` is
        // already set. Navigation is also unhelpful while a modal covers
        // the TabView: a steady-state flip would switch tabs behind the
        // modal so the user has to dismiss the sheet to find the QR.
        //
        // Sheets are not centrally tracked (most use local `@State` in
        // their owning view), so query UIKit's presentation chain — every
        // SwiftUI sheet is a UIKit modal underneath.
        guard !Self.isAnyModalPresented() else { return }

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
    /// Install the flip-to-library sensor lifecycle on this view. iPhone only.
    func flipToLibraryAttached() -> some View {
        modifier(FlipToLibraryModifier())
    }
}
#endif
