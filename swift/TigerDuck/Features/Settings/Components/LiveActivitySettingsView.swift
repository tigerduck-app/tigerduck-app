import ActivityKit
import SwiftUI

struct LiveActivitySettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showResetConfirmation = false
    @State private var resetFeedbackTrigger = 0
    @State private var liveActivitiesEnabled = true

    var body: some View {
        Form {
            if let gap = Self.permissionGapStatus(liveActivitiesEnabled: liveActivitiesEnabled) {
                Section {
                    NavigationLink {
                        NotificationPermissionSettingsView()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: gap.systemImage)
                                .foregroundStyle(gap.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "notification_permission_settings_nav_title"))
                                    .foregroundStyle(.primary)
                                Text(gap.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

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
                        Text(Self.formatHoursAndMinutes(store.assignmentLiveActivityLeadTime))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $store.assignmentLiveActivityLeadTime,
                        in: 3600 ... LiveActivityPreferencesStore.maximumAssignmentLeadTime,
                        step: 1800
                    )
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "live_activity_status_class_preparing"))
                        Spacer()
                        Text(Self.formatHoursAndMinutes(store.classPreparingLeadTime))
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
            appState.reconcileNotificationSettings()
            refreshLiveActivityAuthorization()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshLiveActivityAuthorization()
            }
        }
    }

    private func refreshLiveActivityAuthorization() {
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }

    static func permissionGapStatus(
        liveActivitiesEnabled: Bool
    ) -> NotificationPermissionSettingsView.RowStatus? {
        switch NotificationPermissionSettingsView.liveActivityPermissionStatus(
            enabled: liveActivitiesEnabled
        ) {
        case .granted: return nil
        case .notGranted: return .notGranted
        }
    }

    static func formatHoursAndMinutes(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return String(format: String(localized: "live_activity_settings_minutes_label"), minutes) }
        if minutes == 0 { return String(format: String(localized: "live_activity_settings_hours_label"), hours) }
        return String(format: String(localized: "live_activity_settings_hours_minutes_label"), hours, minutes)
    }
}
