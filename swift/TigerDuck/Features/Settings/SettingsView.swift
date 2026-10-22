import Defaults
import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    /// Observed, not read through `Defaults[...]`: a bare subscript is a
    /// plain read that SwiftUI never subscribes to, so this screen kept
    /// rendering "On" after the switch inside `CloudSyncSettingsView` had
    /// already turned it off -- popping back does not re-evaluate a parent
    /// body on its own.
    ///
    /// The preference is the flag's only copy -- `appState.cloudSyncEnabled`
    /// reads it too, through `CloudSyncPreference` -- so either would do.
    @Default(.cloudSyncEnabled) private var cloudSyncEnabled
    @Default(.outlineRequiredCourses) private var outlineRequiredCourses
    @Default(.pinTodayCoursesOnClassTable) private var pinTodayCoursesOnClassTable
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingTabEditor = false
    @State private var showLibraryLogin = false
    @State private var confirmsSignOut = false
    @State private var signOutLines: [String] = []
    @State private var libIsLoggingIn = false
    @State private var libLoginError: String?
    #if os(iOS)
    @State private var showSchoolMailLogin = false
    #endif
    @State private var notificationsAuthorized: Bool = true
    @State private var showOfficialWebsite = false
    @State private var showServerStatus = false
    #if os(iOS)
    @State private var showManualUpdateCheckResultAlert = false
    @State private var manualWhatsNewItem: WhatsNewPresentation?
    #endif
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    @AppStorage(ScreenCaptureProtectionDebugFlag.userDefaultsKey)
    private var disableScreenCaptureProtection = false
    #endif

    private static let websiteURL = AppURLs.website

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (Build \(build))"
    }

    var body: some View {
        @Bindable var appState = appState
        List {
            Section(String(localized: "settings_section_account")) {
                ntustAccountRow
                libraryAccountRow
                #if os(iOS)
                if SchoolMailAvailability.isEnabled {
                    schoolMailAccountRow
                }
                #endif
            }

            Section(String(localized: "settings_section_custom")) {
                Button(String(localized: "tab_editor_title")) {
                    showingTabEditor = true
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "settings_accent_color"))
                    HStack(spacing: 12) {
                        ForEach(AppState.themeColors, id: \.hex) { theme in
                            Button {
                                withAnimation(reduceMotion ? nil : .smoothSpring) {
                                    appState.accentColorHex = theme.hex
                                }
                            } label: {
                                Circle()
                                    .fill(Color(hex: UInt(theme.hex)))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if appState.accentColorHex == theme.hex {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(String(localized: String.LocalizationValue(theme.nameKey))))
                            .accessibilityAddTraits(appState.accentColorHex == theme.hex ? .isSelected : [])
                        }
                    }
                }
            }

            Section(String(localized: "settings_section_display")) {
                Picker(String(localized: "settings_visual_preset_label"), selection: $appState.visualPreset) {
                    ForEach(VisualPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                Toggle(String(localized: "settings_show_absolute_assignment_time"), isOn: $appState.showAbsoluteAssignmentTime)
                Toggle(
                    String(localized: "settings_pin_today_courses_on_class_table"),
                    isOn: $pinTodayCoursesOnClassTable
                )
                Toggle(
                    String(localized: "settings_show_classroom_on_class_table"),
                    isOn: $appState.showClassroomInClassTable
                )
                Toggle(String(localized: "settings_outline_required_courses"), isOn: $outlineRequiredCourses)
                Toggle(String(localized: "settings_always_show_periods_abc"), isOn: $appState.alwaysShowAllPeriods)
                Picker(String(localized: "settings_link_opening_method"), selection: $appState.browserPreference) {
                    Text(String(localized: "settings_browser_system_default")).tag(BrowserPreference.system)
                    Text(String(localized: "settings_browser_in_app")).tag(BrowserPreference.inApp)
                }
            }

            if LanguageManager.isCurrentLanguageNonChinese(appLanguage: appState.appLanguage) {
                Section(String(localized: "settings_section_abbreviation")) {
                    Toggle(
                        String(localized: "settings_use_english_course_abbreviation"),
                        isOn: $appState.useEnglishCourseAbbreviation
                    )
                    Toggle(
                        String(localized: "settings_use_english_classroom_abbreviation"),
                        isOn: $appState.useEnglishClassroomAbbreviation
                    )
                    if appState.useEnglishClassroomAbbreviation {
                        // The Form default, `.menu`, sizes the row for one line, so a long
                        // localized label wraps to two lines and is clipped at the bottom.
                        // `.navigationLink` renders a real NavigationLink whose row fits the label.
                        Picker(
                            String(localized: "settings_classroom_mandarin_display"),
                            selection: $appState.classroomMandarinDisplay
                        ) {
                            Text(String(localized: "settings_classroom_mandarin_display_original"))
                                .tag("original")
                            Text(String(localized: "settings_classroom_mandarin_display_pinyin"))
                                .tag("pinyin")
                            Text(String(localized: "settings_classroom_mandarin_display_translated"))
                                .tag("translated")
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
            }

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
                        ClassReminderSettingsView(store: appState.liveActivityPreferences)
                    }
                    .disabled(!cloudSyncEnabled)
                    NavigationLink(String(localized: "live_activity_settings_assignment_notification_header")) {
                        AssignmentReminderSettingsView(store: appState.liveActivityPreferences)
                    }
                    .disabled(!cloudSyncEnabled)
                    NavigationLink(String(localized: "live_activity_settings_nav_title")) {
                        LiveActivitySettingsView(store: appState.liveActivityPreferences)
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

            Section(String(localized: "settings_section_about")) {
                LabeledContent(String(localized: "settings_version"), value: appVersion)
                #if os(iOS)
                checkForUpdatesRow
                serverStatusRow
                whatsNewRow
                #endif
                Button {
                    if appState.browserPreference == .inApp {
                        showOfficialWebsite = true
                    } else {
                        openURL(Self.websiteURL)
                    }
                } label: {
                    HStack {
                        Text(String(localized: "settings_official_website"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: appState.browserPreference == .inApp
                              ? "rectangle.portrait.and.arrow.right"
                              : "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink(String(localized: "settings_about_others")) {
                    AboutOthersView()
                }
            }

            #if DEBUG
            Section("Developer") {
                NavigationLink("Time override") {
                    DebugSettingsView()
                }
                NavigationLink("Notifications") {
                    DebugNotificationsView()
                }
                NavigationLink("Server failure simulation") {
                    DebugServerFailureView()
                }
                #if os(iOS)
                NavigationLink("Triggers") {
                    TriggersDebugView()
                }
                NavigationLink("TigerSync status") {
                    TigerSyncStatusView()
                }
                NavigationLink("Email") {
                    DevMailServerView()
                }
                #endif
                Toggle("Disable screen-capture protection", isOn: $disableScreenCaptureProtection)

                Button {} label: {
                    VStack(alignment: .leading) {
                        Text("Long press to erase everything and restart")
                            .foregroundStyle(.red)
                        Text("Wipes all data, accounts (NTUST, Moodle, library), caches, and preferences. Keeps only the API endpoint override.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onLongPressGesture(minimumDuration: 1) {
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    #endif
                    eraseEverything()
                }
            }
            #endif
        }
        .navigationTitle(String(localized: "feature_settings"))
        .task { await refreshNotificationsAuthorization() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await refreshNotificationsAuthorization() }
            }
        }
        .sheet(isPresented: $showingTabEditor) {
            TabEditorView()
        }
        .alert(String(localized: "action_sign_out"), isPresented: $confirmsSignOut) {
            Button(String(localized: "action_sign_out"), role: .destructive) {
                appState.logoutNTUST()
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(signOutLines.joined(separator: "\n"))
        }
        .sheet(isPresented: $showOfficialWebsite) {
            InAppBrowserView(url: Self.websiteURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showServerStatus) {
            InAppBrowserView(url: AppURLs.serverStatus)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showLibraryLogin) {
            LoginSheet(
                title: String(localized: "settings_account_library_system"),
                subtitle: String(localized: "settings_library_account_subtitle"),
                usernamePlaceholder: String(localized: "sign_in_student_id"),
                passwordPlaceholder: String(localized: "sign_in_password"),
                initialUsername: appState.authService.storedStudentId ?? "",
                isLoggingIn: libIsLoggingIn,
                loginError: libLoginError,
                onLogin: { username, password in
                    Task {
                        libIsLoggingIn = true
                        libLoginError = nil
                        do {
                            try await LibraryService.login(
                                username: username,
                                password: password
                            )
                            appState.notifyLibraryStateChanged()
                            showLibraryLogin = false
                        } catch {
                            libLoginError = error.localizedDescription
                        }
                        libIsLoggingIn = false
                    }
                },
                onDismiss: {
                    showLibraryLogin = false
                    libLoginError = nil
                }
            )
        }
        #if os(iOS)
        .sheet(isPresented: $showSchoolMailLogin) {
            MailLoginSheet(isPresented: $showSchoolMailLogin)
        }
        .alert(
            manualCheckResultAlertTitle,
            isPresented: $showManualUpdateCheckResultAlert,
            actions: {
                Button(String(localized: "action_got_it"), role: .cancel) {
                    appState.updateNotifyCoordinator.lastManualCheckResult = nil
                }
            },
            message: {
                Text(manualCheckResultAlertMessage)
            }
        )
        .sheet(item: $manualWhatsNewItem) { presentation in
            WhatsNewFlowView(presentation: presentation) {
                manualWhatsNewItem = nil
            }
            .whatsNewSheetPresentation()
        }
        #endif
    }

    #if os(iOS)
    private var manualCheckResultAlertTitle: String {
        switch appState.updateNotifyCoordinator.lastManualCheckResult {
        case .upToDate: return String(localized: "update_up_to_date_title")
        case .failed: return String(localized: "update_check_failed_title")
        case .offered, nil: return ""
        }
    }

    private var manualCheckResultAlertMessage: String {
        switch appState.updateNotifyCoordinator.lastManualCheckResult {
        case .upToDate:
            return String(format: NSLocalizedString(
                "update_up_to_date_message",
                comment: ""
            ), AppConstants.appName)
        case .failed:
            return String(localized: "update_check_failed_message")
        case .offered, nil:
            return ""
        }
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private var checkForUpdatesRow: some View {
        Button {
            Task {
                await appState.updateNotifyCoordinator.checkManually()
                let result = appState.updateNotifyCoordinator.lastManualCheckResult
                if case .offered = result { return }
                if result != nil { showManualUpdateCheckResultAlert = true }
            }
        } label: {
            HStack {
                Text(String(localized: "settings_check_for_updates"))
                    .foregroundStyle(.primary)
                Spacer()
                if appState.updateNotifyCoordinator.isCheckingForUpdate {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .disabled(appState.updateNotifyCoordinator.isCheckingForUpdate)
    }

    /// "Check Server Status" row. It sits under Check for Updates because that row asks
    /// whether this app is current, and this one whether the services behind it are up.
    ///
    /// Honours the in-app or external browser preference like every other link in
    /// Settings. In-app it uses `SFSafariViewController`, which follows the status URL's
    /// current 302 to another origin in place. A `WKWebView` with a host allowlist would
    /// dead-end there, and an `openURL` hand-off would eject the user into Safari
    /// mid-redirect.
    private var serverStatusRow: some View {
        Button {
            if appState.browserPreference == .inApp {
                showServerStatus = true
            } else {
                openURL(AppURLs.serverStatus)
            }
        } label: {
            HStack {
                Text(String(localized: "settings_check_server_status"))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var whatsNewRow: some View {
        if appState.updateNotifyCoordinator.hasWhatsNewContent(in: appState) {
            Button {
                manualWhatsNewItem = appState.updateNotifyCoordinator.latestWhatsNew(in: appState)
            } label: {
                HStack {
                    Text(String(localized: "settings_whats_new"))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    #endif

    private var ntustAccountRow: some View {
        accountRow(
            title: String(localized: "settings_account_ntust_system"),
            isLoggedIn: appState.authService.hasStoredCredentials,
            detail: appState.authService.storedStudentId,
            onLogin: { appState.presentNTUSTLogin() },
            onLogout: {
                Task {
                    let unsynced = await appState.signOutDeletesUnsyncedData()
                    guard appState.authService.hasStoredCredentials else { return }
                    ImportedClassTableStore.shared.requestSignOut(
                        unsyncedData: unsynced,
                        confirm: { signOutLines = $0; confirmsSignOut = true },
                        signOut: { appState.logoutNTUST() }
                    )
                }
            }
        )
    }

    private var libraryAccountRow: some View {
        accountRow(
            title: String(localized: "settings_account_library_system"),
            isLoggedIn: appState.isLibraryLoggedIn,
            detail: appState.libraryUsername,
            onLogin: { showLibraryLogin = true },
            onLogout: { appState.logoutLibrary() }
        )
    }

    #if os(iOS)
    private var schoolMailAccountRow: some View {
        let mail = MailAccountManager.shared
        return accountRow(
            title: String(localized: "school_mail_account_title"),
            isLoggedIn: mail.isLoggedIn && !mail.authFailed,
            detail: mail.studentID,
            onLogin: { showSchoolMailLogin = true },
            onLogout: { mail.logout() }
        )
    }
    #endif

    @ViewBuilder
    private func accountRow(
        title: String,
        isLoggedIn: Bool,
        detail: String?,
        onLogin: @escaping () -> Void,
        onLogout: @escaping () -> Void
    ) -> some View {
        HStack {
            Circle()
                .fill(isLoggedIn ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if isLoggedIn, let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            accountActionButton(isLoggedIn: isLoggedIn, onLogin: onLogin, onLogout: onLogout)
        }
    }

    @ViewBuilder
    private func accountActionButton(
        isLoggedIn: Bool,
        onLogin: @escaping () -> Void,
        onLogout: @escaping () -> Void
    ) -> some View {
        if isLoggedIn {
            Button(role: .destructive, action: onLogout) {
                Text(String(localized: "action_sign_out"))
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button(action: onLogin) {
                Text(String(localized: "action_sign_in"))
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    #if DEBUG
    private func eraseEverything() {
        appState.logoutNTUST()
        appState.logoutLibrary()
        #if os(iOS)
        MailAccountManager.shared.logout()
        DevMailServerSettings.shared.resetToSchoolServer()
        #endif

        DataCache.shared.clearEverything()

        SecureStore.removeAll(preserving: [DebugEndpointStore.keychainKey])

        // Batch-delete through the live container rather than removing the
        // store file — the container is still mounted and every view is
        // holding queries against it.
        try? modelContext.delete(model: SDCourse.self)
        try? modelContext.delete(model: SDAssignment.self)
        try? modelContext.delete(model: SDAnnouncement.self)
        try? modelContext.delete(model: SDCalendarEvent.self)
        try? modelContext.save()

        UserDefaults.standard.removePersistentDomain(
            forName: Bundle.main.bundleIdentifier!
        )
        Defaults.removeAll()

        try? FileManager.default.removeItem(at: SyncOutbox.defaultDirectory())

        appState.hasCompletedOnboarding = false
        Defaults[.hasCompletedOnboarding] = false
    }
    #endif

    private func refreshNotificationsAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        let authorized = (status == .authorized || status == .provisional || status == .ephemeral)
        await MainActor.run { notificationsAuthorized = authorized }
    }
}
