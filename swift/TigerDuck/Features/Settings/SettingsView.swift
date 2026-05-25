import SwiftUI
import CoreHaptics
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) private var appState
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
    @State private var showLibraryWarning = false
    @State private var pendingLibraryEnable = false
    @State private var warningFlash = false
    @State private var libraryWarningTask: Task<Void, Never>?
    @State private var hapticEngine: CHHapticEngine?
    @State private var hapticPlayer: CHHapticPatternPlayer?
    @State private var notificationsAuthorized: Bool = true
    @State private var showOfficialWebsite = false
    #if os(iOS)
    /// Drives the "you're up to date" / "couldn't reach the App Store"
    /// feedback alert that fires after the manual Check for Updates row.
    /// Only true when the coordinator emitted a result that isn't already
    /// surfaced through the auto-presented update sheet — an `.offered`
    /// result is shown via that sheet path, not this alert.
    @State private var showManualUpdateCheckResultAlert = false
    /// Item for the Settings → What's New row, allowing repeat
    /// presentation of the latest release notes independent of the
    /// auto-launch gate's seen-state. Driven by `.sheet(item:)` rather
    /// than `.sheet(isPresented:)` so the entry is captured at present
    /// time — a stale `latestWhatsNew == nil` between the row tap and
    /// the sheet body evaluation cannot leak an empty sheet onto
    /// screen.
    @State private var manualWhatsNewItem: WhatsNewRepository.ResolvedWhatsNew?
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
            }

            // MARK: - Customization
            Section(String(localized: "settings_section_custom")) {
                Button(String(localized: "tab_editor_title")) {
                    showingTabEditor = true
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "settings_color_theme"))
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
                        // Default Picker layout puts the label and the
                        // selected value on the same line — with a long
                        // localized label (e.g. "When classroom name is
                        // in Mandarin") the value gets squeezed and
                        // truncated. Render the label above the menu so
                        // both halves can use the full row width.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "settings_classroom_mandarin_display"))
                                .fixedSize(horizontal: false, vertical: true)
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
                            .labelsHidden()
                        }
                    }
                }
            }

            // MARK: - Notifications & Live Activity
            Section(String(localized: "settings_section_notifications")) {
                #if os(iOS)
                // The "denied -> open System Settings" deeplink is iOS-only;
                // macOS has its own MacSettingsScene and no openSettingsURLString.
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
                NavigationLink(String(localized: "live_activity_settings_nav_title")) {
                    LiveActivitySettingsView(store: appState.liveActivityPreferences)
                }
                NavigationLink(String(localized: "settings_push_server_nav_label")) {
                    PushServerSettingsView()
                }
            }

            // MARK: - Language
            // The user picks the app language in iOS Settings (per-app
            // language picker). iOS restarts the process on selection,
            // which is why we don't need an in-app picker.
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

            // MARK: - Other settings
            // Library toggle keeps its position at the top of the
            // "Other settings" group; the rest of the miscellany now lives
            // behind a NavigationLink to `OtherSettingsView`.
            Section(String(localized: "settings_section_other_settings")) {
                Toggle(String(localized: "settings_library_related_features"), isOn: libraryToggleBinding)
                NavigationLink(String(localized: "settings_section_other_settings")) {
                    OtherSettingsView()
                }
            }

            // MARK: - About
            Section(String(localized: "settings_section_about")) {
                LabeledContent(String(localized: "settings_version"), value: appVersion)
                #if os(iOS)
                checkForUpdatesRow
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
            }

            #if DEBUG
            Section("Developer") {
                NavigationLink("Time override") {
                    DebugSettingsView()
                }
                NavigationLink("Notifications") {
                    DebugNotificationsView()
                }
                NavigationLink("API endpoint") {
                    DebugEndpointView()
                }
                #if os(iOS)
                NavigationLink("Triggers") {
                    TriggersDebugView()
                }
                #endif
                // Bypass `.screenCaptureProtected(...)` system-wide for
                // demo recordings / layout debugging. Backed by
                // `@AppStorage` so toggling immediately re-evaluates
                // every protected view. Compiled out of release builds.
                Toggle("Disable screen-capture protection", isOn: $disableScreenCaptureProtection)
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
        .sheet(isPresented: $showLibraryLogin) {
            LoginSheet(
                title: String(localized: "settings_account_library_system"),
                subtitle: String(localized: "settings_library_account_subtitle"),
                usernamePlaceholder: String(localized: "login_student_id"),
                passwordPlaceholder: String(localized: "login_password"),
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
        .overlay {
            if showLibraryWarning {
                LibraryWarningOverlay(
                    isFlashing: $warningFlash,
                    onCancel: {
                        pendingLibraryEnable = false
                        showLibraryWarning = false
                        warningFlash = false
                    },
                    onConfirm: {
                        pendingLibraryEnable = false
                        appState.libraryFeatureEnabled = true
                        // Auto-add library tab if there's room
                        if !appState.configuredTabs.contains(.library),
                           appState.configuredTabs.count < 4 {
                            appState.configuredTabs.append(.library)
                        }
                        showLibraryWarning = false
                        warningFlash = false
                    }
                )
                .onAppear {
                    warningFlash = false
                    if !reduceMotion {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            warningFlash = true
                        }
                    }
                    triggerWarningVibration()
                }
                .onDisappear {
                    hapticPlayer = nil
                    hapticEngine?.stop()
                    hapticEngine = nil
                }
            }
        }
        .onDisappear {
            // Cancel any pending warning-overlay delay so it can't fire
            // (and the countdown loop in LibraryWarningOverlay can't try to
            // mutate state on a torn-down view) after Settings closes.
            libraryWarningTask?.cancel()
            libraryWarningTask = nil
        }
        #if os(iOS)
        // Manual-check-result alert — covers the "you're up to date" and
        // "couldn't reach the App Store" outcomes. The .offered case is
        // handled by `.updateNotifySheetHost()` instead, so the row's
        // Task explicitly suppresses this alert in that branch.
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
        .sheet(item: $manualWhatsNewItem) { entry in
            WhatsNewSheetView(entry: entry) {
                // Manual open does NOT advance
                // `lastShownWhatsNewVersion` — the Settings entry is a
                // re-visit surface, and stamping the seen marker here
                // would silently suppress the next auto-prompt after
                // viewing release notes again.
                manualWhatsNewItem = nil
            }
            .presentationDetents([.fraction(0.85), .large])
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

    private var libraryToggleBinding: Binding<Bool> {
        Binding(
            get: { appState.libraryFeatureEnabled || pendingLibraryEnable },
            set: { newValue in
                if newValue {
                    guard !showLibraryWarning else { return }
                    pendingLibraryEnable = true
                    libraryWarningTask?.cancel()
                    libraryWarningTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        showLibraryWarning = true
                    }
                } else {
                    pendingLibraryEnable = false
                    appState.libraryFeatureEnabled = false
                    appState.configuredTabs.removeAll { AppFeature.libraryRelatedFeatures.contains($0) }
                }
            }
        )
    }

    private func triggerWarningVibration() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            try engine.start()
            self.hapticEngine = engine
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0,
                duration: 1.0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            self.hapticPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Silently fail on devices without haptic support
        }
    }

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
                // Only raise the local alert when the coordinator decided
                // not to drive the auto-sheet (.upToDate / .failed). An
                // `.offered` result hands off to the sheet host so a
                // duplicate alert here would stack on top of the sheet.
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

    /// "What's New" entry — always opens the latest entry registered
    /// in `whatsnew.json`, independent of the
    /// `lastShownWhatsNewVersion` gate. Hidden when the asset has no
    /// entries for the resolved locale (e.g. during early bring-up of
    /// a release where the JSON hasn't been filled in yet).
    @ViewBuilder
    private var whatsNewRow: some View {
        if appState.updateNotifyCoordinator.hasWhatsNewContent {
            Button {
                // Capture the entry at tap time and pass it directly to
                // `.sheet(item:)` — avoids the empty-sheet edge case
                // where the row was visible on the latest render but
                // `latestWhatsNew` evaluates to nil inside the sheet
                // body (e.g. language change between render and tap).
                manualWhatsNewItem = appState.updateNotifyCoordinator.latestWhatsNew
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
                Text(String(localized: "action_logout"))
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button(action: onLogin) {
                Text(String(localized: "action_login"))
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

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

// MARK: - Library Warning Overlay

private struct LibraryWarningOverlay: View {
    @Binding var isFlashing: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var countdown = 5
    @State private var confirmEnabled = false

    private var confirmLabel: String {
        if confirmEnabled {
            return String(localized: "settings_library_warning_confirm")
        }
        let format = String(localized: "settings_library_warning_confirm_countdown")
        return String(format: format, countdown)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Flashing warning title
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(String(localized: "settings_library_warning_title"))
                }
                .font(.headline.bold())
                .foregroundStyle(.red)
                .opacity(isFlashing ? 0.15 : 1.0)

                // Warning message
                Text(String(localized: "settings_library_warning_message"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Buttons
                VStack(spacing: 10) {
                    Button(action: onConfirm) {
                        Text(confirmLabel)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                confirmEnabled ? Color.red : Color.red.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!confirmEnabled)

                    Button(action: onCancel) {
                        Text(String(localized: "settings_library_warning_dismiss"))
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
        .task {
            for i in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                countdown = i
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                confirmEnabled = true
            }
        }
    }
}
