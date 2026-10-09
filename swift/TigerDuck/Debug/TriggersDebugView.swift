#if DEBUG && os(iOS)
import SwiftUI

/// Developer-only screen for re-triggering one-shot UI surfaces that are hard to retest once
/// dismissed, reached from `Settings → Developer → Triggers`. The entry point and this file are
/// both `#if DEBUG`, so Release builds see neither.
///
/// Each section uses the smallest hook that simulates a real fire: clearing a persisted gate,
/// arming a debug-only flag, or replaying the closure a real sensor would call. Do not go around
/// the production code paths; a shortcut here can mask real bugs in the surface under test.
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
    @State private var samplePresentation: WhatsNewPresentation?

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
                Button("Preview sample flow") {
                    samplePresentation = WhatsNewSampleFlow.presentation()
                }
            } header: {
                Text("What's New")
            } footer: {
                Text("Trigger clears the seen flag so `evaluateWhatsNewOnLaunch(in:)` re-fires on the next launch / foreground — with no flag that's the running version's pages and summary only. Preview shows one page of every template plus a summary, writing no real setting.")
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
        .sheet(item: $samplePresentation) { presentation in
            WhatsNewFlowView(presentation: presentation) {
                samplePresentation = nil
            }
            .whatsNewSheetPresentation()
        }
        // The arming task is not cancelled on disappear: the 3-second delay lets the tester leave
        // the page, since which tab the prompt overlays is under test. `TriggersDebugArming` holds
        // it across a pop, so re-entry shows it scheduled and blocks a second prompt.
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
