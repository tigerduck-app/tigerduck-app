import SwiftUI
import CoreHaptics

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var notifyAssignments = true
    @State private var notifyAnnouncements = true
    @State private var notifyFreeLunch = true
    @State private var notifyClubs = false
    @State private var showingTabEditor = false
    @State private var showLicense = false
    @State private var showPrivacyPolicy = false
    @State private var showFeedback = false
    @State private var showLibraryLogin = false
    @State private var libIsLoggingIn = false
    @State private var libLoginError: String?
    @State private var showLibraryWarning = false
    @State private var pendingLibraryEnable = false
    @State private var warningFlash = false
    @State private var libraryWarningTask: Task<Void, Never>?
    @State private var hapticEngine: CHHapticEngine?
    @State private var hapticPlayer: CHHapticPatternPlayer?

    private static let feedbackURL = URL(string: "https://github.com/tigerduck-app/tigerduck-app/issues")!
    private static let privacyURL = URL(string: "https://app.ntust.org/tigerduck/privacy")!
    private static let licenseURL = URL(string: "https://github.com/tigerduck-app/tigerduck-app/blob/main/LICENSE")!

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
                                withAnimation(.smoothSpring) {
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
                Toggle(String(localized: "settings_invert_slider_direction"), isOn: $appState.invertSliderDirection)
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
                    }
                }
            }

            // MARK: - Other Features
            Section(String(localized: "settings_section_other_features")) {
                Toggle(String(localized: "settings_library_related_features"), isOn: libraryToggleBinding)
            }

            // MARK: - Notifications & Live Activity
            Section(String(localized: "settings_section_notifications")) {
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
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
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
                Button {
                    if appState.browserPreference == .inApp {
                        showFeedback = true
                    } else {
                        UIApplication.shared.open(Self.feedbackURL)
                    }
                } label: {
                    Text(String(localized: "settings_feedback_bug_report"))
                }
                Button {
                    if appState.browserPreference == .inApp {
                        showPrivacyPolicy = true
                    } else {
                        UIApplication.shared.open(Self.privacyURL)
                    }
                } label: {
                    Text(String(localized: "settings_privacy_policy"))
                }
                Button(String(localized: "settings_open_source_licenses")) {
                    if appState.browserPreference == .inApp {
                        showLicense = true
                    } else {
                        UIApplication.shared.open(Self.licenseURL)
                    }
                }
                NavigationLink(String(localized: "settings_view_source_code")) {
                    SourceCodePickerView()
                }
            }
        }
        .navigationTitle(String(localized: "feature_settings"))
        .sheet(isPresented: $showingTabEditor) {
            TabEditorView()
        }
        .sheet(isPresented: $showFeedback) {
            InAppBrowserView(url: Self.feedbackURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            InAppBrowserView(url: Self.privacyURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showLicense) {
            InAppBrowserView(url: Self.licenseURL)
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
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        warningFlash = true
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
    }

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
}

// MARK: - Library Warning Overlay

private struct LibraryWarningOverlay: View {
    @Binding var isFlashing: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

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
            withAnimation(.easeInOut(duration: 0.3)) {
                confirmEnabled = true
            }
        }
    }
}
