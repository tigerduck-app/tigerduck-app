import Defaults
import SwiftUI

/// "Synced content" secondary menu under TigerSync settings (spec §6), in
/// three groups — Assignments (assignment status, assignment due
/// reminders), Live Activity on its own, and Class table (all courses,
/// course colours, custom course names) — then the jump to Live Activity
/// settings, set apart below them under the destination screen's own name.
///
/// Assignments and Class table are parent switches with no stored value of
/// their own: each reads on while any of its rows is on, and flipping it
/// sets every row it covers, so nothing new is persisted or sent to the
/// backend. While one reads off, its rows are greyed out, since turning it
/// back on is how they return.
///
/// Reachable regardless of whether "Sync course information"
/// (`cloudSyncEnabled`) is on, but not every row behaves the same way while
/// it's off: the notification-related rows (the Assignments switch with its
/// due-reminders row, and Live Activity) stay visible but greyed out, per
/// spec step 3, and so does the jump to the Live Activity screen.
/// Assignment status and the whole Class table group are hidden entirely,
/// matching the Mac account tab, so a category the user cannot see or
/// touch can never pick up a re-enable mark while sync is off.
struct SyncContentSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.cloudSyncEnabled) private var cloudSyncEnabled
    @Default(.syncAssignments) private var syncAssignments
    @Default(.syncAssignmentReminders) private var syncAssignmentReminders
    @Default(.syncLiveActivity) private var syncLiveActivity
    @Default(.syncCourses) private var syncCourses
    @Default(.syncCourseColors) private var syncCourseColors
    @Default(.syncCourseNames) private var syncCourseNames

    /// Sets a row under the parent switch it belongs to.
    private static let childIndent: CGFloat = 16

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "cloud_sync_assignments"), isOn: assignmentsGroup)
                    .disabled(!cloudSyncEnabled)

                if cloudSyncEnabled {
                    // The assignment list and its done / ignored marks.
                    Toggle(String(localized: "cloud_sync_assignments"), isOn: $syncAssignments)
                        .padding(.leading, Self.childIndent)
                        .disabled(!assignmentsGroupOn)
                        .onChange(of: syncAssignments) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("assignments")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }
                }

                Toggle(String(localized: "sync_content_assignment_reminders"), isOn: $syncAssignmentReminders)
                    .padding(.leading, Self.childIndent)
                    .disabled(!cloudSyncEnabled || !assignmentsGroupOn)
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
                    Toggle(String(localized: "cloud_sync_class_table"), isOn: classTableGroup)

                    Toggle(String(localized: "cloud_sync_courses"), isOn: $syncCourses)
                        .padding(.leading, Self.childIndent)
                        .disabled(!classTableGroupOn)
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
                        .padding(.leading, Self.childIndent)
                        .disabled(!classTableGroupOn || !syncCourses)
                        .onChange(of: syncCourseColors) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("course_colors")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }

                    Toggle(String(localized: "cloud_sync_custom_course_names"), isOn: $syncCourseNames)
                        .padding(.leading, Self.childIndent)
                        .disabled(!classTableGroupOn)
                        .onChange(of: syncCourseNames) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("course_names")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }
                }
            }

            Section {
                NavigationLink(String(localized: "live_activity_settings_nav_title")) {
                    LiveActivitySettingsView(store: appState.liveActivityPreferences)
                }
                // Greyed with sync off, like the row under 通知 that leads to
                // the same screen: Live Activity is unavailable then
                // (spec §6), so its switches would take effect on nothing.
                .disabled(!cloudSyncEnabled)
            }
        }
        .navigationTitle(String(localized: "sync_content_nav_label"))
        .reenableConflictAlert()
    }

    private var assignmentsGroupOn: Bool { syncAssignments || syncAssignmentReminders }
    private var classTableGroupOn: Bool { syncCourses || syncCourseColors || syncCourseNames }

    /// Writes both rows; each row's own `onChange` then does exactly what a
    /// tap on that row would.
    private var assignmentsGroup: Binding<Bool> {
        Binding(
            get: { assignmentsGroupOn },
            set: { on in
                syncAssignments = on
                syncAssignmentReminders = on
            }
        )
    }

    /// Writes all three rows, the same way; courses' own handler then keeps
    /// colours off whenever courses are.
    private var classTableGroup: Binding<Bool> {
        Binding(
            get: { classTableGroupOn },
            set: { on in
                syncCourses = on
                syncCourseColors = on
                syncCourseNames = on
            }
        )
    }
}
