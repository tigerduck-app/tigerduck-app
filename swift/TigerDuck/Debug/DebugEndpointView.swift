#if DEBUG
import Observation
import SwiftUI

/// Developer-only screen for picking which backend the app talks to.
/// Survives uninstall because the value lives in Keychain
/// (`DebugEndpointStore`). All writes go through
/// `PushServerConfig.isOverrideAllowed`, so values that fail the gate
/// (non-allowlisted public hosts, non-RFC1918 IPs, etc.) get rejected
/// with an inline error instead of silently saved.
///
/// Shared between the iPhone Settings → Developer screen and the macOS
/// Settings → Developer tab, so it lives in its own file (and is
/// explicitly included in the macOS target's
/// `INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` list) — the rest of
/// `DebugSettingsView.swift` stays iPhone-only.
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
                Text("Effective endpoint")
            } footer: {
                Text("Resolved by PushServerConfig — Keychain override → UserDefaults override → Secrets.plist → localhost fallback.")
            }

            Section {
                textField

                if let error = viewModel.validationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Save") {
                        #if os(iOS)
                        fieldFocused = false
                        #endif
                        viewModel.save()
                    }
                    .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Clear override", role: .destructive) {
                        #if os(iOS)
                        fieldFocused = false
                        #endif
                        viewModel.clear()
                    }
                    .disabled(viewModel.storedOverride == nil)
                }
            } header: {
                Text("Override (Keychain — survives reinstall)")
            } footer: {
                Text("Allowed: `https://staging.api.tigerduck.app/...`, loopback, or any RFC1918 private IPv4 (10.x, 172.16–31.x, 192.168.x). Production is intentionally blocked — Debug builds register on the APNs sandbox and would be rejected by the prod backend.")
            }
        }
        .navigationTitle("API endpoint")
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    @ViewBuilder
    private var textField: some View {
        #if os(iOS)
        TextField("https://staging.api.tigerduck.app/v2", text: $viewModel.draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .font(.system(.body, design: .monospaced))
            .focused($fieldFocused)
        #else
        TextField("https://staging.api.tigerduck.app/v2", text: $viewModel.draft)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
        #endif
    }
}

@MainActor
@Observable
final class DebugEndpointViewModel {
    var draft: String
    private(set) var storedOverride: String?
    private(set) var validationError: String?
    private(set) var effectiveURL: String

    init() {
        let current = DebugEndpointStore.currentOverride()
        self.storedOverride = current
        self.draft = current ?? ""
        self.effectiveURL = PushServerConfig.resolveServerURL().absoluteString
    }

    func save() {
        let ok = DebugEndpointStore.setOverride(draft)
        if ok {
            validationError = nil
            storedOverride = DebugEndpointStore.currentOverride()
            effectiveURL = PushServerConfig.resolveServerURL().absoluteString
        } else {
            validationError = "Rejected: URL is malformed or not in the allowlist (loopback, RFC1918, or staging.api.tigerduck.app)."
        }
    }

    func clear() {
        DebugEndpointStore.clearOverride()
        storedOverride = nil
        draft = ""
        validationError = nil
        effectiveURL = PushServerConfig.resolveServerURL().absoluteString
    }
}
#endif
