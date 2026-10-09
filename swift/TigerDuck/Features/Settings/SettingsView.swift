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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notifyAssignments = true
    @State private var notifyAnnouncements = true
    @State private var notifyFreeLunch = true
    @State private var notifyClubs = false
    @State private var showingTabEditor = false
    @State private var showLibraryLogin = false
    @State private var libIsLoggingIn = false
    @State private var libLoginError: String?
    #if os(iOS)
    @State private var showSchoolMailLogin = false
    #endif
    @State private var notificationsAuthorized: Bool = true
    @State private var showOfficialWebsite = false
    @State private var showServerStatus = false
    #if os(iOS)
    /// Drives the "you're up to date" / "couldn't reach the App Store"
    /// feedback alert that fires after the manual Check for Updates row.
    /// Only true when the coordinator emitted a result that isn't already
    /// surfaced through the auto-presented update sheet — an `.offered`
    /// result is shown via that sheet path, not this alert.
    @State private var showManualUpdateCheckResultAlert = false
    /// Item for the Settings → What's New row, allowing repeat
    /// presentation of the latest release's flow independent of the
    /// auto-launch gate's seen-state. Driven by `.sheet(item:)` rather
    /// than `.sheet(isPresented:)` so the entry is captured at present
    /// time — a stale `latestWhatsNew == nil` between the row tap and
    /// the sheet body evaluation cannot leak an empty sheet onto
    /// screen.
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
            // MARK: - Account
            Section(String(localized: "settings_section_account")) {
                ntustAccountRow
                if appState.libraryFeatureEnabled {
                    libraryAccountRow
                }
                #if os(iOS)
                if SchoolMailAvailability.isEnabled {
                    schoolMailAccountRow
                }
                #endif
            }

            // MARK: - Customization
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
                        }
                    }
                }
            }

            // MARK: - Display
            Section(String(localized: "settings_section_display")) {
                Picker(String(localized: "settings_visual_preset_label"), selection: $appState.visualPreset) {
                    ForEach(VisualPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                Toggle(String(localized: "settings_show_absolute_assignment_time"), isOn: $appState.showAbsoluteAssignmentTime)
                Toggle(
                    String(localized: "settings_show_classroom_on_class_table"),
                    isOn: $appState.showClassroomInClassTable
                )
                Toggle(String(localized: "settings_always_show_periods_abc"), isOn: $appState.alwaysShowAllPeriods)
                Toggle(String(localized: "settings_remember_bulletin_filter"), isOn: $appState.rememberAnnouncementFilter)
                Picker(String(localized: "settings_link_opening_method"), selection: $appState.browserPreference) {
                    Text(String(localized: "settings_browser_system_default")).tag(BrowserPreference.system)
                    Text(String(localized: "settings_browser_in_app")).tag(BrowserPreference.inApp)
                }
            }

            // MARK: - Abbreviations (only when UI is non-Chinese, since the
            // toggles transform Mandarin display strings)
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

            // MARK: - Cloud Sync
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

            // MARK: - Notifications & Live Activity
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
                    NavigationLink(String(localized: "live_activity_settings_assignment_notification_header")) {
                        AssignmentReminderSettingsView(store: appState.liveActivityPreferences)
                    }
                    // Greyed out with course sync off: the backend sends
                    // assignment reminders only to devices that sync, so
                    // nothing set here would take effect.
                    .disabled(!cloudSyncEnabled)
                    NavigationLink(String(localized: "live_activity_settings_nav_title")) {
                        LiveActivitySettingsView(store: appState.liveActivityPreferences)
                    }
                    // Same reason as the row above: Live Activity is unavailable
                    // with course sync off, so nothing on this screen would take effect.
                    .disabled(!cloudSyncEnabled)
                }
                #if os(iOS)
                if SchoolMailAvailability.isEnabled {
                    // The School Mail switch and its check log live here, not in School Mail
                    // settings, so one screen owns them. Disabled while signed out (no mailbox to
                    // notify about); the account row above shows that, so this row has no subtitle.
                    NavigationLink(String(localized: "school_mail_notification_settings_title")) {
                        MailNotificationSettingsView()
                    }
                    .disabled(!MailNotificationSettingsView.settingsRowIsEnabled(
                        isLoggedIn: MailAccountManager.shared.isLoggedIn))
                }
                #endif

                // The last row, always enabled: it reads OS-level permission state,
                // which stays meaningful whether or not course sync is on.
                // iPhone/iPad only; macOS has no equivalent.
                NavigationLink(String(localized: "notification_permission_settings_nav_title")) {
                    NotificationPermissionSettingsView()
                }
            }

            // MARK: - Other settings
            // Two sub-pages: the library switches, and the rest of the
            // miscellany.
            Section(String(localized: "settings_section_other_settings")) {
                NavigationLink(String(localized: "settings_library_related_features")) {
                    LibrarySettingsView()
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

            // MARK: - Language
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

            // MARK: - About
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
                // School Mail is iOS-only, so its server override is too.
                NavigationLink("Email") {
                    DevMailServerView()
                }
                #endif
                // Bypasses `.screenCaptureProtected(...)` everywhere, for demo recordings
                // and layout debugging. `@AppStorage` makes a toggle re-evaluate every
                // protected view at once. Compiled out of release builds.
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
            // Reflect a System Settings round-trip the moment the user
            // comes back so the warning row updates without the user
            // having to leave and re-enter Settings.
            if newPhase == .active {
                Task { await refreshNotificationsAuthorization() }
            }
        }
        .sheet(isPresented: $showingTabEditor) {
            TabEditorView()
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
        // Result of a manual update check: up to date, or the App Store could not be
        // reached. `.updateNotifySheetHost()` handles `.offered`, so the row's Task
        // never raises this alert for it.
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
                // A manual open leaves `lastShownWhatsNewVersion` alone: this entry is
                // for re-reading, and stamping the seen marker here would suppress the
                // next automatic prompt.
                manualWhatsNewItem = nil
            }
            .whatsNewSheetPresentation()
        }
        #endif
    }

    #if os(iOS)
    /// Title for the manual update-check result alert. Mirrors iOS App
    /// Store style: "You're Up to Date" vs "Update Check Failed".
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
    /// "Check for Updates" row. Tapping forces an iTunes Lookup ignoring
    /// the 24h throttle. When the lookup succeeds and an update is
    /// available the existing `.updateNotifySheetHost()` modifier surfaces
    /// the regular prompt sheet — this row only handles the "already up
    /// to date" and "couldn't reach the App Store" feedback paths.
    @ViewBuilder
    private var checkForUpdatesRow: some View {
        Button {
            Task {
                await appState.updateNotifyCoordinator.checkManually()
                // Alert only when the coordinator will not show the sheet (`.upToDate`,
                // `.failed`). An `.offered` result goes to the sheet host, and a duplicate
                // alert here would stack on top of the sheet.
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

    /// "What's New" entry — always opens the newest release's flow
    /// (``WhatsNewCatalog`` pages plus its `whatsnew.json` summary),
    /// independent of the `lastShownWhatsNewVersion` gate. Hidden when
    /// neither has anything for the resolved locale (e.g. during early
    /// bring-up of a release where the JSON hasn't been filled in yet).
    @ViewBuilder
    private var whatsNewRow: some View {
        if appState.updateNotifyCoordinator.hasWhatsNewContent(in: appState) {
            Button {
                // Capture the entry at tap time and hand it to `.sheet(item:)`. Read in
                // the sheet body, `latestWhatsNew` can be nil though the row was visible,
                // as after a language change between render and tap, leaving the sheet empty.
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
            onLogout: { appState.logoutNTUST() }
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
    /// Red when signed out or when the server rejected the saved password.
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
    /// Factory-resets the app in place, without an uninstall.
    ///
    /// The two logouts run first. Only they unwind live state: in-flight sync tasks,
    /// the Live Activity, scheduled reminders, the push registration and the watch's
    /// library credentials. Wiping the stores under them would strand a Live Activity
    /// on the Lock Screen and a library login on the paired watch. Then come the stores
    /// a logout leaves alone, as an account change rather than a reset: the whole cache
    /// tree, every Keychain secret, the SwiftData store, both defaults domains, the outbox.
    private func eraseEverything() {
        appState.logoutNTUST()
        appState.logoutLibrary()
        #if os(iOS)
        // The mail password lives in its own Valet, which `SecureStore.removeAll` does
        // not reach; logging out wipes it with the mail caches and markers.
        MailAccountManager.shared.logout()
        // The developer mail-server override is in `UserDefaults`, which is wiped below, but
        // this process caches it in memory and would keep using that server until the next
        // launch. Unlike the API endpoint, kept in the Keychain, it does not survive a reset.
        DevMailServerSettings.shared.resetToSchoolServer()
        #endif

        DataCache.shared.clearEverything()

        // Everything except the endpoint: that override lives in the
        // Keychain precisely so it outlives a wipe, and a developer
        // resetting the app still wants to point at the same backend.
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

        // Removes outbox.json and any legacy id_map.json.
        try? FileManager.default.removeItem(at: SyncOutbox.defaultDirectory())

        appState.hasCompletedOnboarding = false
        Defaults[.hasCompletedOnboarding] = false
    }
    #endif

    /// Read the current system-level notification authorization so the
    /// warning row appears whenever the user has revoked permission
    /// (.denied) or has yet to grant it (.notDetermined). Re-runs on
    /// every `scenePhase == .active` so a System Settings round-trip
    /// updates the row without the user leaving Settings.
    private func refreshNotificationsAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        let authorized = (status == .authorized || status == .provisional || status == .ephemeral)
        await MainActor.run { notificationsAuthorized = authorized }
    }
}
