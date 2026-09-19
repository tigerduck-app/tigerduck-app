#if os(iOS)
import SwiftUI

/// The signed-out mail page, styled like Library's `loginPrompt`. Nothing is pre-filled:
/// the mail login is separate from the NTUST one (§7.1).
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
                TextField(String(localized: "sign_in_student_id"), text: $studentID)
                    .textContentType(usernameIsAnAddress ? .emailAddress : .username)
                    .autocorrectionDisabled()
                    // `.characters` is right for a Mail2000 student ID (`B10000000`) and wrong for
                    // anything else: it upper-cases *every* character as it is typed, so
                    // `user@example.com` becomes `USER@EXAMPLE.COM` before it ever reaches
                    // `MailAccountManager.normalizedUsername` — which then preserves that case,
                    // because an address's local part is case-sensitive (RFC 5321 §2.3.11). The
                    // login goes out upper-cased and the server rejects it.
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
