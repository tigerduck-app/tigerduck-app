import SwiftUI

struct ClassReminderSettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "settings_class_reminder"), isOn: $store.isClassReminderEnabled)
            } footer: {
                Text(String(localized: "settings_class_reminder_footer"))
            }

            Section {
                Picker(String(localized: "settings_class_reminder_lead_time"), selection: $store.classReminderLeadMinutes) {
                    ForEach(LiveActivityPreferencesStore.classReminderLeadChoices) { offset in
                        Text(offset.label).tag(Int(offset.timeInterval / 60))
                    }
                }
                .pickerStyle(.navigationLink)
            }
            .disabled(!store.isClassReminderEnabled)
        }
        .navigationTitle(String(localized: "settings_class_reminder"))
        .task {
            appState.reconcileNotificationSettings()
            await appState.requestNotificationAuthorization()
        }
    }
}
