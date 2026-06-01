import SwiftUI

/// Settings page for assignment due reminders: a master on/off switch and the
/// per-offset opt-ins. Lives behind a NavigationLink in SettingsView, sibling
/// to LiveActivitySettingsView — mirroring the Android app's separate
/// "Assignment notifications" screen.
struct AssignmentReminderSettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "settings_assignment_due_reminder"),
                    isOn: $store.isAssignmentReminderEnabled
                )
            } footer: {
                Text(String(localized: "live_activity_settings_assignment_notification_footer"))
            }

            Section {
                ForEach(AssignmentReminderOffset.allCases) { offset in
                    Toggle(offset.label, isOn: bindingForOffset(offset))
                }
            }
            .disabled(!store.isAssignmentReminderEnabled)
        }
        .navigationTitle(String(localized: "live_activity_settings_assignment_notification_header"))
        .task {
            // This screen is now the assignment-reminder feature's explicit
            // entry point, so the notification permission prompt lives here.
            // Refresh paths (theme tweaks, foreground transitions, background
            // syncs) intentionally never prompt.
            await appState.requestNotificationAuthorization()
        }
    }

    private func bindingForOffset(_ offset: AssignmentReminderOffset) -> Binding<Bool> {
        Binding(
            get: { store.assignmentReminderOffsets.contains(offset) },
            set: { newValue in
                if newValue {
                    store.assignmentReminderOffsets.insert(offset)
                } else {
                    store.assignmentReminderOffsets.remove(offset)
                }
            }
        )
    }
}
