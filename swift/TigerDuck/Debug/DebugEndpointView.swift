import Observation
import SwiftUI

/// Screen for picking which backend the app talks to.
///
/// The backend is open source and self-hostable, so this is a supported
/// user-facing setting rather than a developer hatch: any host is accepted,
/// subject to ``PushServerConfig/isOverrideAllowed(_:)``'s transport rule
/// (HTTPS unless the address is private/loopback) and to
/// ``EndpointHealthCheck`` finding a TigerDuck backend actually answering.
///
/// Reached from Settings → Other settings on iPhone (every build), from
/// onboarding's sign-in page, and from the macOS Settings → Developer tab,
/// so it lives in its own file — the rest of `DebugSettingsView.swift`
/// stays iPhone-only and DEBUG-only.
struct DebugEndpointView: View {
    @State private var viewModel = DebugEndpointViewModel()
    #if os(iOS)
    @FocusState private var fieldFocused: Bool
    #endif

    var body: some View {
        Form {
            Section {
                Text(viewModel.effectiveURL)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text(String(localized: "settings_api_endpoint_effective_title"))
            }

            if let stale = viewModel.staleOverride {
                Section {
                    Text(stale)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "settings_api_endpoint_stale_title"))
                } footer: {
                    Text(String(localized: "settings_api_endpoint_stale_description"))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                textField

                if let error = viewModel.validationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if let note = viewModel.statusNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        #if os(iOS)
                        fieldFocused = false
                        #endif
                        Task { await viewModel.save() }
                    } label: {
                        if viewModel.isChecking {
                            // The label swap keeps the row from resizing
                            // mid-probe, and names what the wait is for —
                            // a bare spinner on "Save" reads as a hang
                            // when the address is simply unreachable and
                            // we are sitting out the 10 s timeout.
                            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                                ProgressView()
                                Text(String(localized: "settings_api_endpoint_checking"))
                            }
                        } else {
                            Text(String(localized: "action_save"))
                        }
                    }
                    .disabled(viewModel.isChecking || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button(String(localized: "settings_api_endpoint_reset_action"), role: .destructive) {
                        #if os(iOS)
                        fieldFocused = false
                        #endif
                        viewModel.resetToDefault()
                    }
                    .disabled(viewModel.isChecking || viewModel.storedOverride == nil)
                }
            } header: {
                Text(String(localized: "settings_api_endpoint_change_title"))
            } footer: {
                Text(String(localized: "settings_api_endpoint_https_note"))
            }
        }
        .navigationTitle(String(localized: "settings_api_endpoint"))
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    @ViewBuilder
    private var textField: some View {
        let placeholder = String(localized: "settings_api_endpoint_placeholder")
        #if os(iOS)
        TextField(placeholder, text: $viewModel.draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .font(.system(.body, design: .monospaced))
            .focused($fieldFocused)
            .disabled(viewModel.isChecking)
        #else
        TextField(placeholder, text: $viewModel.draft)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
            .disabled(viewModel.isChecking)
        #endif
    }
}

@MainActor
@Observable
final class DebugEndpointViewModel {
    var draft: String
    private(set) var storedOverride: String?
    private(set) var staleOverride: String?
    private(set) var validationError: String?
    private(set) var statusNote: String?
    private(set) var effectiveURL: String
    /// True while the health probe is in flight. Disables both buttons —
    /// a second Save landing mid-probe would race two writes to the same
    /// Keychain key with no ordering guarantee.
    private(set) var isChecking = false

    init() {
        let current = DebugEndpointStore.currentOverride()
        let stale = DebugEndpointStore.storedButRejectedOverride()
        self.storedOverride = current
        self.staleOverride = stale
        self.draft = current ?? stale ?? ""
        self.effectiveURL = PushServerConfig.resolveServerURL().absoluteString
    }

    func save() async {
        guard !isChecking else { return }
        isChecking = true
        validationError = nil
        statusNote = nil
        defer { isChecking = false }

        let submitted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await DebugEndpointStore.setOverride(submitted) {
        case .success:
            storedOverride = DebugEndpointStore.currentOverride()
            staleOverride = DebugEndpointStore.storedButRejectedOverride()
            if let stored = storedOverride { draft = stored }
            effectiveURL = PushServerConfig.resolveServerURL().absoluteString
            // Say so when we quietly downgraded the scheme, rather than
            // letting the field silently disagree with what was typed.
            let rewritten = submitted.lowercased().hasPrefix("https://")
                && (storedOverride?.lowercased().hasPrefix("http://") ?? false)
            statusNote = rewritten
                ? String(localized: "settings_api_endpoint_saved_rewritten")
                : String(localized: "settings_api_endpoint_saved")
        case .malformed:
            validationError = String(localized: "settings_api_endpoint_error_malformed")
        case .insecure:
            validationError = String(localized: "settings_api_endpoint_error_insecure")
        case .unreachable(let detail):
            validationError = String(
                format: String(localized: "settings_api_endpoint_error_unreachable"),
                detail
            )
        case .notTigerDuck:
            validationError = String(localized: "settings_api_endpoint_error_not_backend")
        case .keychainWriteFailed:
            validationError = String(localized: "settings_api_endpoint_error_save_failed")
        }
    }

    func resetToDefault() {
        DebugEndpointStore.clearOverride()
        storedOverride = nil
        staleOverride = nil
        draft = ""
        validationError = nil
        effectiveURL = PushServerConfig.resolveServerURL().absoluteString
        statusNote = String(localized: "settings_api_endpoint_reset_done")
    }
}
