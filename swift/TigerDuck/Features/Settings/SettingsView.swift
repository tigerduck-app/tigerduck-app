import SwiftUI

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
    @State private var showLicenseFullText = false
    @State private var loginStudentId = ""
    @State private var loginPassword = ""
    @State private var libUsername = ""
    @State private var libPassword = ""
    @State private var libIsLoggingIn = false
    @State private var libLoginError: String?

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
                libraryAccountRow
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

            // MARK: - Notifications
            Section("通知") {
                Toggle("作業到期提醒", isOn: $notifyAssignments)
                Toggle("公告通知", isOn: $notifyAnnouncements)
                Toggle("免費便當通知", isOn: $notifyFreeLunch)
                Toggle("社團活動通知", isOn: $notifyClubs)
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
                    showLicense = true
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
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("""
                        TigerDuck
                        Copyright (C) 2026 TigerDuck Contributors

                        This program is free software: you can redistribute it \
                        and/or modify it under the terms of the GNU Affero General \
                        Public License as published by the Free Software Foundation, \
                        either version 3 of the License, or (at your option) any \
                        later version.

                        This program is distributed in the hope that it will be \
                        useful, but WITHOUT ANY WARRANTY; without even the implied \
                        warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR \
                        PURPOSE. See the GNU Affero General Public License for \
                        more details.

                        You should have received a copy of the GNU Affero General \
                        Public License along with this program. If not, see \
                        <https://www.gnu.org/licenses/>.
                        """)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)

                        Button {
                            if appState.browserPreference == .inApp {
                                showLicenseFullText = true
                            } else {
                                UIApplication.shared.open(Self.licenseURL)
                            }
                        } label: {
                            Label("查看完整授權條款", systemImage: "doc.text")
                        }
                        .sheet(isPresented: $showLicenseFullText) {
                            InAppBrowserView(url: Self.licenseURL)
                                .ignoresSafeArea()
                        }
                    }
                    .padding()
                }
                .background(Color.backgroundPrimary)
                .navigationTitle("開源授權 — AGPLv3")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showLicense = false }
                    }
                }
            }
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
                if let expiry = appState.sessionManager.cookieExpiryDate {
                    Text("Cookie 有效至 \(expiry.formatted(.dateTime.hour().minute().second()))")
                        .font(.caption2)
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
                if let expiry = LibraryService.storedTokenExpiry {
                    Text("Token 有效至 \(expiry.formatted(.dateTime.year().month().day()))")
                        .font(.caption2)
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
