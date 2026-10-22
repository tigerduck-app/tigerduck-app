import Defaults
import SwiftUI

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
