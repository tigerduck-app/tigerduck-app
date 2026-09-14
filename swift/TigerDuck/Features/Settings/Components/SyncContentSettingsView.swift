import Defaults
import SwiftUI

/// "Synced content" secondary menu under TigerSync settings (spec §6), in
/// three groups of plain switches: Assignments with Assignment due
/// reminders, Live Activity on its own, and All courses, Course colours and
/// Custom course names.
///
/// Course colours is greyed out while All courses is off, and turning All
/// courses off turns it off too (`AppState.courseColorsAfterCoursesChange`).
///
/// Reachable regardless of whether "Sync course information"
/// (`cloudSyncEnabled`) is on, but not every row behaves the same way while
/// it's off: the notification-related rows (Assignment due reminders and
/// Live Activity) stay visible but greyed out, per spec step 3. Assignment
/// status and the whole course group are hidden entirely, matching the Mac
/// account tab, so a category the user cannot see or touch can never pick
/// up a re-enable mark while sync is off.
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
                if cloudSyncEnabled {
                    // The assignment list and its done / ignored marks.
                    Toggle(String(localized: "cloud_sync_assignments"), isOn: $syncAssignments)
                        .onChange(of: syncAssignments) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("assignments")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }
                }

                Toggle(String(localized: "sync_content_assignment_reminders"), isOn: $syncAssignmentReminders)
                    .disabled(!cloudSyncEnabled)
                    .onChange(of: syncAssignmentReminders) { old, new in
                        appState.pushSyncPreferences()
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
                    }
            }

            Section {
                Toggle(String(localized: "sync_content_live_activity"), isOn: $syncLiveActivity)
                    .disabled(!cloudSyncEnabled)
                    .onChange(of: syncLiveActivity) { old, new in
                        appState.pushSyncPreferences()
                        if NotificationSettingsSync.shouldPushOnDeviceSwitchChange(old: old, new: new) {
                            appState.scheduleNotificationSettingsPush()
                        }
                    }
            }

            if cloudSyncEnabled {
                Section {
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

                    Toggle(String(localized: "cloud_sync_course_colours"), isOn: $syncCourseColors)
                        .disabled(!syncCourses)
                        .onChange(of: syncCourseColors) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("course_colors")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }

                    Toggle(String(localized: "cloud_sync_custom_course_names"), isOn: $syncCourseNames)
                        .onChange(of: syncCourseNames) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("course_names")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }
                }
            }
        }
        .navigationTitle(String(localized: "sync_content_nav_label"))
        .reenableConflictAlert()
    }
}
