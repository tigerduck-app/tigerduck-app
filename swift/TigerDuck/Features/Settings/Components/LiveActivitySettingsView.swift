import SwiftUI

/// Settings page for reminder offsets and Live Activity toggles.
/// Lives behind a NavigationLink in SettingsView so the top-level list
/// stays short.
struct LiveActivitySettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppState.self) private var appState
    @State private var showResetConfirmation = false
    @State private var resetFeedbackTrigger = 0

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "live_activity_settings_enable_toggle"), isOn: $store.isLiveActivityEnabled)
            } footer: {
                Text(String(localized: "live_activity_settings_footer"))
            }

            Section(String(localized: "live_activity_settings_section_display_scenarios")) {
                Toggle(String(localized: "live_activity_status_in_class"), isOn: $store.showInClassScenario)
                Toggle(String(localized: "live_activity_status_class_preparing"), isOn: $store.showClassPreparingScenario)
                Toggle(String(localized: "live_activity_status_assignment_short"), isOn: $store.showAssignmentScenario)
            }
            .disabled(!store.isLiveActivityEnabled)

            Section(String(localized: "live_activity_settings_section_timing")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "live_activity_settings_assignment_warning"))
                        Spacer()
                        Text(formatHours(store.assignmentLiveActivityLeadTime))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $store.assignmentLiveActivityLeadTime,
                        in: 3600 ... LiveActivityPreferencesStore.maximumAssignmentLeadTime,
                        step: 3600
                    )
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "live_activity_status_class_preparing"))
                        Spacer()
                        Text(formatHoursAndMinutes(store.classPreparingLeadTime))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $store.classPreparingLeadTime,
                        in: LiveActivityPreferencesStore.minimumClassPreparingLeadTime
                            ... LiveActivityPreferencesStore.maximumClassPreparingLeadTime,
                        step: 5 * 60
                    )
                }
            }
            .disabled(!store.isLiveActivityEnabled)

            Section {
                ForEach(AssignmentReminderOffset.allCases) { offset in
                    Toggle(offset.label, isOn: bindingForOffset(offset))
                }
            } header: {
                Text(String(localized: "live_activity_settings_assignment_notification_header"))
            } footer: {
                Text(String(localized: "live_activity_settings_assignment_notification_footer"))
            }

            Section {
                Button(String(localized: "live_activity_settings_reset_defaults"), role: .destructive) {
                    showResetConfirmation = true
                }
                .confirmationDialog(
                    String(localized: "live_activity_settings_reset_confirm_title"),
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "action_reset"), role: .destructive) {
                        store.resetToDefaults()
                        resetFeedbackTrigger &+= 1
                    }
                    Button(String(localized: "action_cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "live_activity_settings_reset_confirm_message"))
                }
                .sensoryFeedback(.success, trigger: resetFeedbackTrigger)
            }
        }
        .navigationTitle(String(localized: "live_activity_settings_nav_title"))
        .task {
            // Request notification permission only at this explicit entry
            // point. Refresh paths (theme tweaks, foreground transitions,
            // background syncs) intentionally never prompt.
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

    private func formatHours(_ interval: TimeInterval) -> String {
        let hours = Int(interval / 3600)
        return String(format: String(localized: "live_activity_settings_hours_label"), hours)
    }

    private func formatHoursAndMinutes(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return String(format: String(localized: "live_activity_settings_minutes_label"), minutes) }
        if minutes == 0 { return String(format: String(localized: "live_activity_settings_hours_label"), hours) }
        return String(format: String(localized: "live_activity_settings_hours_minutes_label"), hours, minutes)
    }
}
