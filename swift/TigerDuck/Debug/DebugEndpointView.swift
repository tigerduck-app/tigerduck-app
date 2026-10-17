import Observation
import SwiftUI

/// Screen for picking which backend the app talks to.
///
/// The backend is open source and self-hostable, so this is a supported user setting, not a
/// developer hatch. Any host is accepted, subject to ``PushServerConfig/isOverrideAllowed(_:)``
/// (HTTPS unless the address is private or loopback) and to ``EndpointHealthCheck`` finding a
/// TigerDuck backend answering. Reached from Settings → Other settings on iPhone (every build),
/// onboarding's sign-in page and the macOS Settings → Developer tab, so it has its own file: the
/// rest of `DebugSettingsView.swift` is iPhone-only and DEBUG-only.
struct DebugEndpointView: View {
    @Environment(AppState.self) private var appState
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
                        Task { await viewModel.save { await appState.endpointChangeSignOutNotes() } }
                    } label: {
                        if viewModel.isChecking {
                            // Swapping the label keeps the row from resizing mid-probe and names
                            // the wait: a bare spinner on "Save" reads as a hang while an
                            // unreachable address sits out the 10 s timeout.
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
                        Task { await viewModel.resetToDefault { await appState.endpointChangeSignOutNotes() } }
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
        .endpointChangeAlert(viewModel)
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
    /// The endpoint store's calls, which tests replace.
    struct Backing {
        var currentOverride: () -> String? = { DebugEndpointStore.currentOverride() }
        var rejectedOverride: () -> String? = { DebugEndpointStore.storedButRejectedOverride() }
        var effectiveURL: () -> URL = { PushServerConfig.resolveServerURL() }
        var check: (String) async -> DebugEndpointStore.CheckResult = { await DebugEndpointStore.check($0) }
        var store: (URL) async -> Bool = { await DebugEndpointStore.store($0) }
        var clear: () -> Void = { DebugEndpointStore.clearOverride() }
    }

    /// A change of endpoint the user is asked about first: a checked endpoint, or nil to go back to
    /// the default.
    struct PendingChange: Equatable {
        let url: URL?
        /// The typed https became http, as a private address takes it.
        var rewritten = false
        /// What the sign-out deletes, in lines the alert adds.
        var notes: [String] = []
    }

    var draft: String
    private(set) var storedOverride: String?
    private(set) var staleOverride: String?
    private(set) var validationError: String?
    private(set) var statusNote: String?
    private(set) var effectiveURL: String
    /// True while the health probe or a confirmed change is in flight. Disables both buttons: a
    /// second Save landing mid-probe would race two writes to the same Keychain key with no
    /// ordering guarantee.
    private(set) var isChecking = false
    /// The change ``endpointChangeAlert(_:)`` asks about.
    var pendingChange: PendingChange?
    private let backing: Backing

    init(backing: Backing = Backing()) {
        self.backing = backing
        let current = backing.currentOverride()
        let stale = backing.rejectedOverride()
        self.storedOverride = current
        self.staleOverride = stale
        self.draft = current ?? stale ?? ""
        self.effectiveURL = backing.effectiveURL().absoluteString
    }

    /// Checks the typed endpoint. One that would move the app to another server waits for the
    /// user's answer in ``pendingChange``, with `notes`; the one in use already is saved at once.
    func save(notes: () async -> [String] = { [] }) async {
        guard !isChecking else { return }
        isChecking = true
        validationError = nil
        statusNote = nil
        defer { isChecking = false }

        let submitted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await backing.check(submitted) {
        case .accepted(let url):
            // Say so when the scheme was downgraded, rather than letting the field silently
            // disagree with what was typed.
            let change = PendingChange(
                url: url, rewritten: submitted.lowercased().hasPrefix("https://") && url.scheme == "http"
            )
            if url == backing.effectiveURL() {
                await apply(change)
            } else {
                var asked = change
                asked.notes = await notes()
                pendingChange = asked
            }
        case .rejected(let reason):
            validationError = Self.message(for: reason)
        }
    }

    /// Asks before going back to the default, which moves the app to another server too.
    func resetToDefault(notes: () async -> [String] = { [] }) async {
        pendingChange = PendingChange(url: nil, notes: await notes())
    }

    /// Makes `change` once the user agreed. `signOut` comes first and is waited for: the session
    /// and its last calls belong to the endpoint in use, and no other server issued them.
    func confirm(_ change: PendingChange, signingOut signOut: () async -> Void) async {
        pendingChange = nil
        guard !isChecking else { return }
        isChecking = true
        validationError = nil
        statusNote = nil
        defer { isChecking = false }

        await signOut()
        await apply(change)
    }

    private func apply(_ change: PendingChange) async {
        if let url = change.url {
            guard await backing.store(url) else {
                validationError = String(localized: "settings_api_endpoint_error_save_failed")
                return
            }
            statusNote = change.rewritten
                ? String(localized: "settings_api_endpoint_saved_rewritten")
                : String(localized: "settings_api_endpoint_saved")
        } else {
            backing.clear()
            statusNote = String(localized: "settings_api_endpoint_reset_done")
        }
        storedOverride = backing.currentOverride()
        staleOverride = backing.rejectedOverride()
        draft = storedOverride ?? ""
        effectiveURL = backing.effectiveURL().absoluteString
    }

    private static func message(for reason: DebugEndpointStore.Rejection) -> String {
        switch reason {
        case .malformed:
            String(localized: "settings_api_endpoint_error_malformed")
        case .insecure:
            String(localized: "settings_api_endpoint_error_insecure")
        case .unreachable(let detail):
            String(format: String(localized: "settings_api_endpoint_error_unreachable"), detail)
        case .notTigerDuck:
            String(localized: "settings_api_endpoint_error_not_backend")
        }
    }
}

extension View {
    /// Asks before the API endpoint changes, and on Change signs out of every account first
    /// (``DebugEndpointViewModel/confirm(_:signingOut:)``).
    func endpointChangeAlert(_ viewModel: DebugEndpointViewModel) -> some View {
        modifier(EndpointChangeAlert(viewModel: viewModel))
    }
}

private struct EndpointChangeAlert: ViewModifier {
    let viewModel: DebugEndpointViewModel
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "settings_api_endpoint_change_alert_title"),
            isPresented: Binding(
                get: { viewModel.pendingChange != nil },
                set: { if !$0 { viewModel.pendingChange = nil } }
            ),
            presenting: viewModel.pendingChange
        ) { change in
            Button(String(localized: "settings_api_endpoint_change_alert_confirm"), role: .destructive) {
                Task { await viewModel.confirm(change) { await appState.signOutOfEveryAccount() } }
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: { change in
            Text(([String(localized: "settings_api_endpoint_change_alert_message")] + change.notes)
                .joined(separator: "\n\n"))
        }
    }
}
