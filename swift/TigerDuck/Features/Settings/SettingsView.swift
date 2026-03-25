import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var notifyAssignments = true
    @State private var notifyAnnouncements = true
    @State private var notifyFreeLunch = true
    @State private var notifyClubs = false
    @State private var showingTabEditor = false
    @State private var showLicense = false
    @State private var loginStudentId = ""
    @State private var loginPassword = ""
    @State private var libUsername = ""
    @State private var libPassword = ""
    @State private var libIsLoggingIn = false
    @State private var libLoginError: String?

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
                Text("回饋/問題回報")
                Text("隱私權政策")
                Button("開源授權") {
                    showLicense = true
                }
            }
        }
        .navigationTitle("設定")
        .sheet(isPresented: $showingTabEditor) {
            TabEditorView()
        }
        .sheet(isPresented: $showLicense) {
            NavigationStack {
                ScrollView {
                    Text("""
                    MIT License

                    Copyright (c) 2026 TigerDuck

                    Permission is hereby granted, free of charge, to any person obtaining a copy \
                    of this software and associated documentation files (the "Software"), to deal \
                    in the Software without restriction, including without limitation the rights \
                    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
                    copies of the Software, and to permit persons to whom the Software is \
                    furnished to do so, subject to the following conditions:

                    The above copyright notice and this permission notice shall be included in all \
                    copies or substantial portions of the Software.

                    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
                    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
                    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
                    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
                    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
                    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
                    SOFTWARE.
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .padding()
                }
                .background(Color.backgroundPrimary)
                .navigationTitle("開源授權")
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
