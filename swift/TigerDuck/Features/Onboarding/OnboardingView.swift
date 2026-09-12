import Defaults
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
    @State private var syncEnabled = true
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationRequestInFlight = false
    /// Presents the API-endpoint editor from the sign-in page, for
    /// users pointing the app at their own backend deployment.
    @Environment(\.openURL) private var openURL
    @State private var showEndpointSheet = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: Field?

    private enum Field { case studentId, password }

    /// Page order: Welcome → Privacy → Cloud Sync → Apple Watch →
    /// Login → Notifications → Ready.
    private enum Page: Int, CaseIterable {
        case welcome, privacy, cloudSync, watchOS, login, notifications, ready
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
            cloudSyncPage.tag(Page.cloudSync.rawValue)
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
        .onChange(of: currentPage) { _, page in
            focusedField = nil
            // Belt and braces for `PagingScrollLock`: nothing past the
            // terms page is reachable until both boxes are ticked.
            if page > Page.privacy.rawValue, !hasAgreedToTerms {
                currentPage = Page.privacy.rawValue
            }
        }
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
                        withAnimation(reduceMotion ? nil : .default) { currentPage = Page.privacy.rawValue }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        )
    }

    // MARK: - Page 1: Privacy & terms

    private var hasAgreedToTerms: Bool { agreedPrivacy && agreedDeletion }

    private var privacyPage: some View {
        OnboardingPageView(
            icon: "lock.shield.fill",
            title: String(localized: "onboarding_privacy_title"),
            subtitle: String(localized: "onboarding_privacy_subtitle"),
            accentColor: .blue,
            iconAnimation: .layerFlash,
            justifiesSubtitle: true,
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
                        .opacity(hasAgreedToTerms ? 0 : 1)

                    Button(String(localized: "action_next")) {
                        withAnimation(reduceMotion ? nil : .default) { currentPage = Page.cloudSync.rawValue }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasAgreedToTerms)
                }
            }
        )
        // The Next button is gated on the two boxes, but a swipe went
        // straight past it. Refuse forward swipes off this page until both
        // are ticked — backward stays free, since going back to Welcome is
        // not what the tick gates. `currentPage` is part of the condition
        // because the pager pre-builds the neighbouring page.
        .background(
            PagingScrollLock(isLocked: currentPage == Page.privacy.rawValue && !hasAgreedToTerms)
                .allowsHitTesting(false)
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
                    .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.textSecondary))
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

    // MARK: - Page 2: Cross-Device Sync

    private var cloudSyncPage: some View {
        OnboardingPageView(
            icon: "arrow.triangle.2.circlepath.icloud.fill",
            title: String(localized: "onboarding_sync_title"),
            subtitle: String(localized: "onboarding_sync_subtitle"),
            accentColor: .cyan,
            content: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    cloudSyncInfoRows

                    Toggle(isOn: $syncEnabled) {
                        Text(String(localized: "onboarding_sync_toggle_label"))
                            .font(.callout.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)

                    if !syncEnabled {
                        Label(
                            String(localized: "onboarding_sync_disabled_note"),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    }

                    VStack(spacing: TigerDuckTheme.Spacing.sm) {
                        Link(destination: AppURLs.learnMoreBackend) {
                            Label(String(localized: "settings_learn_more_backend"), systemImage: "server.rack")
                                .font(.caption)
                        }
                        Link(destination: AppURLs.privacyPolicy) {
                            Label(String(localized: "onboarding_privacy_policy_label"), systemImage: "hand.raised.fill")
                                .font(.caption)
                        }
                        Link(destination: AppURLs.deleteAccount) {
                            Label(String(localized: "onboarding_privacy_delete_account_label"), systemImage: "trash")
                                .font(.caption)
                        }
                    }
                    .padding(.top, TigerDuckTheme.Spacing.sm)
                }
            },
            actions: {
                Button(String(localized: "action_next")) {
                    // `AppState` acts on this like on any other change to the
                    // preference (`CloudSyncPreference`).
                    Defaults[.cloudSyncEnabled] = syncEnabled
                    let nextPage = showsWatchPage ? Page.watchOS.rawValue : Page.login.rawValue
                    withAnimation(reduceMotion ? nil : .default) { currentPage = nextPage }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        )
    }

    @ViewBuilder
    private var cloudSyncInfoRows: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_student_id")
            )
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_moodle_token")
            )
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_device_id")
            )
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_courses")
            )
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_assignments")
            )
            cloudSyncInfoRow(
                icon: "xmark.circle.fill",
                color: .red,
                text: String(localized: "onboarding_sync_not_shared_password")
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func cloudSyncInfoRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.callout)
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: - Page 3: Apple Watch support (iPhone only)

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

    // MARK: - Page 4: Login

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
                    // Ordered least-committal first: look at the server,
                    // then repoint the app at a different one, then give
                    // up and skip. A sign-in that fails here has no other
                    // way to tell the user whether the backend is why.
                    //
                    // A Button rather than the Link the rest of onboarding
                    // uses for external URLs, so it is the same control as
                    // the two below it and picks up textSecondary without
                    // fighting the link tint. It does not honour the browser
                    // preference because the user has not been offered that
                    // choice yet at this point in the flow.
                    Button(String(localized: "settings_check_server_status")) {
                        openURL(AppURLs.serverStatus)
                    }
                    .foregroundStyle(Color.textSecondary)

                    // Above "Skip" on purpose: someone running their own
                    // backend has to point the app at it *before* signing
                    // in, because the sign-in round-trip is one of the
                    // calls that goes to it.
                    Button(String(localized: "onboarding_custom_endpoint_button")) {
                        showEndpointSheet = true
                    }
                    .foregroundStyle(Color.textSecondary)

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
        .sheet(isPresented: $showEndpointSheet) {
            NavigationStack {
                DebugEndpointView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "action_done")) { showEndpointSheet = false }
                        }
                    }
            }
        }
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

    // MARK: - Page 5: Notifications

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

    // MARK: - Page 6: Done

    private var readyPage: some View {
        OnboardingPageView(
            icon: "checkmark.circle.fill",
            title: String(localized: "onboarding_ready_title"),
            subtitle: String(localized: "onboarding_ready_subtitle"),
            accentColor: .onboardingAccent
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

#if canImport(UIKit)
/// Refuses *forward* drags on the page-style `TabView`'s own scroll view,
/// leaving backward ones alone. `scrollDisabled` does not reach the
/// page-style pager, hence the UIKit walk to find it.
///
/// The obvious implementation — `isScrollEnabled = false` while locked —
/// was the first one here, and it froze the page in both directions: a
/// user who had not ticked the boxes could not swipe back to Welcome
/// either. Only forward motion is what the tick gates, so the pager stays
/// scrollable and the offending drag is cancelled instead.
struct PagingScrollLock: UIViewRepresentable {
    let isLocked: Bool

    /// Whether a drag of `translationX` points at the *next* page.
    ///
    /// Pulled out of the gesture handler so the mirroring has a test: a
    /// page-style `TabView` reverses under a right-to-left language, so the
    /// same finger movement that advances in English goes back in Arabic,
    /// and the app ships four right-to-left locales.
    static func isForwardDrag(translationX: CGFloat, isRTL: Bool) -> Bool {
        isRTL ? translationX > 0 : translationX < 0
    }

    func makeUIView(context: Context) -> LockView {
        let view = LockView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: LockView, context: Context) {
        view.isLocked = isLocked
    }

    final class LockView: UIView {
        var isLocked = false

        /// Not private: a test asserts the superview walk still reaches
        /// the pager, which is the load-bearing half of this class.
        private(set) weak var attachedPager: UIScrollView?
        /// Latched at the first movement big enough to have a direction, so
        /// one judgement is made per drag rather than one per callback.
        private var hasJudgedDrag = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachToPager()
        }

        private func attachToPager() {
            guard attachedPager == nil else { return }
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    attachedPager = scrollView
                    scrollView.panGestureRecognizer.addTarget(
                        self, action: #selector(pagerDidPan)
                    )
                    return
                }
                candidate = view.superview
            }
        }

        @objc private func pagerDidPan(_ recognizer: UIPanGestureRecognizer) {
            guard let pager = attachedPager else { return }
            guard recognizer.state == .changed else {
                hasJudgedDrag = false
                return
            }
            guard isLocked, !hasJudgedDrag else { return }

            let dx = recognizer.translation(in: pager).x
            // Too small to have a direction yet. Waiting beats guessing —
            // a wrong guess cancels a legitimate backward swipe.
            guard abs(dx) > 4 else { return }
            hasJudgedDrag = true

            let isRTL = pager.effectiveUserInterfaceLayoutDirection == .rightToLeft
            guard PagingScrollLock.isForwardDrag(translationX: dx, isRTL: isRTL) else { return }

            // Turning scrolling off and straight back on cancels the pan in
            // flight; the pager snaps back to the page it started on.
            pager.isScrollEnabled = false
            pager.isScrollEnabled = true
        }
    }
}
#else
private struct PagingScrollLock: View {
    let isLocked: Bool
    var body: some View { EmptyView() }
}
#endif
