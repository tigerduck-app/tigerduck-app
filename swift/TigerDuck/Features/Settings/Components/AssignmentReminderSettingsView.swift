import SwiftUI

struct AssignmentReminderSettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppEnvironment.self) private var app

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
        .navigationTitle(SettingsRow.assignmentReminders.label)
        .task {
            app.notificationSettings.reconcile()
            await app.liveActivity.requestNotificationAuthorization()
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
