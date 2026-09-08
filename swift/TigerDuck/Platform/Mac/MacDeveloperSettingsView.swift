#if os(macOS)
import SwiftUI

// Developer tab and its clock-override view-model. DEBUG builds only —
// the whole file body is inside `#if DEBUG`, so a release build compiles
// it away and `MacSettingsScene` drops the tab with it. Plain `//`, not
// `///`: the next thing down is `#if DEBUG`, not a declaration.
#if DEBUG
/// Mac surface for the debug clock override. Mirrors iPhone's
/// DebugSettingsView, minus the "fake local notification" button —
/// notifications are intentionally absent from the Mac app.
struct MacDeveloperSettingsView: View {
    @State private var viewModel = MacDebugClockViewModel()

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

            // MARK: API endpoint

            Section {
                Text(endpointVM.effectiveURL)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text(String(localized: "settings_api_endpoint_effective_title"))
            }

            // Surface a previously-saved override that no longer passes
            // the allowlist (e.g. allowlist tightened in a later build).
            // Mirrors the iOS DebugEndpointView — without this section,
            // the Mac user only sees the effective URL silently fall
            // through to the next priority with no breadcrumb explaining
            // why their saved override stopped taking effect.
            if let stale = endpointVM.staleOverride {
                Section {
                    Text(stale)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text(String(localized: "settings_api_endpoint_stale_title"))
                } footer: {
                    Text(String(localized: "settings_api_endpoint_stale_description"))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                // Show the example URL above the field instead of as the
                // TextField's leading label — on macOS Form's grouped
                // style the title-string initializer renders a left-side
                // label that eats horizontal space and pushes the input
                // into a sliver. Putting the hint on its own row keeps
                // the input field full-width and easier to paste into.
                Text(verbatim: String(localized: "settings_api_endpoint_placeholder"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField(
                    "",
                    text: $endpointVM.draft,
                    prompt: Text(verbatim: String(localized: "settings_api_endpoint_placeholder"))
                )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .disabled(endpointVM.isChecking)

                if let error = endpointVM.validationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if let note = endpointVM.statusNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        Task { await endpointVM.save() }
                    } label: {
                        if endpointVM.isChecking {
                            Text(String(localized: "settings_api_endpoint_checking"))
                        } else {
                            Text(String(localized: "action_save"))
                        }
                    }
                    .disabled(endpointVM.isChecking || endpointVM.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button(String(localized: "settings_api_endpoint_reset_action"), role: .destructive) {
                        endpointVM.resetToDefault()
                    }
                    .disabled(endpointVM.isChecking || endpointVM.storedOverride == nil)
                }
            } header: {
                Text(String(localized: "settings_api_endpoint_change_title"))
            } footer: {
                Text(String(localized: "settings_api_endpoint_https_note"))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.observeEffectiveNow() }
    }

    @State private var endpointVM = DebugEndpointViewModel()
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
