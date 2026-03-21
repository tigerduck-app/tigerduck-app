import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentPage = 0

    var body: some View {
        TabView(selection: $currentPage) {
            // Page 1: Welcome
            OnboardingPageView(
                icon: "graduationcap.fill",
                title: "歡迎使用 TigerDuck",
                subtitle: "你的台科大校園助手",
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
                    Button("登入 NTUST SSO") {
                        // TODO: Trigger SSO login
                        withAnimation { currentPage = 2 }
                    }
                    .buttonStyle(.borderedProminent)

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

