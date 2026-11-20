import SwiftUI

struct HomePageSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        List {
            Section {
                HomeDisplayToggles(preferences: preferences)
            }
            Section {
                NavigationLink(SettingsRow.assignmentReminders.label) {
                    AppDestination { AssignmentReminderSettingsView(store: $0.liveActivity.preferences) }
                }
                .settingsRow(.assignmentReminders)
                NavigationLink(SettingsRow.liveActivity.label) {
                    AppDestination { LiveActivitySettingsView(store: $0.liveActivity.preferences) }
                }
                .settingsRow(.liveActivity)
            }
        }
    }
}
