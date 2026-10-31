#if DEBUG && os(iOS)
import SwiftUI

struct TriggersDebugView: View {
    @Environment(AppState.self) private var appState
    @State private var statusMessage: String?
    @State private var armedTick = UUID()
    @State private var samplePresentation: WhatsNewPresentation?

    var body: some View {
        Form {
            Section {
                Button("Trigger What's New on next open") {
                    AppUserDefaults.standard.removeObject(
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

            Section {
                Button("Flip offer after 3 sec") {
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
                    Text("Requires Flip-to-Library to be off. Turn it off in Settings → Library first.")
                } else {
                    Text("Resets the answered flag, waits 3 seconds, then replays the prompt a library sign-in shows.")
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
    }

    private var canTriggerFlip: Bool {
        !appState.flipToLibraryEnabled
    }

    private func triggerFirstLibraryFlip() {
        FirstTriggerPromptCenter.shared.reset(.flipToLibrary)
        statusMessage = "Reset first-trigger flag. Prompt fires in 3 seconds."
        TriggersDebugArming.shared.armFlipPrompt(appState: appState) { [self] in
            armedTick = UUID()
        }
        armedTick = UUID()
    }
}

@MainActor
final class TriggersDebugArming {
    static let shared = TriggersDebugArming()
    private init() {}

    private var flipTask: Task<Void, Never>?
    var isFlipArmed: Bool { flipTask != nil }

    func armFlipPrompt(appState: AppState, completion: @escaping () -> Void) {
        guard flipTask == nil else {
            completion()
            return
        }
        flipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                FlipToLibraryPromptPresenter.requestPrompt(appState: appState)
            }
            self?.flipTask = nil
            completion()
        }
    }
}
#endif
