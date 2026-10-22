#if os(macOS)
import SwiftUI

struct MacOtherSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var endpointVM = DebugEndpointViewModel()

    var body: some View {
        Form {
            Section {
                Text(endpointVM.effectiveURL)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text(String(localized: "settings_api_endpoint_effective_title"))
            }

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
                        Task { await endpointVM.save { await EndpointChangeSignOut(appState: appState).notes() } }
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
                        Task { await endpointVM.resetToDefault { await EndpointChangeSignOut(appState: appState).notes() } }
                    }
                    .disabled(endpointVM.isChecking || endpointVM.storedOverride == nil)
                }
            } header: {
                Text(String(localized: "settings_api_endpoint_change_title"))
            } footer: {
                Text(String(localized: "settings_api_endpoint_https_note"))
            }

            MoodleFilesCacheSection()
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .endpointChangeAlert(endpointVM)
    }
}
#endif
