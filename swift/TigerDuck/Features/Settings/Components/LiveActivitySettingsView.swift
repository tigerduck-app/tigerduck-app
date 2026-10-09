import ActivityKit
import SwiftUI

/// Settings page for reminder offsets and Live Activity toggles, behind a
/// NavigationLink in SettingsView so the top-level list stays short.
///
/// Permission states live on `NotificationPermissionSettingsView`. This page
/// only links there while the system Live Activities switch is off, so a user
/// who turned it off is not left with settings that do nothing and nowhere to go.
/// `permissionGapStatus(liveActivitiesEnabled:)` decides which states count; its
/// doc says why notification authorization is not one of them.
struct LiveActivitySettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showResetConfirmation = false
    @State private var resetFeedbackTrigger = 0
    /// Starts out enabled — "nothing missing" — so a screen that is fine
    /// never flashes a warning row in the frame before `.task` reads the
    /// real value. The opposite default would put an orange row on every
    /// first render of a working screen.
    @State private var liveActivitiesEnabled = true

    var body: some View {
        Form {
            if let gap = Self.permissionGapStatus(liveActivitiesEnabled: liveActivitiesEnabled) {
                Section {
                    // Links to the notification permission screen, which owns the states
                    // and the jump to system Settings. Outside the `.disabled` groups below,
                    // since OS-level state stays actionable whatever these switches say.
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
            // Show what another device last saved, not only this one's copy.
            appState.reconcileNotificationSettings()
            refreshLiveActivityAuthorization()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-read after a trip to Settings, as `NotificationPermissionSettingsView`
            // does. This also fires while that screen is pushed on top, so the row is
            // right when the user pops back; `.task` does not re-run on a pop.
            if newPhase == .active {
                refreshLiveActivityAuthorization()
            }
        }
    }

    private func refreshLiveActivityAuthorization() {
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// The link row's state, or `nil` to show nothing when the user is not blocked.
    /// The only gate is `ActivityAuthorizationInfo().areActivitiesEnabled`: when it is
    /// false, `LiveActivityCoordinator.apply` requests nothing. Notification
    /// authorization is not a gate, unlike on Android: on iOS `Activity.request`
    /// succeeds with notifications denied, so a warning would sit on a working screen.
    /// Static and taking a `Bool` so `LiveActivitySettingsViewTests` can pin the
    /// decision without constructing a view, store or environment.
    /// See docs/decisions/0011-live-activity-permission-gate.md.
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

    /// Static and internal so `LiveActivitySettingsViewTests` can assert on its
    /// output directly: the codebase has no SwiftUI view inspection, and building
    /// a `LiveActivityPreferencesStore` for a formatter that never touches it
    /// would add an unrelated `Defaults` dependency to the test. The slider has
    /// half-hour positions, so this must not truncate to whole hours.
    static func formatHoursAndMinutes(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return String(format: String(localized: "live_activity_settings_minutes_label"), minutes) }
        if minutes == 0 { return String(format: String(localized: "live_activity_settings_hours_label"), hours) }
        return String(format: String(localized: "live_activity_settings_hours_minutes_label"), hours, minutes)
    }
}
