import Defaults
import SwiftUI

/// "Synced content" submenu of TigerSync settings. Its switches, in three groups:
/// Assignments and Assignment due reminders; Live Activity; All courses, Course
/// colours and Custom course names. Course colours turns on and off with All courses
/// (`AppState.courseColorsAfterCoursesChange`) and is greyed out without All courses.
///
/// With `cloudSyncEnabled` off, the reminder and Live Activity rows stay visible but
/// greyed out. Assignments and the course group are hidden, as on the Mac account tab,
/// so a hidden category never picks up a re-enable mark while sync is off.
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
                        // Turning this on ungates its section in `NotificationSettingsSync.push`, and nothing
                        // else uploads it until this push: the PATCH above sends just the switch. Queued and
                        // marked like any edit, it cannot overlap another push, and a failure stays marked.
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
                            // Colours' own `onChange` then marks and pushes
                            // them the way a tap on their row would.
                            syncCourseColors = AppState.courseColorsAfterCoursesChange(coursesNowOn: new)
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
