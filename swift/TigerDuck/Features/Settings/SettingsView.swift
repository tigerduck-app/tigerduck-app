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
    @State private var loginStudentId = ""
    @State private var loginPassword = ""
    @State private var libUsername = ""
    @State private var libPassword = ""
    @State private var libIsLoggingIn = false
    @State private var libLoginError: String?
    @State private var showLibraryWarning = false
    @State private var warningFlash = false
    @State private var hapticEngine: CHHapticEngine?

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
                Toggle("作業截止時間顯示完整日期", isOn: $appState.showAbsoluteAssignmentTime)
                Toggle("記住公告篩選條件", isOn: $appState.rememberAnnouncementFilter)
                Picker("開啟連結方式", selection: $appState.browserPreference) {
                    Text("系統預設瀏覽器").tag(BrowserPreference.system)
                    Text("App 內瀏覽器").tag(BrowserPreference.inApp)
                }
                Picker("時間滑條樣式", selection: $appState.timeSliderStyle) {
                    ForEach(TimeSliderStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("反轉滑條方向", isOn: $appState.invertSliderDirection)
            }

            // MARK: - Other Features
            Section("其他功能") {
                Toggle("圖書館及相關功能", isOn: libraryToggleBinding)
            }

            // MARK: - Notifications (hidden — not yet implemented)
//            Section("通知") {
//                Toggle("作業到期提醒", isOn: $notifyAssignments)
//                Toggle("公告通知", isOn: $notifyAnnouncements)
//                Toggle("免費便當通知", isOn: $notifyFreeLunch)
//                Toggle("社團活動通知", isOn: $notifyClubs)
//            }

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
        .overlay {
            if showLibraryWarning {
                LibraryWarningOverlay(
                    isFlashing: $warningFlash,
                    onCancel: {
                        showLibraryWarning = false
                        warningFlash = false
                    },
                    onConfirm: {
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
            }
        }
    }

    private var libraryToggleBinding: Binding<Bool> {
        Binding(
            get: { appState.libraryFeatureEnabled },
            set: { newValue in
                if newValue {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        showLibraryWarning = true
                    }
                } else {
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
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Silently fail on devices without haptic support
        }
    }

    private var ntustAccountRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(appState.isNTUSTLoggedIn ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("NTUST 校務系統")
                    .font(.headline)
                Spacer()
                if appState.authService.isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(appState.isNTUSTLoggedIn ? "已登入" : "未登入")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if appState.isNTUSTLoggedIn {
                if let studentId = appState.authService.storedStudentId {
                    Text("學號：\(studentId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("登出", role: .destructive) {
                    appState.authService.logout()
                    loginStudentId = ""
                    loginPassword = ""
                }
            } else {
                TextField("學號", text: $loginStudentId)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                SecureField("密碼", text: $loginPassword)
                    .textContentType(.password)

                if let error = appState.authService.loginError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }

                Button("登入 NTUST") {
                    Task {
                        await appState.authService.login(
                            studentId: loginStudentId,
                            password: loginPassword
                        )
                    }
                }
                .disabled(loginStudentId.isEmpty || loginPassword.isEmpty || appState.authService.isLoggingIn)
            }
        }
    }

    private var libraryAccountRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(LibraryService.isTokenValid ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("圖書館系統")
                    .font(.headline)
                Spacer()
                if libIsLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(LibraryService.isTokenValid ? "已登入" : "未登入")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if LibraryService.isTokenValid {
                if let username = LibraryService.storedUsername {
                    Text("帳號：\(username)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("登出", role: .destructive) {
                    LibraryService.clearCredentials()
                    libUsername = ""
                    libPassword = ""
                }
            } else {
                Text("帳號密碼可能與校務系統不同")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                TextField("圖書館帳號", text: $libUsername)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                SecureField("圖書館密碼", text: $libPassword)
                    .textContentType(.password)

                if let error = libLoginError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }

                Button("登入圖書館") {
                    Task {
                        libIsLoggingIn = true
                        libLoginError = nil
                        do {
                            try await LibraryService.login(
                                username: libUsername,
                                password: libPassword
                            )
                            libUsername = ""
                            libPassword = ""
                        } catch {
                            libLoginError = error.localizedDescription
                        }
                        libIsLoggingIn = false
                    }
                }
                .disabled(libUsername.isEmpty || libPassword.isEmpty || libIsLoggingIn)
            }
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
                Text("本應用程式非臺科大官方圖書館應用程式，且尚未得到學校圖書館認可，無法保證各項功能的正常使用及其他相關使用後果。\n\n如需使用請謹慎。若使後產生任何負面結果，需自負責任，且與 tigerduck-app 一律無關！")
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
