#if DEBUG && os(iOS)
import SwiftUI

/// Developer-only screen for re-triggering one-shot UI surfaces that are
/// otherwise hard to retest after they've been dismissed once. Reached
/// from `Settings → Developer → Triggers`; entry point and this file
/// are both `#if DEBUG` so Release builds never see either.
///
/// Each section maps to a specific surface and uses the smallest hook
/// that simulates a real fire — clearing a persisted gate, arming a
/// debug-only flag, or replaying the same closure a real sensor would.
/// Avoid going around the production code paths: a trigger that takes
/// a shortcut here can mask real-world bugs in the surface it's
/// supposed to be testing.
struct TriggersDebugView: View {
    @Environment(AppState.self) private var appState
    @State private var statusMessage: String?
    /// Tick that refreshes the disabled-button state when the static
    /// armed-flag flips. The actual task lives on
    /// ``TriggersDebugArming`` (a MainActor singleton) so it survives
    /// this view being popped and re-pushed — `@State` is destroyed on
    /// pop, which is what allowed the same button to spawn a second
    /// in-flight task when the user navigated away and back.
    @State private var armedTick = UUID()

    var body: some View {
        Form {
            // MARK: - What's New
            Section {
                Button("Trigger What's New on next open") {
                    UserDefaults.standard.removeObject(
                        forKey: AppConstants.UserDefaultsKeys.lastShownWhatsNewVersion
                    )
                    statusMessage = "Cleared lastShownWhatsNewVersion. Cold-launch or scene-active fires the sheet."
                }
            } header: {
                Text("What's New")
            } footer: {
                Text("Clears the seen flag so `evaluateWhatsNewOnLaunch()` re-fires the latest registered entry on the next launch / foreground.")
            }

            // MARK: - Update prompt
            Section {
                Button("Trigger Update Available on next open") {
                    UpdateNotifyCoordinator.armDebugSimulatedUpdate()
                    statusMessage = "Armed synthetic update prompt. Cold-launch or scene-active fires it once."
                }
                if UpdateNotifyCoordinator.isDebugSimulatedUpdateArmed {
                    Text("Currently armed — relaunch or background/foreground to fire.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Update prompt")
            } footer: {
                Text("Skips iTunes Lookup and surfaces a fake `PendingUpdate` (v99.0.0 → apps.apple.com). One-shot per arm.")
            }

            // MARK: - Flip-to-Library first trigger
            Section {
                Button("First library flip after 3 sec") {
                    triggerFirstLibraryFlip()
                }
                .disabled(!canTriggerFlip || TriggersDebugArming.shared.isFlipArmed)
                if TriggersDebugArming.shared.isFlipArmed {
                    Text("Flip prompt scheduled. Stay in this tab or navigate to any tab — it'll fire root-level.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Flip to Library")
            } footer: {
                if !canTriggerFlip {
                    Text("Requires both Library and Flip-to-Library to be enabled. Toggle them on in Settings → Other settings first.")
                } else {
                    Text("Resets the first-trigger seen flag, waits 3 seconds, then replays the same prompt a real face-down gesture would surface.")
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Triggers")
        // Intentionally NOT cancelling the arming task on disappear: the
        // 3-second delay exists so navigation away from this page is part
        // of the test (which tab the prompt overlays is part of what's
        // being verified). The arming lives on `TriggersDebugArming` so
        // it survives this view being popped — re-entering the page
        // shows the disabled-button + "scheduled" footer instead of
        // letting a second tap spawn a duplicate prompt.
    }

    private var canTriggerFlip: Bool {
        appState.libraryFeatureEnabled && appState.flipToLibraryEnabled
    }

    private func triggerFirstLibraryFlip() {
        FirstTriggerPromptCenter.shared.reset(.flipToLibrary)
        statusMessage = "Reset first-trigger flag. Prompt fires in 3 seconds."
        TriggersDebugArming.shared.armFlipPrompt(appState: appState) { [self] in
            // Rotate the tick so the body re-evaluates the disabled
            // state if the view is still mounted when the timer fires.
            armedTick = UUID()
        }
        armedTick = UUID()
    }
}

/// MainActor singleton that owns the debug "arm flip prompt" task
/// beyond a single view's lifetime. `TriggersDebugView`'s `@State` is
/// destroyed when the user pops the page, which previously let a second
/// tap on re-entry spawn a duplicate in-flight task. Anchoring the task
/// here keeps the "scheduled" indication consistent across navigation.
@MainActor
final class TriggersDebugArming {
    static let shared = TriggersDebugArming()
    private init() {}

    private var flipTask: Task<Void, Never>?
    var isFlipArmed: Bool { flipTask != nil }

    /// Schedule the flip-to-library first-trigger prompt to fire after
    /// 3 seconds. No-ops if a previous arm is still in flight.
    /// `completion` is invoked on the MainActor when the task ends
    /// (either fired or already-armed-skip) so the caller can refresh
    /// any view-local state.
    func armFlipPrompt(appState: AppState, completion: @escaping () -> Void) {
        guard flipTask == nil else {
            completion()
            return
        }
        flipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                FlipToLibraryPromptPresenter.requestFirstTriggerPrompt(appState: appState)
            }
            self?.flipTask = nil
            completion()
        }
    }
}
#endif
