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
    @State private var showSourceCode = false
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
    private static let sourceCodeURL = URL(string: "https://github.com/tigerduck-app/tigerduck-app")!

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (Build \(build))"
    }

    var body: some View {
        @Bindable var appState = appState
        List {
            // MARK: - Account
            Section("帳號") {
                ntustAccountRow
                if appState.libraryFeatureEnabled {
                    libraryAccountRow
                }
            }

            // MARK: - Customization
            Section("自訂") {
                Button("Tab 編輯器") {
                    showingTabEditor = true
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("主題色")
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
            Section("顯示") {
                Picker("介面風格", selection: $appState.visualPreset) {
                    ForEach(VisualPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                Toggle("作業截止時間顯示完整日期", isOn: $appState.showAbsoluteAssignmentTime)
                Toggle("記住公告篩選條件", isOn: $appState.rememberAnnouncementFilter)
                Picker("開啟連結方式", selection: $appState.browserPreference) {
                    Text("系統預設瀏覽器").tag(BrowserPreference.system)
                    Text("App 內瀏覽器").tag(BrowserPreference.inApp)
                }
                Toggle("反轉滑條方向", isOn: $appState.invertSliderDirection)
            }

            // MARK: - Other Features
            Section("其他功能") {
                Toggle("圖書館及相關功能", isOn: libraryToggleBinding)
            }

            // MARK: - Notifications & Live Activity
            Section("通知") {
                NavigationLink("即時動態 Live Activity（實驗性）") {
                    LiveActivitySettingsView(store: appState.liveActivityPreferences)
                }
            }

            // MARK: - About
            Section("關於") {
                LabeledContent("版本", value: appVersion)
                Button {
                    if appState.browserPreference == .inApp {
                        showFeedback = true
                    } else {
                        UIApplication.shared.open(Self.feedbackURL)
                    }
                } label: {
                    Text("回饋/問題回報")
                }
                Button {
                    if appState.browserPreference == .inApp {
                        showPrivacyPolicy = true
                    } else {
                        UIApplication.shared.open(Self.privacyURL)
                    }
                } label: {
                    Text("隱私權政策")
                }
                Button("開源授權") {
                    if appState.browserPreference == .inApp {
                        showLicense = true
                    } else {
                        UIApplication.shared.open(Self.licenseURL)
                    }
                }
                Button("查看原始碼") {
                    if appState.browserPreference == .inApp {
                        showSourceCode = true
                    } else {
                        UIApplication.shared.open(Self.sourceCodeURL)
                    }
                }
            }
        }
        .navigationTitle("設定")
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
        .sheet(isPresented: $showSourceCode) {
            InAppBrowserView(url: Self.sourceCodeURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showLibraryLogin) {
            LoginSheet(
                title: "圖書館系統",
                usernamePlaceholder: "學號",
                passwordPlaceholder: "密碼",
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
            title: "校務系統",
            isLoggedIn: appState.isNTUSTLoggedIn,
            detail: appState.authService.storedStudentId,
            onLogin: { appState.presentNTUSTLogin() },
            onLogout: { appState.logoutNTUST() }
        )
    }

    private var libraryAccountRow: some View {
        accountRow(
            title: "圖書館系統",
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
                Text("登出")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button(action: onLogin) {
                Text("登入")
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Flashing warning title
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("請注意！")
                }
                .font(.headline.bold())
                .foregroundStyle(.red)
                .opacity(isFlashing ? 0.15 : 1.0)

                // Warning message
                Text("本應用程式非臺科大官方圖書館應用程式，且尚未得到學校圖書館認可，無法保證各項功能的正常使用及其他相關使用後果。\n\n如需使用請謹慎。若使用後產生任何負面結果，需自負責任，且與 tigerduck-app 一律無關！")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Buttons
                VStack(spacing: 10) {
                    Button(action: onConfirm) {
                        Text(confirmEnabled ? "我願意自負後果" : "我願意自負後果（\(countdown)）")
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
                        Text("退回")
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
