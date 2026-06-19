import Defaults
import SwiftUI

/// Detail view for Cross-Device Sync, reachable from the Notifications
/// section in SettingsView. Shows the same information as the onboarding
/// cloud-sync page plus the master toggle.
struct CloudSyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.cloudSyncEnabled) private var syncEnabled

    var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "settings_sync_toggle_label"),
                    isOn: $syncEnabled
                )
                .onChange(of: syncEnabled) { _, newValue in
                    appState.cloudSyncEnabled = newValue
                }
            } footer: {
                Text(String(localized: "settings_sync_brief_description"))
            }

            Section(String(localized: "settings_sync_data_section")) {
                cloudSyncInfoRow(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: String(localized: "onboarding_sync_shared_student_id")
                )
                cloudSyncInfoRow(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: String(localized: "onboarding_sync_shared_moodle_token")
                )
                cloudSyncInfoRow(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: String(localized: "onboarding_sync_shared_device_id")
                )
                cloudSyncInfoRow(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: String(localized: "onboarding_sync_shared_courses")
                )
                cloudSyncInfoRow(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: String(localized: "onboarding_sync_shared_assignments")
                )
                cloudSyncInfoRow(
                    icon: "xmark.circle.fill",
                    color: .red,
                    text: String(localized: "onboarding_sync_not_shared_password")
                )
            }

            if !syncEnabled {
                Section {
                    Label(
                        String(localized: "settings_sync_disabled_note"),
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            Section {
                Link(destination: AppURLs.learnMoreBackend) {
                    Label(String(localized: "settings_learn_more_backend"), systemImage: "server.rack")
                }
                Link(destination: AppURLs.privacyPolicy) {
                    Label(String(localized: "onboarding_privacy_policy_label"), systemImage: "hand.raised.fill")
                }
                Link(destination: AppURLs.deleteAccount) {
                    Label(String(localized: "onboarding_privacy_delete_account_label"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(String(localized: "settings_sync_toggle_label"))
    }

    private func cloudSyncInfoRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
        }
    }
}
