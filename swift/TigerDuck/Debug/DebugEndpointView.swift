import Observation
import SwiftUI

/// Screen for picking which backend the app talks to. Survives uninstall
/// because the value lives in Keychain (`DebugEndpointStore`). All writes
/// go through `PushServerConfig.isOverrideAllowed`, so values that fail
/// the gate (non-allowlisted public hosts, non-RFC1918 IPs, etc.) get
/// rejected with an inline error instead of silently saved.
///
/// Reached from Settings → Other settings on iPhone (every build) and the
/// macOS Settings → Developer tab, so it lives in its own file — the rest
/// of `DebugSettingsView.swift` stays iPhone-only and DEBUG-only.
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

            if let stale = viewModel.staleOverride {
                Section {
                    Text(stale)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Stored override no longer accepted")
                } footer: {
                    Text("The allowlist tightened since this value was saved, so it's being ignored and the resolver is using the next priority. Save a new value or clear the override.")
                        .foregroundStyle(.orange)
                }
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
                Text("Allowed: `https://api.tigerduck.app/...` (apex or any subdomain), loopback, or any RFC1918 private IPv4 (10.x, 172.16–31.x, 192.168.x). LAN dev backend speaks plain HTTP — `https://192.168.X.X:…` is auto-rewritten to `http://` at save time. Pointing a Debug build at the prod apex breaks push (apns_env mismatch — sandbox tokens get rejected at registration), but read-only API surfaces (bulletin, etc.) work for testing.")
            }
        }
        .navigationTitle(String(localized: "settings_api_endpoint"))
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    @ViewBuilder
    private var textField: some View {
        #if os(iOS)
        TextField("http://192.168.X.X:40000/v2", text: $viewModel.draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .font(.system(.body, design: .monospaced))
            .focused($fieldFocused)
        #else
        TextField("http://192.168.X.X:40000/v2", text: $viewModel.draft)
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
    private(set) var staleOverride: String?
    private(set) var validationError: String?
    private(set) var effectiveURL: String

    init() {
        let current = DebugEndpointStore.currentOverride()
        let stale = DebugEndpointStore.storedButRejectedOverride()
        self.storedOverride = current
        self.staleOverride = stale
        self.draft = current ?? stale ?? ""
        self.effectiveURL = PushServerConfig.resolveServerURL().absoluteString
    }

    func save() {
        switch DebugEndpointStore.setOverride(draft) {
        case .success:
            validationError = nil
            storedOverride = DebugEndpointStore.currentOverride()
            staleOverride = DebugEndpointStore.storedButRejectedOverride()
            if let stored = storedOverride { draft = stored }
            effectiveURL = PushServerConfig.resolveServerURL().absoluteString
        case .malformed:
            validationError = "URL is malformed — expected something like `http://192.168.X.X:40000/v2` or `https://staging.api.tigerduck.app/v2`."
        case .rejected:
            validationError = "Rejected by allowlist. Only loopback, RFC1918 (10.x / 172.16–31.x / 192.168.x), or `*.api.tigerduck.app` (apex + subdomains) are accepted."
        case .keychainWriteFailed:
            validationError = "Keychain write failed — the URL passed validation but couldn't be persisted. Try again; if it keeps failing, the device may be locked or out of secure storage."
        }
    }

    func clear() {
        DebugEndpointStore.clearOverride()
        storedOverride = nil
        staleOverride = nil
        draft = ""
        validationError = nil
        effectiveURL = PushServerConfig.resolveServerURL().absoluteString
    }
}
