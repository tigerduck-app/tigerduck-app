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
                Text("Effective endpoint")
            } footer: {
                Text("Resolved by PushServerConfig — Keychain override → UserDefaults override → Secrets.plist → localhost fallback.")
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
                    Text("Stored override no longer accepted")
                } footer: {
                    Text("The allowlist tightened since this value was saved, so it's being ignored and the resolver is using the next priority. Save a new value or clear the override.")
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
                Text(verbatim: "http://192.168.X.X:40000/v2")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("", text: $endpointVM.draft, prompt: Text(verbatim: "http://192.168.X.X:40000/v2"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .labelsHidden()

                if let error = endpointVM.validationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Save") { endpointVM.save() }
                        .disabled(endpointVM.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Clear override", role: .destructive) { endpointVM.clear() }
                        .disabled(endpointVM.storedOverride == nil)
                }
            } header: {
                Text("Override (Keychain — survives reinstall)")
            } footer: {
                Text("Allowed: api.tigerduck.app (apex + any subdomain) over HTTPS, loopback, or any RFC1918 IPv4. Pointing a Debug build at the prod apex breaks push (apns_env mismatch — sandbox tokens get rejected at registration), but read-side API surfaces still work for testing.")
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
