import Defaults
import SwiftUI

/// "Synced content" secondary menu under TigerSync settings (spec §6) — the
/// six per-category sync toggles plus a jump to Live Activity settings.
///
/// Reachable regardless of whether "Sync course information"
/// (`cloudSyncEnabled`) is on: the two notification-related rows
/// (assignment due reminders, Live Activity) are greyed out while it's
/// off, per spec step 3. The other four rows stay interactive — they
/// already have no effect while sync is off, but the spec only calls out
/// the first two for an explicit disabled state.
struct SyncContentSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.cloudSyncEnabled) private var cloudSyncEnabled
    @Default(.syncAssignments) private var syncAssignments
    @Default(.syncAssignmentReminders) private var syncAssignmentReminders
    @Default(.syncLiveActivity) private var syncLiveActivity
    @Default(.syncCourses) private var syncCourses
    @Default(.syncCourseColors) private var syncCourseColors
    @Default(.syncCourseNames) private var syncCourseNames

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "cloud_sync_assignments"), isOn: $syncAssignments)
                    .onChange(of: syncAssignments) { old, new in
                        if new && !old {
                            appState.markCategoryReenabled("assignments")
                            appState.checkPendingConflicts()
                        }
                        appState.pushSyncPreferences()
                    }

                Toggle(String(localized: "sync_content_assignment_reminders"), isOn: $syncAssignmentReminders)
                    .disabled(!cloudSyncEnabled)
                    .onChange(of: syncAssignmentReminders) { old, new in
                        appState.pushSyncPreferences()
                        #if os(iOS)
                        // On re-enable, the section this switch guards is
                        // ungated again in `NotificationSettingsSync.push`,
                        // but nothing else pushes its now-current local
                        // value to the server until this fires — the
                        // device-preferences PATCH above only carries the
                        // switch itself, not the section's content. It goes
                        // through the same queued, marker-setting path as
                        // any edit, so it cannot overlap another push and a
                        // failed attempt stays marked for the next retry.
                        if NotificationSettingsSync.shouldPushOnDeviceSwitchChange(old: old, new: new) {
                            appState.scheduleNotificationSettingsPush()
                        }
                        #endif
                    }

                Toggle(String(localized: "sync_content_live_activity"), isOn: $syncLiveActivity)
                    .disabled(!cloudSyncEnabled)
                    .onChange(of: syncLiveActivity) { old, new in
                        appState.pushSyncPreferences()
                        #if os(iOS)
                        if NotificationSettingsSync.shouldPushOnDeviceSwitchChange(old: old, new: new) {
                            appState.scheduleNotificationSettingsPush()
                        }
                        #endif
                    }

                Toggle(String(localized: "sync_content_class_table_all"), isOn: $syncCourses)
                    .onChange(of: syncCourses) { old, new in
                        if new && !old {
                            appState.markCategoryReenabled("courses")
                            appState.checkPendingConflicts()
                        }
                        syncCourseColors = AppState.courseColorsAfterCoursesChange(
                            coursesNowOn: new,
                            coloursCurrentlyOn: syncCourseColors
                        )
                        appState.pushSyncPreferences()
                    }

                Toggle(String(localized: "sync_content_class_table_colors"), isOn: $syncCourseColors)
                    .disabled(!syncCourses)
                    .onChange(of: syncCourseColors) { old, new in
                        if new && !old {
                            appState.markCategoryReenabled("course_colors")
                            appState.checkPendingConflicts()
                        }
                        appState.pushSyncPreferences()
                    }

                Toggle(String(localized: "sync_content_class_table_names"), isOn: $syncCourseNames)
                    .onChange(of: syncCourseNames) { old, new in
                        if new && !old {
                            appState.markCategoryReenabled("course_names")
                            appState.checkPendingConflicts()
                        }
                        appState.pushSyncPreferences()
                    }

                NavigationLink(String(localized: "sync_content_live_activity_settings_nav")) {
                    LiveActivitySettingsView(store: appState.liveActivityPreferences)
                }
            }
        }
        .navigationTitle(String(localized: "sync_content_nav_label"))
        .reenableConflictAlert()
    }
}
