#if os(iOS)
import SwiftUI
import UIKit

private struct FlipToLibraryModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var detector: FlipDetector?

    func body(content: Content) -> some View {
        content
            .onAppear {
                reconcile()
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
            .onChange(of: LibraryPagePresence.shared.isShown) { _, shown in
                if !shown { Self.offerGesture(appState: appState) }
            }
            .onChange(of: scenePhase) { _, new in
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
        guard appState.flipToLibraryEnabled, appState.isLibraryLoggedIn else { return }

        guard !Self.isAnyModalPresented() else { return }

        appState.openFromWidget(.library)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private static func offerGesture(appState: AppState, attemptsLeft: Int = 10, waitFirst: Bool = false) {
        guard FlipDetector.isSupported,
              FlipToLibraryGate.offersGesture(
                  signedInToLibrary: appState.isLibraryLoggedIn,
                  enabled: appState.flipToLibraryEnabled,
                  asked: FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary),
                  onLibraryPage: LibraryPagePresence.shared.isShown
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
    static func requestPrompt(appState: AppState) {
        FirstTriggerPromptCenter.shared.requestIfFirstTime(.flipToLibrary) {
            FirstTriggerPromptContent(
                title: String(localized: "first_trigger_flip_to_library_title"),
                message: String(localized: "settings_flip_to_library_summary"),
                animation: .phoneFlip,
                acceptLabel: String(localized: "first_trigger_flip_to_library_turn_on"),
                declineLabel: String(localized: "permission_warning_action_later"),
                onAccept: { appState.flipToLibraryEnabled = true },
                onDecline: { appState.flipToLibraryEnabled = false }
            )
        }
    }
}
#endif
