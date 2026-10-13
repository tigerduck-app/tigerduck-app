#if os(iOS)
import SwiftUI

/// The signed-out mail page, styled like Library's `loginPrompt`. The mail login is separate
/// from the NTUST one, since a Mail2000 password is set in webmail and need not match SSO; what
/// it still prefills, and the limits on that, are `MailCredentialPrefill`'s to decide.
struct MailLoginCard: View {
    private enum Field: Hashable { case studentID, password }

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var studentID = ""
    @State private var password = ""
    @State private var showWebmail = false
    @FocusState private var field: Field?
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 36
    private let account = MailAccountManager.shared

    /// The configured address domain, prefilled into the empty field as `@domain` so the form
    /// says what it expects instead of leaving it to be guessed.
    ///
    /// On the school server a bare `B10000000` is right, because the app knows the domain and
    /// supplies it. Under an override the domain comes from the Developer → Email screen, and
    /// without the suffix a bare local part looks just as plausible but is rejected by the server
    /// as a wrong password. The suffix is ordinary editable text, so a server that wants a bare
    /// username still works once it is deleted.
    private var prefilledDomainSuffix: String {
        #if DEBUG
        let config = MailServerConfig.effective
        return config.isOverridden ? "@\(config.addressDomain)" : ""
        #else
        return ""
        #endif
    }

    private var usernamePlaceholder: String {
        prefilledDomainSuffix.isEmpty
            ? String(localized: "sign_in_student_id")
            : "you\(prefilledDomainSuffix)"
    }

    /// Whether the username this field collects is an email address rather than a student ID.
    ///
    /// Only the DEBUG developer override can point the app at a server whose usernames are
    /// addresses; against the school it is always a student ID, so this is `false` in every
    /// Release build and the field keeps exactly the behaviour it has always had.
    private var usernameIsAnAddress: Bool {
        #if DEBUG
        return MailServerConfig.effective.isOverridden
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            Image(systemName: "envelope.fill")
                .font(.system(size: heroIconSize))
                .foregroundStyle(.tint)

            Text(String(localized: "school_mail_sign_in_prompt_title"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)

            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                TextField(usernamePlaceholder, text: $studentID)
                    .textContentType(usernameIsAnAddress ? .emailAddress : .username)
                    .autocorrectionDisabled()
                    // `.characters` suits a student ID (`B10000000`) but upper-cases an address as
                    // it is typed, and `MailAccountManager.normalizedUsername` keeps an address's
                    // case (RFC 5321 §2.3.11), so the login would go out upper-cased and fail.
                    .textInputAutocapitalization(usernameIsAnAddress ? .never : .characters)
                    .keyboardType(usernameIsAnAddress ? .emailAddress : .default)
                    .focused($field, equals: .studentID)
                    .submitLabel(.next)
                    .onSubmit { field = .password }
                    .padding(TigerDuckTheme.Spacing.md)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))

                PasswordField(
                    placeholder: String(localized: "sign_in_password"),
                    text: $password,
                    focusBinding: $field,
                    focusValue: .password,
                    onSubmit: submit
                )
                .padding(TigerDuckTheme.Spacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))
            }

            Text(String(localized: "school_mail_sign_in_note"))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            if let error = account.loginError {
                Label(error.message, systemImage: "xmark.circle")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(.red)
            }

            signInButton

            Button(String(localized: "school_mail_forgot_password"), action: openWebmail)
                .font(TigerDuckTheme.Typography.caption)
        }
        .cardPadding()
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .sheet(isPresented: $showWebmail) {
            InAppBrowserView(url: MailConstants.webmailURL).ignoresSafeArea()
        }
        // Only ever seeds an empty field, so it cannot overwrite something half-typed when the
        // view re-appears.
        .onAppear { seedFields() }
        #if DEBUG
        // Re-seeds when the override changes, taking the school's password out of a form now aimed
        // at another server. `.onAppear` misses this: the card keeps its `@State` while an override
        // is applied in Settings, and `SchoolMailView`'s `generation` hook resets only the list.
        .onChange(of: DevMailServerSettings.shared.generation) { _, _ in seedFields() }
        #endif
    }

    /// Puts `MailCredentialPrefill`'s answer into the two fields. Every carve-out lives in that
    /// function, which is pure and tested; this is only the wiring.
    private func seedFields() {
        let auth = appState.authService
        let fields = MailCredentialPrefill.fields(
            storedID: auth.storedStudentId,
            storedPassword: auth.storedPassword,
            currentID: studentID,
            currentPassword: password,
            isOverridden: usernameIsAnAddress,
            lastRejectedPassword: account.lastRejectedPassword,
            domainSuffix: prefilledDomainSuffix
        )
        studentID = fields.id
        password = fields.password
    }

    @ViewBuilder
    private var signInButton: some View {
        let disabled = studentID.isEmpty || password.isEmpty || account.isLoggingIn
        let label = LoadingButtonLabel(isLoading: account.isLoggingIn) {
            Text(String(localized: "action_sign_in"))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        if #available(iOS 26, *) {
            Button(action: submit) { label }.buttonStyle(.glassProminent).disabled(disabled)
        } else {
            Button(action: submit) { label }.buttonStyle(.borderedProminent).disabled(disabled)
        }
    }

    private func submit() {
        guard !studentID.isEmpty, !password.isEmpty, !account.isLoggingIn else { return }
        field = nil
        let id = studentID
        let secret = password
        Task {
            await account.login(studentID: id, password: secret)
            if account.isLoggedIn { password = "" }
        }
    }

    private func openWebmail() {
        if appState.browserPreference == .inApp {
            showWebmail = true
        } else {
            openURL(MailConstants.webmailURL)
        }
    }
}
#endif
