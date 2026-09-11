#if os(macOS)
import SwiftUI
import UserNotifications

// Developer tab and its clock-override view-model. DEBUG builds only —
// the whole file body is inside `#if DEBUG`, so a release build compiles
// it away and `MacSettingsScene` drops the tab with it. Plain `//`, not
// `///`: the next thing down is `#if DEBUG`, not a declaration.
#if DEBUG
/// Mac surface for the debug clock override. Mirrors iPhone's
/// DebugSettingsView, minus the "fake local notification" button —
/// notifications are intentionally absent from the Mac app.
struct MacDeveloperSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = MacDebugClockViewModel()
    @State private var snapshot: PushDiagnostic?
    @State private var refreshTimer: Timer?

    var body: some View {
        Form {
            Section("Time override") {
                Toggle("Use fake time", isOn: Binding(
                    get: { viewModel.enabled },
                    set: { viewModel.setEnabled($0) }
                ))

                DatePicker(
                    "Date & time",
                    selection: Binding(
                        get: { viewModel.draftInstant },
                        set: { viewModel.setDraftInstant($0) }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .disabled(!viewModel.enabled)

                Picker("Mode", selection: Binding(
                    get: { viewModel.frozen },
                    set: { viewModel.setFrozen($0) }
                )) {
                    Text("Frozen").tag(true)
                    Text("Ticking").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.enabled)
            }

            Section("Effective now") {
                Text(viewModel.effectiveNow.formatted(date: .complete, time: .standard))
                    .font(.system(.body, design: .monospaced))
            }

            Section {
                Text("Time override is mirrored across Home, Class Table, and Calendar. Notifications are disabled on macOS — there is no equivalent of the iPhone fake-push button here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Notes")
            }

            // MARK: Server failure simulation

            Section("Server failure simulation") {
                ForEach(ServerKind.allCases) { server in
                    Picker(server.label, selection: Binding(
                        get: { ServerFailureSimulator.shared.failure(for: server) },
                        set: { ServerFailureSimulator.shared.failures[server] = $0 }
                    )) {
                        ForEach(SimulatedFailure.allCases) { failure in
                            Text(failure.label).tag(failure)
                        }
                    }
                }
                HStack {
                    Button("Reset all") {
                        ServerFailureSimulator.shared.failures.removeAll()
                    }
                    Spacer()
                    Button("Reset statuses") {
                        ServerStatusTracker.shared.statuses.removeAll()
                    }
                }
            }

            // MARK: TigerSync status
            //
            // Raw `PushDiagnostic` for engineering use — the corresponding
            // iOS page is `TigerSyncStatusView`. The user-facing TigerSync
            // screen (inlined above in `MacAccountSettingsView`) keeps only
            // device-registration status and the latest error.
            Section("TigerSync status") {
                if let s = snapshot {
                    LabeledContent("Enabled") { Text(s.enabled ? "true" : "false") }
                    LabeledContent("Started") { Text(s.isStarted ? "true" : "false") }
                    LabeledContent("Live Activities enabled") { Text(s.liveActivitiesEnabled ? "true" : "false") }
                    LabeledContent("Notification auth status") { Text(notificationStatusText(s.notificationAuthStatus)) }
                    LabeledContent("PTS token length") { Text("\(s.registration.ptsTokenLength)") }
                    LabeledContent("Device token length") { Text("\(s.registration.deviceTokenLength)") }
                    LabeledContent("Device ID") {
                        Text(s.uuid)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Server URL") {
                        Text(s.resolvedServerURL.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.observeEffectiveNow() }
        .task { await refreshSnapshot() }
        .onAppear {
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in await refreshSnapshot() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func refreshSnapshot() async {
        snapshot = await appState.pushCoordinator.currentSnapshot()
    }

    private func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not determined"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }
}

@MainActor
@Observable
private final class MacDebugClockViewModel {
    var enabled: Bool
    var draftInstant: Date
    var frozen: Bool
    private(set) var effectiveNow: Date

    init() {
        let current = DebugClockController.shared.currentOverride()
        self.enabled = current != nil
        self.draftInstant = current?.instant ?? Date()
        self.frozen = current?.frozen ?? true
        self.effectiveNow = AppClock.now()
    }

    func observeEffectiveNow() async {
        effectiveNow = AppClock.now()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            effectiveNow = AppClock.now()
        }
    }

    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        if newValue {
            pushOverride()
        } else {
            DebugClockController.shared.setOverride(nil)
        }
    }

    func setDraftInstant(_ newValue: Date) {
        draftInstant = newValue
        if enabled { pushOverride() }
    }

    func setFrozen(_ newValue: Bool) {
        frozen = newValue
        if enabled { pushOverride() }
    }

    private func pushOverride() {
        let override = ClockOverride(
            instant: draftInstant,
            frozen: frozen,
            savedAtReal: Date()
        )
        DebugClockController.shared.setOverride(override)
    }
}
#endif
#endif
