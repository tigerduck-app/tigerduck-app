import Defaults
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    /// Observed, not read through `Defaults[...]`: a bare subscript is a
    /// plain read that SwiftUI never subscribes to, so this screen kept
    /// rendering "On" after the switch inside `CloudSyncSettingsView` had
    /// already turned it off -- popping back does not re-evaluate a parent
    /// body on its own.
    @AccountDefault(.cloudSyncEnabled) private var cloudSyncEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheets = SettingsSheetState()
    @State private var notificationsAuthorized: Bool = true

    var body: some View {
        List {
            SettingsAccountSection(sheets: sheets)

            SettingsDisplaySections(sheets: sheets)

            Section(String(localized: "cloud_sync_title")) {
                NavigationLink {
                    CloudSyncSettingsView()
                } label: {
                    HStack {
                        Text(String(localized: "cloud_sync_title"))
                        Spacer()
                        Text(cloudSyncEnabled
                             ? String(localized: "settings_sync_status_on")
                             : String(localized: "settings_sync_status_off"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(String(localized: "settings_section_notifications")) {
                if !cloudSyncEnabled {
                    Label(
                        String(localized: "settings_notifications_need_course_sync"),
                        systemImage: "icloud.slash"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }

                #if os(iOS)
                if !notificationsAuthorized {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label(
                            String(localized: "settings_notifications_disabled_warning"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                #endif

                Group {
                    NavigationLink(String(localized: "settings_class_reminder")) {
                        ClassReminderSettingsView(store: app.liveActivity.preferences)
                    }
                    .disabled(!cloudSyncEnabled)
                    NavigationLink(String(localized: "live_activity_settings_assignment_notification_header")) {
                        AssignmentReminderSettingsView(store: app.liveActivity.preferences)
                    }
                    .disabled(!cloudSyncEnabled)
                    NavigationLink(String(localized: "live_activity_settings_nav_title")) {
                        LiveActivitySettingsView(store: app.liveActivity.preferences)
                    }
                    .disabled(!cloudSyncEnabled)
                }
                #if os(iOS)
                if SchoolMailAvailability.isEnabled {
                    NavigationLink(String(localized: "school_mail_notification_settings_title")) {
                        MailNotificationSettingsView()
                    }
                    .disabled(!MailNotificationSettingsView.settingsRowIsEnabled(
                        isLoggedIn: MailAccountManager.shared.isLoggedIn))
                }
                #endif

                NavigationLink(String(localized: "moodle_notification_settings_title")) {
                    MoodleNotificationSettingsView(settings: MoodleNotificationSettings(
                        signIn: app.authService.session.currentSignIn,
                        api: .live(chinese: !LanguageManager.isCurrentLanguageNonChinese(
                            appLanguage: app.preferences.appLanguage
                        ))
                    ), account: app.authService.session)
                }
                .disabled(!app.authService.hasStoredCredentials)

                NavigationLink(String(localized: "notification_permission_settings_nav_title")) {
                    NotificationPermissionSettingsView()
                }
            }

            Section(String(localized: "settings_section_other_settings")) {
                if LibrarySettingsView.isAvailable {
                    NavigationLink(String(localized: "settings_library_related_features")) {
                        LibrarySettingsView()
                    }
                }
                #if os(iOS)
                if SchoolMailAvailability.isEnabled {
                    NavigationLink(String(localized: "school_mail_account_title")) {
                        MailSettingsView()
                    }
                }
                #endif
                NavigationLink(String(localized: "settings_section_other_settings")) {
                    OtherSettingsView()
                }
            }

            // No in-app picker: the user picks the app language in the per-app
            // picker in iOS Settings, and iOS restarts the process on selection.
            Section(String(localized: "feature_category_language")) {
                Button {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                } label: {
                    HStack {
                        Text(String(localized: "settings_language"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsAboutSection(sheets: sheets)

            #if DEBUG
            SettingsDeveloperSection()
            #endif
        }
        .navigationTitle(String(localized: "feature_settings"))
        .task { await refreshNotificationsAuthorization() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await refreshNotificationsAuthorization() }
            }
        }
        .modifier(SettingsSheets(state: sheets))
    }

    private func refreshNotificationsAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        let authorized = (status == .authorized || status == .provisional || status == .ephemeral)
        await MainActor.run { notificationsAuthorized = authorized }
    }
}
