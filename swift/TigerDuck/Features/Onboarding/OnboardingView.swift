import SwiftUI
import UserNotifications

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPage = 0
    @State private var studentId = ""
    @State private var password = ""
    @State private var agreedPrivacy = false
    @State private var agreedDeletion = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationRequestInFlight = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: Field?

    private enum Field { case studentId, password }

    /// Page order matches the Android flow at
    /// `OnboardingScreen.kt:85-87`: Welcome → Privacy → Apple Watch →
    /// Login → Notifications → Ready.
    private enum Page: Int, CaseIterable {
        case welcome, privacy, watchOS, login, notifications, ready
    }

    /// iPad has no Apple Watch pairing affordance — there's no Watch app to
    /// install from the iPad, so the slide is pure noise there. Keep it for
    /// iPhone (the canonical pairing host) and for any non-iOS host.
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
            privacyPage.tag(Page.privacy.rawValue)
            if showsWatchPage {
                watchOSPage.tag(Page.watchOS.rawValue)
            }
            loginPage.tag(Page.login.rawValue)
            notificationsPage.tag(Page.notifications.rawValue)
            readyPage.tag(Page.ready.rawValue)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(Color.backgroundPrimary)
        // Keyboard avoidance hits the TabView root, not the inner page
        // VStacks — without this the login page's overall frame shrinks
        // to fit above the keyboard, squeezing the credential ScrollView
        // and dragging the Sign in / Skip-for-now actions up with it.
        // Ignoring it at the TabView level keeps every page laid out
        // against the device geometry; tap-to-dismiss on each page (and
        // the inner ScrollView's interactive scroll-to-dismiss) still
        // give the user a way to clear the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .contentShape(Rectangle())
        // Simultaneous (not `.onTapGesture`) so this keyboard-dismiss tap on the
        // TabView root doesn't swallow taps on interactive children — see
        // View+ScrollSafeGesture for the iOS 18 gesture-arbitration details.
        .dismissTapGesture { focusedField = nil }
        .onChange(of: currentPage) { _, _ in focusedField = nil }
        .task { await refreshNotificationStatus() }
        .onChange(of: scenePhase) { _, newPhase in
            // Catch a System Settings round-trip — if the user enabled
            // notifications externally, reflect that the moment they
            // return so the denied row + settings button stop showing.
            if newPhase == .active {
                Task { await refreshNotificationStatus() }
            }
        }
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
                        .font(.callout)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(12)
                        .minimumScaleFactor(0.6)

                    // `Link` (not a bare `Button`) keeps the semantic
                    // `.isLink` VoiceOver trait and the system URL affordances
                    // (long-press peek / Copy Link / Share). The bordered,
                    // large control size gives the reliable hit target the
                    // plain text links lacked, and now that the page's
                    // keyboard-dismiss tap is a `.simultaneousGesture` it no
                    // longer swallows these links' first tap on iOS 18.
                    VStack(spacing: TigerDuckTheme.Spacing.lg) {
                        Link(destination: AppURLs.website) {
                            Label(String(localized: "onboarding_welcome_website_label"), systemImage: "globe")
                        }
                        Link(destination: AppURLs.github) {
                            Label(String(localized: "onboarding_welcome_github_label"), systemImage: "chevron.left.forwardslash.chevron.right")
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
                        withAnimation(reduceMotion ? nil : .default) { currentPage = Page.privacy.rawValue }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
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
                Grid(alignment: .leading, horizontalSpacing: TigerDuckTheme.Spacing.md, verticalSpacing: TigerDuckTheme.Spacing.md) {
                    privacyCheckboxRow(
                        isOn: $agreedPrivacy,
                        label: String(localized: "onboarding_privacy_policy_label"),
                        destination: AppURLs.privacyPolicy
                    )
                    privacyCheckboxRow(
                        isOn: $agreedDeletion,
                        label: String(localized: "onboarding_privacy_delete_account_label"),
                        destination: AppURLs.deleteAccount
                    )
                }
                .frame(maxWidth: .infinity)
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
                        let nextPage = showsWatchPage ? Page.watchOS.rawValue : Page.login.rawValue
                        withAnimation(reduceMotion ? nil : .default) { currentPage = nextPage }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!(agreedPrivacy && agreedDeletion))
                }
            }
        )
    }

    private func privacyCheckboxRow(
        isOn: Binding<Bool>, label: String, destination: URL
    ) -> some View {
        GridRow {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isOn.wrappedValue ? Color.accentPrimary : Color.textSecondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
            .accessibilityRepresentation {
                Toggle(label, isOn: isOn)
            }

            // Kept reachable by VoiceOver: the checkbox above is exposed as
            // a Toggle, so this is the only way an assistive-tech user can
            // open the privacy / delete-account page before accepting it.
            Link(label, destination: destination)
                .font(.callout)
        }
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
                withAnimation(reduceMotion ? nil : .default) { currentPage = Page.login.rawValue }
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
            title: String(localized: "onboarding_sign_in_title"),
            subtitle: String(localized: "onboarding_sign_in_subtitle"),
            accentColor: .green,
            content: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    VStack(spacing: 1) {
                        HStack(spacing: TigerDuckTheme.Spacing.md) {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField(String(localized: "sign_in_student_id"), text: $studentId)
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
                                placeholder: String(localized: "sign_in_password"),
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
                        withAnimation(reduceMotion ? nil : .default) { currentPage = Page.notifications.rawValue }
                    }
                    .foregroundStyle(Color.textSecondary)

                    Button {
                        submitLogin()
                    } label: {
                        LoadingButtonLabel(
                            isLoading: appState.authService.isLoggingIn,
                            tint: .white
                        ) {
                            Text(String(localized: "onboarding_sign_in_button"))
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
        #if canImport(UIKit)
        UIApplication.dismissKeyboard()
        #endif
        focusedField = nil
        let trimmedId = studentId.trimmingCharacters(in: .whitespaces)
        let trimmedPwd = password.trimmingCharacters(in: .whitespaces)
        guard !trimmedId.isEmpty, !trimmedPwd.isEmpty, !appState.authService.isLoggingIn else { return }
        Task {
            let success = await appState.authService.login(
                studentId: trimmedId, password: trimmedPwd
            )
            if success { withAnimation(reduceMotion ? nil : .default) { currentPage = Page.notifications.rawValue } }
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

                    #if canImport(UIKit)
                    if notificationStatus == .denied {
                        Button(String(localized: "action_go_to_settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    #endif
                }
            },
            actions: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    Button(String(localized: "onboarding_skip_for_now")) {
                        withAnimation(reduceMotion ? nil : .default) { currentPage = Page.ready.rawValue }
                    }
                    .foregroundStyle(Color.textSecondary)

                    // While the user hasn't answered the system prompt yet,
                    // the affirmative action lives in `notificationStatusRow`
                    // (Allow). Don't surface a second prominent Next here —
                    // it would let the user finish onboarding without ever
                    // triggering `requestAuthorization`, stranding the app
                    // in `.notDetermined` with no registration path.
                    if notificationStatus != .notDetermined {
                        Button(String(localized: "action_next")) {
                            withAnimation(reduceMotion ? nil : .default) { currentPage = Page.ready.rawValue }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
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
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshNotificationStatus()
        // Onboarding is the user's first opt-in to notifications; flip the
        // `pushServerEnabled` flag so PushCoordinator registers for remote
        // notifications and the server sync runs. Without this the user
        // would have to find Settings → Notifications later to actually
        // start receiving server-backed pushes.
        guard granted else { return }
        appState.enablePushServer()
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
