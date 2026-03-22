import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentPage = 0
    @State private var studentId = ""
    @State private var password = ""

    var body: some View {
        TabView(selection: $currentPage) {
            // Page 1: Welcome
            OnboardingPageView(
                icon: "graduationcap.fill",
                title: "歡迎使用 TigerDuck",
                subtitle: "你的臺科大校園助手",
                accentColor: .accentPrimary
            ) {
                Button("下一步") {
                    withAnimation { currentPage = 1 }
                }
                .buttonStyle(.borderedProminent)
            }
            .tag(0)

            // Page 2: Login
            OnboardingPageView(
                icon: "person.badge.key.fill",
                title: "登入帳號",
                subtitle: "使用 NTUST SSO 登入以存取課表、Moodle 等功能",
                accentColor: .green
            ) {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    TextField("學號", text: $studentId)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .frame(maxWidth: 280)

                    SecureField("密碼", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .frame(maxWidth: 280)

                    if let error = appState.authService.loginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task {
                            let success = await appState.authService.login(
                                studentId: studentId,
                                password: password
                            )
                            if success {
                                withAnimation { currentPage = 2 }
                            }
                        }
                    } label: {
                        if appState.authService.isLoggingIn {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("登入 NTUST SSO")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(studentId.isEmpty || password.isEmpty || appState.authService.isLoggingIn)

                    Button("暫時跳過") {
                        withAnimation { currentPage = 2 }
                    }
                    .foregroundStyle(Color.textSecondary)
                }
            }
            .tag(1)

            // Page 3: Feature selection
            OnboardingPageView(
                icon: "slider.horizontal.3",
                title: "選擇功能",
                subtitle: "你可以之後在設定中隨時調整",
                accentColor: .orange
            ) {
                Button("下一步") {
                    withAnimation { currentPage = 3 }
                }
                .buttonStyle(.borderedProminent)
            }
            .tag(2)

            // Page 4: Done
            OnboardingPageView(
                icon: "checkmark.circle.fill",
                title: "準備就緒！",
                subtitle: "開始探索你的校園生活",
                accentColor: .accentPrimary
            ) {
                Button("開始使用 TigerDuck") {
                    appState.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(Color.backgroundPrimary)
    }
}

