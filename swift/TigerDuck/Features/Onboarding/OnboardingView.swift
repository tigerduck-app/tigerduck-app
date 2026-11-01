import Defaults
import SwiftUI
import UserNotifications

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPage = 0
    @State private var studentId = ""
    @State private var password = ""
    @State private var agreedPrivacy = false
    @State private var agreedDeletion = false
    @State private var syncEnabled = true
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationRequestInFlight = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: OnboardingLoginPage.Field?

    private enum Page: Int, CaseIterable {
        case welcome, privacy, cloudSync, watchOS, login, notifications, ready
    }

    private var showsWatchPage: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .pad
        #else
        true
        #endif
    }

    var body: some View {
        TabView(selection: $currentPage) {
            welcomePage.tag(Page.welcome.rawValue)
            OnboardingPrivacyPage(
                agreedPrivacy: $agreedPrivacy,
                agreedDeletion: $agreedDeletion,
                isCurrent: currentPage == Page.privacy.rawValue,
                onNext: { go(to: .cloudSync) }
            )
            .tag(Page.privacy.rawValue)
            OnboardingCloudSyncPage(syncEnabled: $syncEnabled) {
                app.cloudSyncEnabled = syncEnabled
                go(to: showsWatchPage ? .watchOS : .login)
            }
            .tag(Page.cloudSync.rawValue)
            if showsWatchPage {
                watchOSPage.tag(Page.watchOS.rawValue)
            }
            OnboardingLoginPage(
                studentId: $studentId,
                password: $password,
                focusedField: $focusedField,
                onSkip: { go(to: .notifications) },
                onSignedIn: { go(to: .notifications) }
            )
            .tag(Page.login.rawValue)
            OnboardingNotificationsPage(
                status: notificationStatus,
                isRequesting: notificationRequestInFlight,
                onRequest: { Task { await requestNotifications() } },
                onNext: { go(to: .ready) }
            )
            .tag(Page.notifications.rawValue)
            readyPage.tag(Page.ready.rawValue)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(Color.backgroundPrimary)
        // Keyboard avoidance acts on the TabView root, not the page VStacks. Without this the login
        // page shrinks to fit above the keyboard, squeezing its ScrollView and lifting its buttons;
        // tap-to-dismiss and the ScrollView's scroll-to-dismiss still clear the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .contentShape(Rectangle())
        .onChange(of: currentPage) { _, page in
            focusedField = nil
            if page > Page.privacy.rawValue, !hasAgreedToTerms {
                currentPage = Page.privacy.rawValue
            }
        }
        .task { await refreshNotificationStatus() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await refreshNotificationStatus() }
            }
        }
    }

    private func go(to page: Page) {
        withAnimation(reduceMotion ? nil : .default) { currentPage = page.rawValue }
    }

    private var welcomePage: some View {
        OnboardingPageView(
            icon: .image("AppLogo"),
            title: String(localized: "onboarding_welcome_title"),
            subtitle: String(localized: "onboarding_welcome_subtitle"),
            accentColor: .onboardingAccent,
            content: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    Text(String(localized: "onboarding_welcome_description"))
                        .font(.callout)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(12)
                        .minimumScaleFactor(0.6)

                    // `Link` over `Button` keeps the `.isLink` VoiceOver trait and long-press peek,
                    // Copy Link and Share. Bordered and large for a reliable hit target. The page's
                    // dismiss tap is a `.simultaneousGesture`, so iOS 18 passes the first tap on.
                    VStack(spacing: TigerDuckTheme.Spacing.lg) {
                        Link(destination: AppURLs.website) {
                            Label(String(localized: "onboarding_welcome_website_label"), systemImage: "globe")
                                .frame(maxWidth: .infinity)
                        }
                        Link(destination: AppURLs.github) {
                            Label(String(localized: "onboarding_welcome_github_label"), systemImage: "chevron.left.forwardslash.chevron.right")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .font(.callout.weight(.semibold))
                    .padding(.top, TigerDuckTheme.Spacing.sm)
                }
            },
            actions: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    Button(String(localized: "action_next")) {
                        go(to: .privacy)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        )
    }

    private var hasAgreedToTerms: Bool { agreedPrivacy && agreedDeletion }

    private var watchOSPage: some View {
        OnboardingPageView(
            icon: "applewatch",
            title: String(localized: "onboarding_watchos_title"),
            subtitle: String(localized: "onboarding_watchos_description"),
            accentColor: .red
        ) {
            Button(String(localized: "action_next")) {
                go(to: .login)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func requestNotifications() async {
        notificationRequestInFlight = true
        defer { notificationRequestInFlight = false }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshNotificationStatus()
        guard granted else { return }
        app.pushSchedule.enablePushServer()
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { notificationStatus = settings.authorizationStatus }
    }

    private var readyPage: some View {
        OnboardingPageView(
            icon: "checkmark.circle.fill",
            title: String(localized: "onboarding_ready_title"),
            subtitle: String(localized: "onboarding_ready_subtitle"),
            accentColor: .onboardingAccent
        ) {
            Button(String(localized: "onboarding_start_button")) {
                app.completeOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(app.authService.isLoggingIn)
        }
    }
}
