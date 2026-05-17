import SwiftUI
import UserNotifications

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentPage = 0
    @State private var studentId = ""
    @State private var password = ""
    @State private var agreedPrivacy = false
    @State private var agreedDeletion = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationRequestInFlight = false
    @FocusState private var focusedField: Field?

    private enum Field { case studentId, password }

    /// Page order matches the Android flow at
    /// `OnboardingScreen.kt:85-87`: Welcome → Privacy → Apple Watch →
    /// Login → Notifications → Ready.
    private enum Page: Int, CaseIterable {
        case welcome, privacy, watchOS, login, notifications, ready
    }

    private let lastPageIndex = Page.allCases.count - 1

    var body: some View {
        TabView(selection: $currentPage) {
            welcomePage.tag(Page.welcome.rawValue)
            privacyPage.tag(Page.privacy.rawValue)
            watchOSPage.tag(Page.watchOS.rawValue)
            loginPage.tag(Page.login.rawValue)
            notificationsPage.tag(Page.notifications.rawValue)
            readyPage.tag(Page.ready.rawValue)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(Color.backgroundPrimary)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
        .onChange(of: currentPage) { _, _ in focusedField = nil }
        .task { await refreshNotificationStatus() }
    }

    // MARK: - Page 0: Welcome

    private var welcomePage: some View {
        OnboardingPageView(
            icon: "graduationcap.fill",
            title: String(localized: "onboarding_welcome_title"),
            subtitle: String(localized: "onboarding_welcome_subtitle"),
            accentColor: .accentPrimary,
            content: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    Text(String(localized: "onboarding_welcome_description"))
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: TigerDuckTheme.Spacing.sm) {
                        Link(String(localized: "onboarding_welcome_website_label"), destination: AppURLs.website)
                        Link(String(localized: "onboarding_welcome_github_label"), destination: AppURLs.github)
                    }
                    .font(.footnote.weight(.semibold))
                }
            },
            actions: {
                Button(String(localized: "action_next")) {
                    withAnimation { currentPage = Page.privacy.rawValue }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        )
    }

    // MARK: - Page 1: Privacy & terms

    private var privacyPage: some View {
        OnboardingPageView(
            icon: "lock.shield.fill",
            title: String(localized: "onboarding_privacy_title"),
            subtitle: String(localized: "onboarding_privacy_subtitle"),
            accentColor: .blue,
            iconAnimation: .layerFlash,
            content: {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
                    privacyCheckbox(
                        isOn: $agreedPrivacy,
                        label: String(localized: "onboarding_privacy_policy_label"),
                        destination: AppURLs.privacyPolicy
                    )
                    privacyCheckbox(
                        isOn: $agreedDeletion,
                        label: String(localized: "onboarding_privacy_delete_account_label"),
                        destination: AppURLs.deleteAccount
                    )
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            },
            actions: {
                VStack(spacing: TigerDuckTheme.Spacing.sm) {
                    Text(String(localized: "onboarding_privacy_continue_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(agreedPrivacy && agreedDeletion ? 0 : 1)

                    Button(String(localized: "action_next")) {
                        withAnimation { currentPage = Page.watchOS.rawValue }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!(agreedPrivacy && agreedDeletion))
                }
            }
        )
    }

    private func privacyCheckbox(
        isOn: Binding<Bool>, label: String, destination: URL
    ) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isOn.wrappedValue ? Color.accentPrimary : Color.textSecondary)
            }
            .buttonStyle(.plain)

            Link(label, destination: destination)
                .font(.callout)
            Spacer()
        }
        .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
    }

    // MARK: - Page 2: Apple Watch support

    private var watchOSPage: some View {
        OnboardingPageView(
            icon: "applewatch",
            title: String(localized: "onboarding_watchos_title"),
            subtitle: String(localized: "onboarding_watchos_description"),
            accentColor: .red
        ) {
            Button(String(localized: "action_next")) {
                withAnimation { currentPage = Page.login.rawValue }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Page 3: Login

    private var loginPage: some View {
        let isSignedIn = appState.authService.hasStoredCredentials

        return OnboardingPageView(
            icon: "person.badge.key.fill",
            title: String(localized: "onboarding_login_title"),
            subtitle: String(localized: "onboarding_login_subtitle"),
            accentColor: .green,
            content: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    VStack(spacing: 1) {
                        HStack(spacing: TigerDuckTheme.Spacing.md) {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField(String(localized: "login_student_id"), text: $studentId)
                                .keyboardType(.asciiCapable)
                                .focused($focusedField, equals: .studentId)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                        .background(.fill.quaternary, in: .rect(topLeadingRadius: TigerDuckTheme.CornerRadius.md, topTrailingRadius: TigerDuckTheme.CornerRadius.md))

                        Divider()
                            .padding(.horizontal, TigerDuckTheme.Spacing.lg)

                        HStack(spacing: TigerDuckTheme.Spacing.md) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            PasswordField(
                                placeholder: String(localized: "login_password"),
                                text: $password,
                                focusBinding: $focusedField,
                                focusValue: .password,
                                onSubmit: { submitLogin() }
                            )
                        }
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                        .background(.fill.quaternary, in: .rect(bottomLeadingRadius: TigerDuckTheme.CornerRadius.md, bottomTrailingRadius: TigerDuckTheme.CornerRadius.md))
                    }
                    .frame(maxWidth: 320)

                    if let error = appState.authService.loginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if isSignedIn {
                        Label(
                            String(localized: "action_done"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                    }
                }
            },
            actions: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    Button(String(localized: "onboarding_skip_for_now")) {
                        withAnimation { currentPage = Page.notifications.rawValue }
                    }
                    .foregroundStyle(Color.textSecondary)

                    Button {
                        submitLogin()
                    } label: {
                        LoadingButtonLabel(
                            isLoading: appState.authService.isLoggingIn,
                            tint: .white
                        ) {
                            Text(String(localized: "onboarding_login_button"))
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(studentId.isEmpty || password.isEmpty || appState.authService.isLoggingIn)
                }
            }
        )
    }

    private func submitLogin() {
        UIApplication.dismissKeyboard()
        focusedField = nil
        let trimmedId = studentId.trimmingCharacters(in: .whitespaces)
        let trimmedPwd = password.trimmingCharacters(in: .whitespaces)
        guard !trimmedId.isEmpty, !trimmedPwd.isEmpty, !appState.authService.isLoggingIn else { return }
        Task {
            let success = await appState.authService.login(
                studentId: trimmedId, password: trimmedPwd
            )
            if success { withAnimation { currentPage = Page.notifications.rawValue } }
        }
    }

    // MARK: - Page 4: Notifications

    private var notificationsPage: some View {
        OnboardingPageView(
            icon: "bell.badge.fill",
            title: String(localized: "onboarding_permissions_title"),
            subtitle: String(localized: "onboarding_permissions_subtitle"),
            accentColor: .orange,
            content: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    notificationStatusRow

                    if notificationStatus == .denied {
                        Button(String(localized: "action_go_to_settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            },
            actions: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    Button(String(localized: "onboarding_skip_for_now")) {
                        withAnimation { currentPage = Page.ready.rawValue }
                    }
                    .foregroundStyle(Color.textSecondary)

                    Button(String(localized: "action_next")) {
                        withAnimation { currentPage = Page.ready.rawValue }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        )
    }

    @ViewBuilder
    private var notificationStatusRow: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Label(String(localized: "bulletin_push_status_registration_done"), systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
        case .denied:
            Label(String(localized: "bulletin_push_status_denied"), systemImage: "xmark.octagon.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
        case .notDetermined:
            Button {
                Task { await requestNotifications() }
            } label: {
                LoadingButtonLabel(
                    isLoading: notificationRequestInFlight,
                    tint: .white
                ) {
                    Label(String(localized: "action_allow"), systemImage: "bell.fill")
                        .font(.callout.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(notificationRequestInFlight)
        @unknown default:
            EmptyView()
        }
    }

    private func requestNotifications() async {
        notificationRequestInFlight = true
        defer { notificationRequestInFlight = false }
        let center = UNUserNotificationCenter.current()
        _ = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshNotificationStatus()
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { notificationStatus = settings.authorizationStatus }
    }

    // MARK: - Page 5: Done

    private var readyPage: some View {
        OnboardingPageView(
            icon: "checkmark.circle.fill",
            title: String(localized: "onboarding_ready_title"),
            subtitle: String(localized: "onboarding_ready_subtitle"),
            accentColor: .accentPrimary
        ) {
            Button(String(localized: "onboarding_start_button")) {
                appState.completeOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.authService.isLoggingIn)
        }
    }
}
