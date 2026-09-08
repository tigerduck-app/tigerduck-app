#if os(macOS)
import SwiftUI

/// Other settings tab — the settings that belong to no other tab.
///
/// Today that is the API endpoint override, which used to be reachable
/// only from the DEBUG-only Developer tab. It is not a debug affordance:
/// a user running their own backend, or one told to point at a fallback
/// while the default host is down, needs it in a shipping build. The
/// iPhone has had it in Settings → Other settings for exactly that
/// reason; this is the Mac half of the same idea.
struct MacOtherSettingsView: View {
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
    }
}
#endif
