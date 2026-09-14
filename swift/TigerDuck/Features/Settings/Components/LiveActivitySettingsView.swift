import ActivityKit
import SwiftUI

/// Settings page for reminder offsets and Live Activity toggles.
/// Lives behind a NavigationLink in SettingsView so the top-level list
/// stays short.
///
/// It shows no permission *states* — those live on
/// `NotificationPermissionSettingsView` (spec §6) — but it does show a single
/// link row back to that screen while the system switch a Live Activity
/// depends on is off, so a user who turned Live Activities off in iOS
/// Settings is not left with a page of settings that cannot produce anything
/// and nowhere to go. Which states count is `permissionGapStatus(liveActivitiesEnabled:)`'s
/// decision; see it for why the notification authorization is not one of them.
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
                    // A way in to 通知權限設定, not a second permission list:
                    // the states, and the jump into system Settings, stay on
                    // that screen. Deliberately outside the
                    // `.disabled(!store.isLiveActivityEnabled)` groups below —
                    // it reads OS-level state, which stays meaningful (and
                    // actionable) whatever this screen's own switches say.
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
            // Same round-trip-from-Settings refresh
            // `NotificationPermissionSettingsView` uses, for the same reason:
            // the user leaves to flip the switch and has to come back to a
            // screen that has noticed. This fires even while the permission
            // screen is pushed on top — this view stays in the navigation
            // stack, so the row is already right by the time they pop back to
            // it, which `.task` alone would not manage (it does not re-run on
            // a pop).
            if newPhase == .active {
                refreshLiveActivityAuthorization()
            }
        }
    }

    private func refreshLiveActivityAuthorization() {
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Whether to show the link row above this screen's settings, and in what
    /// state — `nil` for "show nothing", which is the whole answer when the
    /// user is not blocked. No empty state, no permanently present row.
    ///
    /// The one state gated on is `ActivityAuthorizationInfo().areActivitiesEnabled`:
    /// `LiveActivityCoordinator.apply` returns before requesting anything when
    /// it is false, so nothing this screen can be set to produces a Live
    /// Activity.
    ///
    /// The notification authorization is deliberately NOT a gate, which is
    /// where this parts company with the Android half (there a Live Update
    /// *is* a notification, so POST_NOTIFICATIONS stops it outright). On iOS
    /// ActivityKit is authorized separately: `Activity.request` succeeds with
    /// notifications denied, and the activity appears on the Lock Screen and
    /// in the Dynamic Island. Denied notifications only cost the alert
    /// configuration on a pushed update — the update still lands, silently —
    /// so gating on it would put a permanent warning on a screen that works.
    /// It keeps its row on 通知權限設定, next to the reminders that do need it.
    ///
    /// `static`, internal, and taking a plain `Bool` so
    /// `LiveActivitySettingsViewTests` can pin the shown/hidden decision
    /// without constructing a view, store, or environment — the same move
    /// `formatHoursAndMinutes` below and `NotificationPermissionSettingsView`'s
    /// two mappings already made. It reuses that view's `RowStatus` rather
    /// than describing the same two states a second way.
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

    /// `static` and not `private` (the assignment-lead-time row used to
    /// call the now-deleted `formatHours`, which truncated to whole hours
    /// and silently mis-rendered 7 of the slider's 15 half-hour
    /// positions). Static — not an instance method
    /// reading `store` — and internal rather than private so
    /// `LiveActivitySettingsViewTests` can assert on its output directly;
    /// this codebase has no SwiftUI view-inspection facility, and
    /// constructing a `LiveActivityPreferencesStore` just to reach a
    /// formatter that never touches it would only add an unrelated
    /// `Defaults` dependency to the test.
    static func formatHoursAndMinutes(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return String(format: String(localized: "live_activity_settings_minutes_label"), minutes) }
        if minutes == 0 { return String(format: String(localized: "live_activity_settings_hours_label"), hours) }
        return String(format: String(localized: "live_activity_settings_hours_minutes_label"), hours, minutes)
    }
}
